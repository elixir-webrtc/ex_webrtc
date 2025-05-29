defmodule ExWebRTC.PeerConnection do
  @moduledoc """
  Implementation of the [RTCPeerConnection](https://www.w3.org/TR/webrtc/#dom-rtcpeerconnection).
  """

  use GenServer

  import Bitwise

  require Logger

  alias ExWebRTC.RTPCodecParameters
  alias __MODULE__.{Configuration, Demuxer, TWCCRecorder}

  alias ExWebRTC.{
    DataChannel,
    DefaultICETransport,
    DTLSTransport,
    ICECandidate,
    MediaStreamTrack,
    RTPTransceiver,
    RTPSender,
    SCTPTransport,
    SDPUtils,
    SessionDescription,
    Utils
  }

  if not Code.ensure_loaded?(ExSCTP) do
    @sctp_error_text "DataChannel support is turned off"
    @sctp_tip "Install Rust and add `ex_sctp` dependency to your project in order to enable DataChannels."
  end

  @twcc_interval 100
  @twcc_uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"

  @type peer_connection() :: GenServer.server()

  @typedoc """
  Possible connection states.

  For the exact meaning, refer to the [RTCPeerConnection: connectionState property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/connectionState).
  """
  @type connection_state() :: :new | :connecting | :connected | :disconnected | :failed | :closed

  @typedoc """
  Possible ICE gathering states.

  For the exact meaning, refer to the [RTCPeerConnection: iceGatheringState property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/iceGatheringState).
  """
  @type ice_gathering_state() :: :new | :gathering | :complete

  @typedoc """
  Possible ICE connection states.

  For the exact meaning, refer to the [RTCPeerConnection: iceConnectionState property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/iceConnectionState).
  """
  @type ice_connection_state() ::
          :new | :checking | :connected | :completed | :failed | :disconnected | :closed

  @typedoc """
  Possible DTLS transport states.

  For the exact meaning, refer to the [RTCDtlsTransport: state property](https://developer.mozilla.org/en-US/docs/Web/API/RTCDtlsTransport/state)
  """
  @type dtls_transport_state() :: :new | :connecting | :connected | :failed

  @typedoc """
  Possible signaling states.

  For the exact meaning, refer to the [RTCPeerConnection: signalingState property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/signalingState).
  """
  @type signaling_state() :: :stable | :have_local_offer | :have_remote_offer

  @typedoc """
  Messages sent by the `ExWebRTC.PeerConnection` process to its controlling process.

  Most of the messages match the [RTCPeerConnection events](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection#events),
  except for:
  * `:dtls_transport_state_change` - traditional WebRTC implementation does not emit such event.
  Instead, developer can read DTLS transport state by iterating over RTP receivers/senders, and checking their
  DTLS transports states. See https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpSender/transport.
  However, because Elixir WebRTC creates a single DTLS transport for all receivers and senders, there is one generic
  notification for convenience and parity with other events informing about ice/signaling/connection state changes.
  * `:track_muted`, `:track_ended` - these match the [MediaStreamTrack events](https://developer.mozilla.org/en-US/docs/Web/API/MediaStreamTrack#events).
  * `:data` - data received from DataChannel identified by its `ref`.
  * `:rtp` and `:rtcp` - these contain packets received by the PeerConnection. The third element of `:rtp` tuple is a simulcast RID and is set to `nil` if simulcast
  is not used.
  * each of the packets in `:rtcp` message is in the form of `{track_id, packet}` tuple, where `track_id` is the id of the corrsponding track.
  In case of PLI and NACK, this is the id of an outgoing (sender's) track id, in case of Sender and Receiver Reports - incoming (receiver's) track id.
  If matching to a track was not possible (like in the case of TWCC packedts), `track_id` is set to `nil`.
  """
  @type message() ::
          {:ex_webrtc, pid(),
           {:connection_state_change, connection_state()}
           | {:ice_candidate, ICECandidate.t()}
           | {:ice_connection_state_change, ice_connection_state()}
           | {:ice_gathering_state_change, ice_gathering_state()}
           | {:dtls_transport_state_change, dtls_transport_state()}
           | :negotiation_needed
           | {:signaling_state_change, signaling_state()}
           | {:data_channel_state_change, DataChannel.ref(), DataChannel.ready_state()}
           | {:data_channel, DataChannel.t()}
           | {:track, MediaStreamTrack.t()}
           | {:track_muted, MediaStreamTrack.id()}
           | {:track_ended, MediaStreamTrack.id()}
           | {:data, DataChannel.ref(), binary()}
           | {:rtp, MediaStreamTrack.id(), String.t() | nil, ExRTP.Packet.t()}}
          | {:rtcp, [{MediaStreamTrack.id() | nil, ExRTCP.Packet.packet()}]}

  #### NON-MDN-API ####

  @doc """
  Returns a list of all running `ExWebRTC.PeerConnection` processes.
  """
  @spec get_all_running() :: [pid()]
  def get_all_running() do
    Registry.select(ExWebRTC.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.filter(fn pid -> Process.alive?(pid) end)
  end

  @doc """
  Starts a new `ExWebRTC.PeerConnection` process.

  `ExWebRTC.PeerConnection` is a `GenServer` under the hood, thus this function allows for
  passing the generic `t:GenServer.options/0` as an argument.
  """
  @spec start(Configuration.options(), GenServer.options()) :: GenServer.on_start()
  def start(pc_opts \\ [], gen_server_opts \\ []) do
    config =
      pc_opts
      |> Keyword.put_new(:controlling_process, self())
      |> Configuration.from_options!()

    GenServer.start(__MODULE__, config, gen_server_opts)
  end

  @doc """
  Starts a new `ExWebRTC.PeerConnection` process.

  Works identically to `start/2`, but links to the calling process.
  """
  @spec start_link(Configuration.options(), GenServer.options()) :: GenServer.on_start()
  def start_link(pc_opts \\ [], gen_server_opts \\ []) do
    config =
      pc_opts
      |> Keyword.put_new(:controlling_process, self())
      |> Configuration.from_options!()

    GenServer.start_link(__MODULE__, config, gen_server_opts)
  end

  @doc """
  Changes the controlling process of this `peer_connection` process.

  Controlling process is a process that receives all of the messages (described
  by `t:message/0`) from this PeerConnection.
  """
  @spec controlling_process(peer_connection(), Process.dest()) :: :ok
  def controlling_process(peer_connection, controlling_process) do
    GenServer.call(peer_connection, {:controlling_process, controlling_process})
  end

  @doc """
  Returns current `peer_connection` configuration.

  Note: the configuration may change after applying remote description.
  """
  @spec get_configuration(peer_connection()) :: Configuration.t()
  def get_configuration(peer_connection) do
    GenServer.call(peer_connection, :get_configuration)
  end

  @doc """
  Sets the codec that will be used for sending RTP packets.

  `send_rtp/4` overrides some of the RTP packet fields.
  In particular, when multiple codecs are negotiated, `send_rtp/4` will use
  payload type of the most preffered by the remote side codec (i.e. the first
  one from the list of codecs in the remote description).

  Use this function if you want to select, which codec (hence payload type)
  should be used for sending.

  Once the first RTP packet is sent (via `send_rtp/4`), `set_sender_codec/3`
  can only be called with a codec with the same clock rate.

  Although very unlikely, keep in mind that after renegotiation,
  the selected codec may no longer be supported by the remote side and you might
  need to call this function again, passing a new codec.

  To check available codecs you can use `get_transceivers/1`:

  ```
  {:ok, pc} = PeerConnection.start_link()
  {:ok, rtp_sender} = PeerConnection.add_track(MediaStreamTrack.new(:video))

  # exchange SDP with the remote side
  # {:ok, offer} = PeerConnection.create_offer(pc)
  # ...

  tr =
    pc
    |> PeerConnection.get_transceivers()
    |> Enum.find(fn tr -> tr.sender.id == rtp_sender.id end)

  dbg(tr.codecs) # list of supported codecs both for sending and receiving

  # e.g. always prefer h264 over vp8
  h264 = Enum.find(tr.codecs, fn codec -> codec.mime_type == "video/H264" end)
  vp8 = Enum.find(tr.codecs, fn codec -> codec.mime_type == "video/VP8" end)

  :ok = PeerConnection.set_sender_codec(pc, rtp_sender.id, h264 || vp8)
  ```

  This function can only be called once the first negotiation passes.
  """
  @spec set_sender_codec(peer_connection(), RTPSender.id(), RTPCodecParameters.t()) ::
          :ok | {:error, term()}
  def set_sender_codec(peer_connection, sender_id, codec) do
    GenServer.call(peer_connection, {:set_sender_codec, sender_id, codec})
  end

  @doc """
  Sends an RTP packet to the remote peer using the track specified by the `track_id`.

  The following fields of the RTP packet will be overwritten by this function:
  * payload type
  * ssrc
  * rtp header extensions

  If you negotiated multiple codecs (hence payload types) and you want to choose,
  which one should be used, see `set_sender_codec/3`.

  Options:
    * `rtx?` - send the packet as if it was retransmitted (use SSRC and payload type specific to RTX)
  """
  @spec send_rtp(
          peer_connection(),
          MediaStreamTrack.id(),
          ExRTP.Packet.t(),
          rtx?: boolean()
        ) :: :ok
  def send_rtp(peer_connection, track_id, packet, opts \\ []) do
    GenServer.cast(peer_connection, {:send_rtp, track_id, packet, opts})
  end

  @doc """
  Sends an RTCP PLI feedback to the remote peer using the track specified by the `track_id`.

  Set `rid` to the simulcast `rid` for which the PLI should be sent. If simulcast is not used, `rid` should
  be equal to `nil`.
  """
  @spec send_pli(peer_connection(), MediaStreamTrack.id(), String.t() | nil) :: :ok
  def send_pli(peer_connection, track_id, rid \\ nil) do
    GenServer.cast(peer_connection, {:send_pli, track_id, rid})
  end

  @doc """
  Sends data over DataChannel, using channel identified by `ref`.

  Requires the channel to be in `:open` state.

  If `ref` does not identify any DataChannel, this function behaves like no-op.
  """
  @spec send_data(peer_connection(), DataChannel.ref(), binary(), :string | :binary) :: :ok
  def send_data(peer_connection, channel_ref, data, data_type \\ :string) do
    GenServer.cast(peer_connection, {:send_data, channel_ref, data_type, data})
  end

  @doc """
  Sets very simple packet loss.

  Can be used for experimental purposes.
  """
  @spec set_packet_loss(peer_connection(), 0..100) :: :ok
  def set_packet_loss(peer_connection, value) when value in 0..100 do
    GenServer.cast(peer_connection, {:set_packet_loss, value})
  end

  #### MDN-API ####

  @doc """
  Returns the connection state.

  For more information, refer to the [RTCPeerConnection: connectionState property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/connectionState).
  """
  @spec get_connection_state(peer_connection()) :: connection_state()
  def get_connection_state(peer_connection) do
    GenServer.call(peer_connection, :get_connection_state)
  end

  @doc """
  Returns the ICE connection state.

  For more information, refer to the [RTCPeerConnection: iceConnectionState property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/iceConnectionState).
  """
  @spec get_ice_connection_state(peer_connection()) :: ice_connection_state()
  def get_ice_connection_state(peer_connection) do
    GenServer.call(peer_connection, :get_ice_connection_state)
  end

  @doc """
  Returns the ICE gathering state.

  For more information, refer to the [RTCPeerConnection: iceGatheringState property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/iceGatheringState).
  """
  @spec get_ice_gathering_state(peer_connection()) :: ice_gathering_state()
  def get_ice_gathering_state(peer_connection) do
    GenServer.call(peer_connection, :get_ice_gathering_state)
  end

  @doc """
  Returns the DTLS transport state.

  For more information, refer to the [RTCDtlsTransport: state property](https://developer.mozilla.org/en-US/docs/Web/API/RTCDtlsTransport/state).
  """
  @spec get_dtls_transport_state(peer_connection()) :: dtls_transport_state()
  def get_dtls_transport_state(peer_connection) do
    GenServer.call(peer_connection, :get_dtls_transport_state)
  end

  @doc """
  Returns the signaling state.

  For more information, refer to the [RTCPeerConnection: signalingState property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/signalingState).
  """
  @spec get_signaling_state(peer_connection()) :: signaling_state()
  def get_signaling_state(peer_connection) do
    GenServer.call(peer_connection, :get_signaling_state)
  end

  @doc """
  Returns the local description.

  For more information, refer to the [RTCPeerConnection: localDescription property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/localDescription).
  """
  @spec get_local_description(peer_connection()) :: SessionDescription.t() | nil
  def get_local_description(peer_connection) do
    GenServer.call(peer_connection, :get_local_description)
  end

  @doc """
  Returns the remote description.

  For more information, refer to the [RTCPeerConnection: remoteDescription property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/remoteDescription).
  """
  @spec get_remote_description(peer_connection()) :: SessionDescription.t() | nil
  def get_remote_description(peer_connection) do
    GenServer.call(peer_connection, :get_remote_description)
  end

  @doc """
  Returns the pending local description.

  For more information, refer to the [RTCPeerConnection: pendingLocalDescription property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/pendingLocalDescription).
  """
  @spec get_pending_local_description(peer_connection()) :: SessionDescription.t() | nil
  def get_pending_local_description(peer_connection) do
    GenServer.call(peer_connection, :get_pending_local_description)
  end

  @doc """
  Returns the pending remote description.

  For more information, refer to the [RTCPeerConnection: pendingRemoteDescription property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/pendingRemoteDescription).
  """
  @spec get_pending_remote_description(peer_connection()) :: SessionDescription.t() | nil
  def get_pending_remote_description(peer_connection) do
    GenServer.call(peer_connection, :get_pending_remote_description)
  end

  @doc """
  Returns the current local description.

  For more information, refer to the [RTCPeerConnection: currentLocalDescription property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/currentLocalDescription).
  """
  @spec get_current_local_description(peer_connection()) :: SessionDescription.t() | nil
  def get_current_local_description(peer_connection) do
    GenServer.call(peer_connection, :get_current_local_description)
  end

  @doc """
  Returns the current remote description.

  For more information, refer to the [RTCPeerConnection: currentRemoteDescription property](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/currentRemoteDescription).
  """
  @spec get_current_remote_description(peer_connection()) :: SessionDescription.t() | nil
  def get_current_remote_description(peer_connection) do
    GenServer.call(peer_connection, :get_current_remote_description)
  end

  @doc """
  Returns the list of transceivers.

  For more information, refer to the [RTCPeerConnection: getTransceivers() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/getTransceivers).
  """
  @spec get_transceivers(peer_connection()) :: [RTPTransceiver.t()]
  def get_transceivers(peer_connection) do
    GenServer.call(peer_connection, :get_transceivers)
  end

  @doc """
  Returns PeerConnection's statistics.

  For more information, refer to the [RTCPeerConnection: getStats() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/getStats).
  See [RTCStatsReport](https://www.w3.org/TR/webrtc/#rtcstatsreport-object) for the output structure.
  """
  @spec get_stats(peer_connection()) :: %{(atom() | integer()) => map()}
  def get_stats(peer_connection) do
    GenServer.call(peer_connection, :get_stats)
  end

  @doc """
  Sets the local description.

  For more information, refer to the [RTCPeerConnection: setLocalDescription() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/setLocalDescription).
  """
  @spec set_local_description(peer_connection(), SessionDescription.t()) :: :ok | {:error, term()}
  def set_local_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_local_description, description})
  end

  @doc """
  Sets the remote description.

  For more information, refer to the [RTCPeerConnection: setRemoteDescription() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/setRemoteDescription).
  """
  @spec set_remote_description(peer_connection(), SessionDescription.t()) ::
          :ok | {:error, term()}
  def set_remote_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_remote_description, description})
  end

  @doc """
  Creates an SDP offer.

  For more information, refer to the [RTCPeerConnection: createOffer() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/createOffer).
  """
  @spec create_offer(peer_connection(), ice_restart: boolean()) ::
          {:ok, SessionDescription.t()} | {:error, term()}
  def create_offer(peer_connection, options \\ []) do
    GenServer.call(peer_connection, {:create_offer, options})
  end

  @doc """
  Creates an SDP answer.

  For more information, refer to the [RTCPeerConnection: createAnswer() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/createAnswer).
  """
  @spec create_answer(peer_connection()) :: {:ok, SessionDescription.t()} | {:error, term()}
  def create_answer(peer_connection) do
    GenServer.call(peer_connection, :create_answer)
  end

  @doc """
  Adds a new remote ICE candidate.

  For more information, refer to the [RTCPeerConnection: addIceCandidate() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/addIceCandidate).
  """
  @spec add_ice_candidate(peer_connection(), ICECandidate.t()) :: :ok | {:error, term()}
  def add_ice_candidate(peer_connection, candidate) do
    GenServer.call(peer_connection, {:add_ice_candidate, candidate})
  end

  @doc """
  Adds a new transceiver.

  For more information, refer to the [RTCPeerConnection: addTransceiver() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/addTransceiver).
  """
  @spec add_transceiver(
          peer_connection(),
          RTPTransceiver.kind() | MediaStreamTrack.t(),
          direction: RTPTransceiver.direction()
        ) :: {:ok, RTPTransceiver.t()}
  def add_transceiver(peer_connection, kind_or_track, options \\ []) do
    GenServer.call(peer_connection, {:add_transceiver, kind_or_track, options})
  end

  @doc """
  Sets the direction of transceiver specified by the `transceiver_id`.

  For more information, refer to the [RTCRtpTransceiver: direction property](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpTransceiver/direction).
  """
  @spec set_transceiver_direction(
          peer_connection(),
          RTPTransceiver.id(),
          RTPTransceiver.direction()
        ) :: :ok | {:error, term()}
  def set_transceiver_direction(peer_connection, transceiver_id, direction)
      when direction in [:sendrecv, :sendonly, :recvonly, :inactive] do
    GenServer.call(peer_connection, {:set_transceiver_direction, transceiver_id, direction})
  end

  @doc """
  Stops the transceiver specified by the `transceiver_id`.

  For more information, refer to the [RTCRtpTransceiver: stop() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpTransceiver/stop).
  """
  @spec stop_transceiver(peer_connection(), RTPTransceiver.id()) :: :ok | {:error, term()}
  def stop_transceiver(peer_connection, transceiver_id) do
    GenServer.call(peer_connection, {:stop_transceiver, transceiver_id})
  end

  @doc """
  Adds a new track.

  For more information, refer to the [RTCPeerConnection: addTrack() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/addTrack).
  """
  @spec add_track(peer_connection(), MediaStreamTrack.t()) :: {:ok, RTPSender.t()}
  def add_track(peer_connection, track) do
    GenServer.call(peer_connection, {:add_track, track})
  end

  @doc """
  Replaces the track assigned to the sender specified by the `sender_id`.

  For more information, refer to the [RTCRtpSender: replaceTrack() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpSender/replaceTrack).
  """
  @spec replace_track(peer_connection(), RTPSender.id(), MediaStreamTrack.t()) ::
          :ok | {:error, term()}
  def replace_track(peer_connection, sender_id, track) do
    GenServer.call(peer_connection, {:replace_track, sender_id, track})
  end

  @doc """
  Removes the track assigned to the sender specified by the `sender_id`.

  For more information, refer to the [RTCPeerConnection: removeTrack() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/removeTrack).
  """
  @spec remove_track(peer_connection(), RTPSender.id()) :: :ok | {:error, term()}
  def remove_track(peer_connection, sender_id) do
    GenServer.call(peer_connection, {:remove_track, sender_id})
  end

  @doc """
  Creates a new DataChannel.

  For more information, refer to the [RTCPeerConnection: createDataChannel() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/createDataChannel).
  """
  @spec create_data_channel(peer_connection(), String.t(), DataChannel.options()) ::
          {:ok, DataChannel.t()} | {:error, atom()}
  def create_data_channel(peer_connection, label, opts \\ []) do
    GenServer.call(peer_connection, {:create_data_channel, label, opts})
  end

  @doc """
  Closes a DataChannel identified by `ref`.

  As of now, the closed channel directly transitions to closed state,
  which is signaled with `{:data_channel_state_change, ref, :closed}` message.
  For more information, refer to the [RTCDataChannel: close() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel/close).

  If `ref` does not identify any DataChannel, this function behaves like no-op.
  """
  @spec close_data_channel(peer_connection(), DataChannel.ref()) :: :ok
  def close_data_channel(peer_connection, channel_ref) do
    GenServer.call(peer_connection, {:close_data_channel, channel_ref})
  end

  @doc """
  Returns `t:ExWebRTC.DataChannel.t()` identified by `channel_ref` if it exists, `nil` otherwise.

  This function can be especially helpful when you want to obtain DataChannel `id`. Normally,
  before SCTP connection is established, `create_data_channel/3` will return DataChannel struct
  with `id` set to `nil`. After receiving `{:data_channel_state_change, ref, :open}` message,
  you can call this function to obtain the same struct, but with `id` set to proper value.
  """
  @spec get_data_channel(peer_connection(), DataChannel.ref()) :: DataChannel.t() | nil
  def get_data_channel(peer_connection, channel_ref) do
    GenServer.call(peer_connection, {:get_data_channel, channel_ref})
  end

  @doc """
  Closes the PeerConnection.

  This function kills the `peer_connection` process.
  For more information, refer to the [RTCPeerConnection: close() method](https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/close).
  """
  @spec close(peer_connection()) :: :ok
  def close(peer_connection) do
    GenServer.stop(peer_connection)
  end

  #### CALLBACKS ####

  @impl true
  def init(config) do
    # FIXME: Spawning a lot of peer connections simultaneously, often takes a lot of time.
    # This does not happen when spawning a single peer connection.
    # Moving actual initialization to handle_continue at least does not block
    # supervisor/dynamic supervisor under which those peer connections are spawned.
    {:ok, nil, {:continue, config}}
  end

  @impl true
  def handle_continue(config, _state) do
    {:ok, _} = Registry.register(ExWebRTC.Registry, self(), self())

    ice_config = [
      ice_servers: config.ice_servers,
      ice_transport_policy: config.ice_transport_policy,
      ip_filter: config.ice_ip_filter,
      aggressive_nomination: config.ice_aggressive_nomination,
      ports: config.ice_port_range,
      on_data: nil
    ]

    {:ok, ice_pid} = DefaultICETransport.start_link(ice_config)
    {:ok, dtls_transport} = DTLSTransport.start_link(DefaultICETransport, ice_pid)
    # route data to the DTLSTransport
    :ok = DefaultICETransport.on_data(ice_pid, dtls_transport)

    twcc_id =
      (config.video_extensions ++ config.audio_extensions)
      |> Enum.find(&(&1.uri == @twcc_uri))
      |> then(&if(:twcc in config.features, do: &1.id, else: nil))

    if twcc_id != nil do
      Process.send_after(self(), :send_twcc_feedback, @twcc_interval)
    end

    state = %{
      owner: config.controlling_process,
      config: config,
      current_local_desc: nil,
      pending_local_desc: nil,
      current_remote_desc: nil,
      pending_remote_desc: nil,
      negotiation_needed: false,
      sctp_transport: SCTPTransport.new(),
      ice_transport: DefaultICETransport,
      ice_pid: ice_pid,
      dtls_transport: dtls_transport,
      demuxer: %Demuxer{},
      transceivers: [],
      ice_state: :new,
      ice_gathering_state: :new,
      dtls_state: :new,
      conn_state: :new,
      signaling_state: :stable,
      last_offer: nil,
      last_answer: nil,
      peer_fingerprint: nil,
      sent_packets: 0,
      twcc_extension_id: twcc_id,
      twcc_recorder: TWCCRecorder.new()
    }

    notify(state.owner, {:connection_state_change, :new})
    notify(state.owner, {:signaling_state_change, :stable})

    {:noreply, state}
  end

  @impl true
  def handle_call({:controlling_process, controlling_process}, _from, state) do
    state = %{state | owner: controlling_process}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_configuration, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_call({:set_sender_codec, sender_id, codec}, _from, state) do
    state.transceivers
    |> Enum.with_index()
    |> Enum.find(fn {tr, _idx} -> tr.sender.id == sender_id end)
    |> case do
      {tr, idx} when tr.direction in [:sendrecv, :sendonly] ->
        case RTPTransceiver.set_sender_codec(tr, codec) do
          {:ok, tr} ->
            transceivers = List.replace_at(state.transceivers, idx, tr)
            state = %{state | transceivers: transceivers}
            {:reply, :ok, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      {_tr, _idx} ->
        {:reply, {:error, :invalid_transceiver_direction}, state}

      nil ->
        {:reply, {:error, :invalid_sender_id}, state}
    end
  end

  @impl true
  def handle_call(:get_connection_state, _from, state) do
    {:reply, state.conn_state, state}
  end

  @impl true
  def handle_call(:get_ice_connection_state, _from, state) do
    {:reply, state.ice_state, state}
  end

  @impl true
  def handle_call(:get_ice_gathering_state, _from, state) do
    {:reply, state.ice_gathering_state, state}
  end

  @impl true
  def handle_call(:get_dtls_transport_state, _from, state) do
    {:reply, state.dtls_state, state}
  end

  @impl true
  def handle_call(:get_signaling_state, _from, state) do
    {:reply, state.signaling_state, state}
  end

  @impl true
  def handle_call({:create_offer, _options}, _from, %{signaling_state: ss} = state)
      when ss not in [:stable, :have_local_offer] do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_call({:create_offer, options}, _from, state) do
    if Keyword.get(options, :ice_restart, false) do
      :ok = state.ice_transport.restart(state.ice_pid)
    end

    {:ok, ice_ufrag, ice_pwd} =
      state.ice_transport.get_local_credentials(state.ice_pid)

    offer =
      %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
      # we support trickle ICE only
      |> ExSDP.add_attribute({:ice_options, "trickle"})

    fingerprint = DTLSTransport.get_fingerprint(state.dtls_transport)

    opts =
      [
        ice_ufrag: ice_ufrag,
        ice_pwd: ice_pwd,
        ice_options: "trickle",
        fingerprint: {:sha256, Utils.hex_dump(fingerprint)},
        setup: :actpass,
        rtcp: true
      ]

    {transceivers, mlines} = generate_offer_mlines(state, opts)

    mids = SDPUtils.get_bundle_mids(mlines)

    offer =
      offer
      |> ExSDP.add_attributes([
        %ExSDP.Attribute.Group{semantics: "BUNDLE", mids: mids},
        "extmap-allow-mixed",
        {"msid-semantic", "WMS *"}
      ])
      |> ExSDP.add_media(mlines)

    sdp = to_string(offer)
    desc = %SessionDescription{type: :offer, sdp: sdp}

    # NOTICE: we assign mids in create_offer (not in apply_local_description)
    # this is fine as long as we not allow for SDP munging
    state = %{state | last_offer: sdp, transceivers: transceivers}
    {:reply, {:ok, desc}, state}
  end

  @impl true
  def handle_call(:create_answer, _from, %{signaling_state: ss} = state)
      when ss not in [:have_remote_offer, :have_local_pranswer] do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_call(:create_answer, _from, state) do
    {:offer, remote_offer} = state.pending_remote_desc

    {:ok, ice_ufrag, ice_pwd} =
      state.ice_transport.get_local_credentials(state.ice_pid)

    answer =
      %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
      # we only support trickle ICE, so non-trickle offers should be rejected earlier
      |> ExSDP.add_attribute({:ice_options, "trickle"})

    fingerprint = DTLSTransport.get_fingerprint(state.dtls_transport)

    opts =
      [
        ice_ufrag: ice_ufrag,
        ice_pwd: ice_pwd,
        ice_options: "trickle",
        fingerprint: {:sha256, Utils.hex_dump(fingerprint)},
        setup: :active
      ]

    mlines =
      Enum.map(remote_offer.media, fn mline ->
        {:mid, mid} = ExSDP.get_attribute(mline, :mid)

        if SDPUtils.data_channel?(mline) do
          generate_data_mline(mid, opts)
        else
          {_ix, transceiver} = find_transceiver(state.transceivers, mid)
          RTPTransceiver.to_answer_mline(transceiver, mline, opts)
        end
      end)

    mids = SDPUtils.get_bundle_mids(mlines)

    answer =
      answer
      |> ExSDP.add_attributes([
        %ExSDP.Attribute.Group{semantics: "BUNDLE", mids: mids},
        # always allow for mixing one- and two-byte RTP header extensions
        # TODO ensure this was also offered
        "extmap-allow-mixed",
        {"msid-semantic", "WMS *"}
      ])
      |> ExSDP.add_media(mlines)

    sdp = to_string(answer)
    desc = %SessionDescription{type: :answer, sdp: sdp}
    state = %{state | last_answer: sdp}

    {:reply, {:ok, desc}, state}
  end

  @impl true
  def handle_call({:set_local_description, desc}, _from, state) do
    case apply_local_description(desc, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:get_local_description, _from, state) do
    desc = state.pending_local_desc || state.current_local_desc
    candidates = state.ice_transport.get_local_candidates(state.ice_pid)
    desc = do_get_description(desc, candidates)
    {:reply, desc, state}
  end

  @impl true
  def handle_call(:get_pending_local_description, _from, state) do
    candidates = state.ice_transport.get_local_candidates(state.ice_pid)
    desc = do_get_description(state.current_pending_desc, candidates)
    {:reply, desc, state}
  end

  @impl true
  def handle_call(:get_current_local_description, _from, state) do
    candidates = state.ice_transport.get_local_candidates(state.ice_pid)
    desc = do_get_description(state.current_local_desc, candidates)
    {:reply, desc, state}
  end

  @impl true
  def handle_call({:set_remote_description, desc}, _from, state) do
    case apply_remote_description(desc, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:get_remote_description, _from, state) do
    desc = state.pending_remote_desc || state.current_remote_desc
    candidates = state.ice_transport.get_remote_candidates(state.ice_pid)
    desc = do_get_description(desc, candidates)
    {:reply, desc, state}
  end

  @impl true
  def handle_call(:get_pending_remote_description, _from, state) do
    candidates = state.ice_transport.get_local_candidates(state.ice_pid)
    desc = do_get_description(state.current_remote_desc, candidates)
    {:reply, desc, state}
  end

  @impl true
  def handle_call(:get_current_remote_description, _from, state) do
    candidates = state.ice_transport.get_remote_candidates(state.ice_pid)
    desc = do_get_description(state.current_remote_desc, candidates)
    {:reply, desc, state}
  end

  @impl true
  def handle_call(
        {:add_ice_candidate, _},
        _from,
        %{current_remote_desc: nil, pending_remote_desc: nil} = state
      ),
      do: {:reply, {:error, :no_remote_description}, state}

  @impl true
  def handle_call({:add_ice_candidate, %{candidate: ""}}, _from, state) do
    :ok = state.ice_transport.end_of_candidates(state.ice_pid)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_ice_candidate, candidate}, _from, state) do
    with "candidate:" <> attr <- candidate.candidate do
      state.ice_transport.add_remote_candidate(state.ice_pid, attr)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_transceivers, _from, state) do
    transceivers = Enum.map(state.transceivers, &RTPTransceiver.to_struct/1)
    {:reply, transceivers, state}
  end

  @impl true
  def handle_call({:add_transceiver, kind, options}, _from, state)
      when kind in [:audio, :video] do
    {ssrc, rtx_ssrc} = generate_ssrcs(state)
    options = [{:ssrc, ssrc}, {:rtx_ssrc, rtx_ssrc} | options]

    tr = RTPTransceiver.new(kind, nil, state.config, options)
    state = %{state | transceivers: state.transceivers ++ [tr]}

    state = update_negotiation_needed(state)

    {:reply, {:ok, RTPTransceiver.to_struct(tr)}, state}
  end

  @impl true
  def handle_call({:add_transceiver, %MediaStreamTrack{} = track, options}, _from, state) do
    {ssrc, rtx_ssrc} = generate_ssrcs(state)
    options = [{:ssrc, ssrc}, {:rtx_ssrc, rtx_ssrc} | options]

    tr = RTPTransceiver.new(track.kind, track, state.config, options)
    state = %{state | transceivers: state.transceivers ++ [tr]}

    state = update_negotiation_needed(state)

    {:reply, {:ok, RTPTransceiver.to_struct(tr)}, state}
  end

  @impl true
  def handle_call({:set_transceiver_direction, tr_id, direction}, _from, state) do
    state.transceivers
    |> Enum.with_index()
    |> Enum.find(fn {tr, _idx} -> tr.id == tr_id end)
    |> case do
      {tr, idx} ->
        tr = RTPTransceiver.set_direction(tr, direction)
        transceivers = List.replace_at(state.transceivers, idx, tr)
        state = %{state | transceivers: transceivers}
        state = update_negotiation_needed(state)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :invalid_transceiver_id}, state}
    end
  end

  @impl true
  def handle_call({:stop_transceiver, tr_id}, _from, state) do
    state.transceivers
    |> Enum.with_index()
    |> Enum.find(fn {tr, _idx} -> tr.id == tr_id end)
    |> case do
      {tr, _idx} when tr.stopping ->
        {:reply, :ok, state}

      {tr, idx} ->
        on_track_ended = on_track_ended(state.owner, tr.receiver.track.id)
        tr = RTPTransceiver.stop_sending_and_receiving(tr, on_track_ended)
        transceivers = List.replace_at(state.transceivers, idx, tr)
        state = %{state | transceivers: transceivers}
        state = update_negotiation_needed(state)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :invalid_transceiver_id}, state}
    end
  end

  @impl true
  def handle_call({:add_track, %MediaStreamTrack{kind: kind} = track}, _from, state) do
    # we ignore the condition that sender has never been used to send

    {transceivers, sender} =
      state.transceivers
      |> Enum.with_index()
      |> Enum.find(fn {tr, _idx} -> RTPTransceiver.can_add_track?(tr, kind) end)
      |> case do
        {tr, idx} ->
          tr = RTPTransceiver.add_track(tr, track)
          {List.replace_at(state.transceivers, idx, tr), tr.sender}

        nil ->
          {ssrc, rtx_ssrc} = generate_ssrcs(state)

          options = [
            direction: :sendrecv,
            added_by_add_track: true,
            ssrc: ssrc,
            rtx_ssrc: rtx_ssrc
          ]

          tr = RTPTransceiver.new(kind, track, state.config, options)
          {state.transceivers ++ [tr], tr.sender}
      end

    state =
      %{state | transceivers: transceivers}
      |> update_negotiation_needed()

    {:reply, {:ok, RTPSender.to_struct(sender)}, state}
  end

  @impl true
  def handle_call({:replace_track, sender_id, track}, _from, state) do
    state.transceivers
    |> Enum.with_index()
    |> Enum.find(fn {tr, _idx} -> tr.sender.id == sender_id end)
    |> case do
      {tr, _idx} when track != nil and tr.kind != track.kind ->
        {:reply, {:error, :invalid_track_type}, state}

      {tr, idx} when tr.direction in [:sendrecv, :sendonly] ->
        tr = RTPTransceiver.replace_track(tr, track)
        transceivers = List.replace_at(state.transceivers, idx, tr)
        state = %{state | transceivers: transceivers}
        {:reply, :ok, state}

      {_tr, _idx} ->
        # that's not compliant with the W3C but it's safer not
        # to allow for this until we have clear use case
        {:reply, {:error, :invalid_transceiver_direction}, state}

      nil ->
        {:reply, {:error, :invalid_sender_id}, state}
    end
  end

  @impl true
  def handle_call({:remove_track, sender_id}, _from, state) do
    state.transceivers
    |> Stream.with_index()
    |> Enum.find(fn {tr, _idx} -> tr.sender.id == sender_id end)
    |> case do
      {tr, _idx} when tr.sender.track == nil ->
        {:reply, :ok, state}

      {tr, idx} ->
        tr = RTPTransceiver.remove_track(tr)
        transceivers = List.replace_at(state.transceivers, idx, tr)
        state = %{state | transceivers: transceivers}
        state = update_negotiation_needed(state)
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :invalid_sender_id}, state}
    end
  end

  if Code.ensure_loaded?(ExSCTP) do
    @impl true
    def handle_call({:create_data_channel, label, opts}, _from, state) do
      ordered = Keyword.get(opts, :ordered, true)
      lifetime = Keyword.get(opts, :max_packet_life_time)
      max_rtx = Keyword.get(opts, :max_retransmits)
      protocol = Keyword.get(opts, :protocol, "")

      with true <- byte_size(label) < 65_535,
           true <- lifetime == nil or max_rtx == nil do
        {events, channel, sctp_transport} =
          SCTPTransport.add_channel(
            state.sctp_transport,
            label,
            ordered,
            protocol,
            lifetime,
            max_rtx
          )

        state = update_negotiation_needed(%{state | sctp_transport: sctp_transport})

        handle_sctp_events(events, state)
        {:reply, {:ok, channel}, state}
      else
        _other -> {:reply, {:error, :invalid_option}, state}
      end
    end

    @impl true
    def handle_call({:close_data_channel, channel_ref}, _from, state) do
      {events, sctp_transport} = SCTPTransport.close_channel(state.sctp_transport, channel_ref)
      handle_sctp_events(events, state)

      {:reply, :ok, %{state | sctp_transport: sctp_transport}}
    end

    @impl true
    def handle_call({:get_data_channel, channel_ref}, _from, state) do
      channel = SCTPTransport.get_channel(state.sctp_transport, channel_ref)
      {:reply, channel, state}
    end
  else
    @impl true
    def handle_call({:create_data_channel, _label, _opts}, _from, _state) do
      raise("#{@sctp_error_text} #{@sctp_tip}")
    end

    @impl true
    def handle_call({:close_data_channel, _channel_ref}, _from, _state) do
      raise("#{@sctp_error_text} #{@sctp_tip}")
    end

    @impl true
    def handle_call({:get_data_channel, _channel_ref}, _from, _state) do
      raise("#{@sctp_error_text} #{@sctp_tip}")
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    timestamp = System.os_time(:millisecond)

    ice_stats = state.ice_transport.get_stats(state.ice_pid)

    %{local_cert_info: local_cert_info, remote_cert_info: remote_cert_info} =
      DTLSTransport.get_certs_info(state.dtls_transport)

    remote_certificate =
      if remote_cert_info != nil do
        %{
          id: :remote_certificate,
          type: :certificate,
          timestamp: timestamp,
          fingerprint: remote_cert_info.fingerprint,
          fingerprint_algorithm: remote_cert_info.fingerprint_algorithm,
          base64_certificate: remote_cert_info.base64_certificate
        }
      else
        %{
          id: :remote_certificate,
          type: :certificate,
          timestamp: timestamp,
          fingerprint: nil,
          fingerprint_algorithm: nil,
          base64_certificate: nil
        }
      end

    to_stats_candidate = fn cand, type, timestamp ->
      %{
        id: cand.id,
        timestamp: timestamp,
        type: type,
        address: cand.address,
        port: cand.port,
        protocol: cand.transport,
        candidate_type: cand.type,
        priority: cand.priority,
        foundation: cand.foundation,
        related_address: cand.base_address,
        related_port: cand.base_port
      }
    end

    to_stats_pair = fn pair, timestamp ->
      %{
        id: pair.id,
        timestamp: timestamp,
        type: :candidate_pair,
        local_candidate_id: pair.local_cand_id,
        remote_candidate_id: pair.remote_cand_id,
        priority: pair.priority,
        state: pair.state,
        valid: pair.valid?,
        last_seen: pair.last_seen,
        nominated: pair.nominated?,
        packets_sent: pair.packets_sent,
        packets_received: pair.packets_received,
        bytes_sent: pair.bytes_sent,
        bytes_received: pair.bytes_received,
        requests_sent: pair.requests_sent,
        requests_received: pair.requests_received,
        responses_sent: pair.responses_sent,
        responses_received: pair.responses_received,
        non_symmetric_responses_received: pair.non_symmetric_responses_received,
        packets_discarded_on_send: pair.packets_discarded_on_send,
        bytes_discarded_on_send: pair.bytes_discarded_on_send
      }
    end

    local_cands =
      Map.new(ice_stats.local_candidates, fn local_cand ->
        cand = to_stats_candidate.(local_cand, :local_candidate, timestamp)
        {cand.id, cand}
      end)

    remote_cands =
      Map.new(ice_stats.remote_candidates, fn remote_cand ->
        cand = to_stats_candidate.(remote_cand, :remote_candidate, timestamp)
        {cand.id, cand}
      end)

    candidate_pairs =
      Map.new(ice_stats.candidate_pairs, fn pair ->
        pair = to_stats_pair.(pair, timestamp)
        {pair.id, pair}
      end)

    rtp_stats =
      state.transceivers
      |> Enum.flat_map(&RTPTransceiver.get_stats(&1, timestamp))
      |> Map.new(fn stats -> {stats.id, stats} end)

    data_channel_stats =
      state.sctp_transport
      |> SCTPTransport.get_stats(timestamp)
      |> Map.new(fn stats -> {stats.id, stats} end)

    stats = %{
      peer_connection: %{
        id: :peer_connection,
        type: :peer_connection,
        timestamp: timestamp,
        signaling_state: state.signaling_state,
        negotiation_needed: state.negotiation_needed,
        connection_state: state.conn_state
      },
      local_certificate: %{
        id: :local_certificate,
        type: :certificate,
        timestamp: timestamp,
        fingerprint: local_cert_info.fingerprint,
        fingerprint_algorithm: local_cert_info.fingerprint_algorithm,
        base64_certificate: local_cert_info.base64_certificate
      },
      remote_certificate: remote_certificate,
      transport: %{
        id: :transport,
        type: :transport,
        timestamp: timestamp,
        ice_state: ice_stats.state,
        ice_gathering_state: state.ice_gathering_state,
        ice_role: ice_stats.role || :unknown,
        ice_local_ufrag: ice_stats.local_ufrag,
        dtls_state: state.dtls_state,
        bytes_sent: ice_stats.bytes_sent,
        bytes_received: ice_stats.bytes_received,
        packets_sent: ice_stats.packets_sent,
        packets_received: ice_stats.packets_received,
        selected_candidate_pair_changes: ice_stats.selected_candidate_pair_changes,
        unmatched_requests: ice_stats.unmatched_requests
      }
    }

    stats =
      stats
      |> Map.merge(local_cands)
      |> Map.merge(remote_cands)
      |> Map.merge(candidate_pairs)
      |> Map.merge(rtp_stats)
      |> Map.merge(data_channel_stats)

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:send_rtp, track_id, packet, opts}, %{conn_state: conn_state} = state)
      when conn_state != :failed do
    rtx? = Keyword.get(opts, :rtx?, false)

    # TODO: iterating over transceivers is not optimal
    # but this is, most likely, going to be refactored anyways
    state.transceivers
    |> Enum.with_index()
    |> Enum.find(fn {tr, _idx} -> tr.sender.track && tr.sender.track.id == track_id end)
    |> case do
      {tr, idx} ->
        # When RTP packet comes from another peer connection,
        # it can already have some extensions, in particular,
        # extensions that we didn't negotiate (consider simulcast and rid).
        # Remove these extensions and add ours.
        packet = ExRTP.Packet.remove_extensions(packet)

        {packet, state} =
          case state.twcc_extension_id do
            nil ->
              {packet, state}

            id ->
              twcc =
                ExRTP.Packet.Extension.TWCC.new(state.sent_packets)
                |> ExRTP.Packet.Extension.TWCC.to_raw(id)

              packet = ExRTP.Packet.add_extension(packet, twcc)

              state = %{state | sent_packets: state.sent_packets + 1 &&& 0xFFFF}
              {packet, state}
          end

        {packet, tr} = RTPTransceiver.send_packet(tr, packet, rtx?)

        if packet != <<>>, do: :ok = DTLSTransport.send_rtp(state.dtls_transport, packet)

        transceivers = List.replace_at(state.transceivers, idx, tr)
        state = %{state | transceivers: transceivers}

        {:noreply, state}

      nil ->
        Logger.warning("""
        Attempted to send packet to track with unrecognized id: #{inspect(track_id)}. \
        Ignoring.\
        """)

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_rtp, _track_id, _packet, _opts}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_pli, track_id, rid}, %{conn_state: conn_state} = state)
      when conn_state != :failed do
    state.transceivers
    |> Enum.with_index()
    |> Enum.find(fn {tr, _idx} -> tr.receiver.track.id == track_id end)
    |> case do
      {tr, idx} ->
        case RTPTransceiver.get_pli(tr, rid) do
          {pli, tr} ->
            encoded = ExRTCP.Packet.encode(pli)
            :ok = DTLSTransport.send_rtcp(state.dtls_transport, encoded)
            {:noreply, %{state | transceivers: List.replace_at(state.transceivers, idx, tr)}}

          :error ->
            Logger.warning(
              "Unable to send PLI for track #{inspect(track_id)}, rid #{inspect(rid)}"
            )

            {:noreply, state}
        end

      nil ->
        Logger.warning("Attempted to send PLI for non existent track #{inspect(track_id)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_pli, _track_id, _rid}, state) do
    {:noreply, state}
  end

  if Code.ensure_loaded?(ExSCTP) do
    @impl true
    def handle_cast({:send_data, channel_ref, data_type, data}, %{conn_state: conn_state} = state)
        when conn_state != :failed do
      {events, sctp_transport} =
        SCTPTransport.send(state.sctp_transport, channel_ref, data_type, data)

      handle_sctp_events(events, state)

      {:noreply, %{state | sctp_transport: sctp_transport}}
    end

    @impl true
    def handle_cast({:send_data, _channel_ref, _data_type, _data}, state) do
      {:noreply, state}
    end
  else
    @impl true
    def handle_cast({:send_data, _channel_ref, _data_type, _data}, _state) do
      raise("#{@sctp_error_text} #{@sctp_tip}")
    end
  end

  @impl true
  def handle_cast({:set_packet_loss, packet_loss}, state) do
    DTLSTransport.set_packet_loss(state.dtls_transport, packet_loss)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, {:connection_state_change, new_ice_state}}, state) do
    state = %{state | ice_state: new_ice_state}
    notify(state.owner, {:ice_connection_state_change, new_ice_state})
    next_conn_state = next_conn_state(new_ice_state, state.dtls_state)
    state = update_conn_state(state, next_conn_state)

    if new_ice_state == :connected do
      :ok = DTLSTransport.set_ice_connected(state.dtls_transport)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, {:gathering_state_change, new_gathering_state}}, state) do
    state = %{state | ice_gathering_state: new_gathering_state}
    notify(state.owner, {:ice_gathering_state_change, new_gathering_state})
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, {:new_candidate, candidate}}, state) do
    candidate = %ICECandidate{
      candidate: "candidate:" <> candidate,
      sdp_mid: "0",
      sdp_m_line_index: 0
      # username_fragment: "vx/1"
    }

    notify(state.owner, {:ice_candidate, candidate})

    {:noreply, state}
  end

  @impl true
  def handle_info({:dtls_transport, _pid, {:state_change, new_dtls_state}}, state) do
    notify(state.owner, {:dtls_transport_state_change, new_dtls_state})

    next_conn_state = next_conn_state(state.ice_state, new_dtls_state)

    state =
      %{state | dtls_state: new_dtls_state}
      |> update_conn_state(next_conn_state)
      |> maybe_connect_sctp()

    {:noreply, state}
  end

  @impl true
  def handle_info({:dtls_transport, _pid, {:rtp, data}}, state) do
    with {:ok, packet} <- ExRTP.Packet.decode(data),
         {:ok, mid, demuxer} <- Demuxer.demux_packet(state.demuxer, packet),
         {idx, t} <- find_transceiver(state.transceivers, mid) do
      # id == nil means we either did not negotiate TWCC, or it was turned off

      twcc_recorder =
        with id when id != nil <- state.twcc_extension_id,
             {:ok, raw_ext} <- ExRTP.Packet.fetch_extension(packet, id),
             {:ok, %{sequence_number: seq_no}} <- ExRTP.Packet.Extension.TWCC.from_raw(raw_ext) do
          # we always update the ssrc's for the one's from the latest packet
          # although this is not a necessity, the feedbacks are transport-wide
          %TWCCRecorder{
            state.twcc_recorder
            | media_ssrc: packet.ssrc,
              sender_ssrc: t.sender.ssrc
          }
          |> TWCCRecorder.record_packet(seq_no)
        else
          _other -> state.twcc_recorder
        end

      transceivers =
        case RTPTransceiver.receive_packet(t, packet, byte_size(data)) do
          {:ok, {rid, packet}, t} ->
            notify(state.owner, {:rtp, t.receiver.track.id, rid, packet})
            List.replace_at(state.transceivers, idx, t)

          {:error, t} ->
            List.replace_at(state.transceivers, idx, t)
        end

      state = %{
        state
        | demuxer: demuxer,
          transceivers: transceivers,
          twcc_recorder: twcc_recorder
      }

      {:noreply, state}
    else
      :error ->
        Logger.error("Unable to demux RTP packet")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Unable to handle RTP packet, reason: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:dtls_transport, _pid, {:rtcp, data}}, state) do
    case ExRTCP.CompoundPacket.decode(data) do
      {:ok, packets} ->
        {packets, state} =
          Enum.map_reduce(packets, state, fn packet, state ->
            {track_id, state} = handle_rtcp_packet(state, packet)
            {{track_id, packet}, state}
          end)

        notify(state.owner, {:rtcp, packets})
        {:noreply, state}

      {:error, _res} ->
        case data do
          <<2::2, _::1, count::5, ptype::8, _::binary>> ->
            Logger.warning("Failed to decode RTCP packet, type: #{ptype}, count: #{count}")

          _ ->
            Logger.warning("Failed to decode RTCP packet, packet is too short")
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:dtls_transport, _pid, {:data, data}}, state) do
    {events, sctp_transport} = SCTPTransport.handle_data(state.sctp_transport, data)
    handle_sctp_events(events, state)

    {:noreply, %{state | sctp_transport: sctp_transport}}
  end

  @impl true
  def handle_info(:send_twcc_feedback, %{twcc_recorder: twcc_recorder} = state) do
    Process.send_after(self(), :send_twcc_feedback, @twcc_interval)

    if twcc_recorder.media_ssrc != nil do
      {feedbacks, twcc_recorder} = TWCCRecorder.get_feedback(twcc_recorder)

      for feedback <- feedbacks do
        encoded = ExRTCP.Packet.encode(feedback)
        :ok = DTLSTransport.send_rtcp(state.dtls_transport, encoded)
      end

      {:noreply, %{state | twcc_recorder: twcc_recorder}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:send_reports, transceiver_id}, state) do
    transceiver =
      state.transceivers
      |> Enum.with_index()
      |> Enum.find(fn {tr, _idx} -> tr.id == transceiver_id end)

    transceivers =
      case transceiver do
        nil ->
          state.transceivers

        {tr, idx} ->
          {reports, tr} = RTPTransceiver.get_reports(tr)

          for report <- reports do
            encoded = ExRTCP.Packet.encode(report)
            :ok = DTLSTransport.send_rtcp(state.dtls_transport, encoded)
          end

          List.replace_at(state.transceivers, idx, tr)
      end

    {:noreply, %{state | transceivers: transceivers}}
  end

  @impl true
  def handle_info({:send_nacks, transceiver_id}, state) do
    transceiver =
      state.transceivers
      |> Enum.with_index()
      |> Enum.find(fn {tr, _idx} -> tr.id == transceiver_id end)

    transceivers =
      case transceiver do
        nil ->
          state.transceivers

        {tr, idx} ->
          {nacks, tr} = RTPTransceiver.get_nacks(tr)

          for nack <- nacks do
            encoded = ExRTCP.Packet.encode(nack)
            :ok = DTLSTransport.send_rtcp(state.dtls_transport, encoded)
          end

          List.replace_at(state.transceivers, idx, tr)
      end

    {:noreply, %{state | transceivers: transceivers}}
  end

  if Code.ensure_loaded?(ExSCTP) do
    @impl true
    def handle_info(:sctp_timeout, state) do
      {events, sctp_transport} = SCTPTransport.handle_timeout(state.sctp_transport)
      handle_sctp_events(events, state)

      {:noreply, %{state | sctp_transport: sctp_transport}}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.info("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, nil) do
    # we exit before finishing handle_continue
    Logger.debug("Closing peer connection with reason: #{inspect(reason)}")
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("Closing peer connection with reason: #{inspect(reason)}")
    :ok = DTLSTransport.stop(state.dtls_transport)
    :ok = state.ice_transport.stop(state.ice_pid)
  end

  defp generate_offer_mlines(%{current_local_desc: nil} = state, opts) do
    # if that's the first negotiation, generating an offer
    # is as simple as iterating over transceivers and
    # converting them into mlines
    next_mid = find_next_mid(state)

    {transceivers, next_mid} =
      Enum.map_reduce(state.transceivers, next_mid, fn
        # In the initial offer, we can't have stopped transceivers, only stopping ones.
        # Also, stopped transceivers are immediately removed.
        %{stopping: true, mid: nil} = tr, nm ->
          {tr, nm}

        %{stopping: false, mid: nil} = tr, nm ->
          tr = RTPTransceiver.assign_mid(tr, to_string(nm))
          # in the initial offer, mline_idx is the same as mid
          tr = %{tr | mline_idx: nm}
          {tr, nm + 1}
      end)

    mlines =
      transceivers
      |> Enum.reject(fn tr -> tr.stopping == true end)
      |> Enum.map(&RTPTransceiver.to_offer_mline(&1, opts))

    data_mline =
      if SCTPTransport.data_channels?(state.sctp_transport) do
        [generate_data_mline(next_mid, opts)]
      else
        []
      end

    {transceivers, mlines ++ data_mline}
  end

  defp generate_offer_mlines(state, opts) do
    last_answer = get_last_answer(state)
    next_mid = find_next_mid(state)
    next_mline_idx = Enum.count(last_answer.media)

    {transceivers, next_mid} =
      assign_mlines(state.transceivers, last_answer, next_mid, next_mline_idx)

    # The idea is as follows:
    # * Iterate over current local mlines
    # * If there is transceiver's mline that should replace
    # mline from the last offer/answer, do it (i.e. recycle free mline)
    # * If there is no transceiver's mline, just rewrite
    # mline from the offer/answer respecting its port number i.e. whether
    # it is rejected or not.
    # This is to preserve the same number of mlines
    # between subsequent offer/answer exchanges.
    # * At the end, add remaining transceiver mlines
    {_, current_local_desc} = state.current_local_desc

    final_mlines =
      current_local_desc.media
      |> Stream.with_index()
      |> Enum.map(fn {local_mline, idx} ->
        tr = Enum.find(transceivers, &(&1.mline_idx == idx))

        cond do
          SDPUtils.data_channel?(local_mline) ->
            {:mid, mid} = ExSDP.get_attribute(local_mline, :mid)
            generate_data_mline(mid, opts)

          tr == nil ->
            %{local_mline | port: 0}

          true ->
            RTPTransceiver.to_offer_mline(tr, opts)
        end
      end)

    fm_cnt = Enum.count(final_mlines)

    rem_mlines =
      transceivers
      |> Stream.filter(fn tr -> tr.mline_idx >= fm_cnt end)
      |> Enum.map(&RTPTransceiver.to_offer_mline(&1, opts))

    final_mlines = final_mlines ++ rem_mlines

    data_mline =
      if SCTPTransport.data_channels?(state.sctp_transport) and
           not Enum.any?(final_mlines, &SDPUtils.data_channel?(&1)) do
        [generate_data_mline(next_mid, opts)]
      else
        []
      end

    {transceivers, final_mlines ++ data_mline}
  end

  defp generate_data_mline(mid, opts) do
    attributes =
      [
        {:mid, mid},
        {:ice_ufrag, Keyword.fetch!(opts, :ice_ufrag)},
        {:ice_pwd, Keyword.fetch!(opts, :ice_pwd)},
        {:ice_options, Keyword.fetch!(opts, :ice_options)},
        {:fingerprint, Keyword.fetch!(opts, :fingerprint)},
        {:setup, Keyword.fetch!(opts, :setup)},
        {"sctp-port", "5000"}
      ]

    # NOTICE: Media.new puts fmtp (`webrtc-datachannel`) into a list
    %ExSDP.Media{
      ExSDP.Media.new("application", 9, "UDP/DTLS/SCTP", "webrtc-datachannel")
      | # mline must be followed by a cline, which must contain
        # the default value "IN IP4 0.0.0.0" (as there are no candidates yet)
        connection_data: [%ExSDP.ConnectionData{address: {0, 0, 0, 0}}]
    }
    |> ExSDP.add_attributes(attributes)
  end

  # next_mline_idx is future mline idx to use if there are no mlines to recycle
  # next_mid is the next free mid
  defp assign_mlines(
         transceivers,
         last_answer,
         next_mid,
         next_mline_idx,
         recycled_mlines \\ [],
         result \\ []
       )

  defp assign_mlines([], _, next_mid, _, _, result), do: {Enum.reverse(result), next_mid}

  defp assign_mlines(
         [%{mid: nil, mline_idx: nil, stopped: false} = tr | trs],
         last_answer,
         next_mid,
         next_mline_idx,
         recycled_mlines,
         result
       ) do
    tr = RTPTransceiver.assign_mid(tr, to_string(next_mid))

    case SDPUtils.find_free_mline_idx(last_answer, recycled_mlines) do
      nil ->
        tr = %{tr | mline_idx: next_mline_idx}
        result = [tr | result]
        assign_mlines(trs, last_answer, next_mid + 1, next_mline_idx + 1, recycled_mlines, result)

      idx ->
        tr = %{tr | mline_idx: idx}
        result = [tr | result]
        recycled_mlines = [idx | recycled_mlines]
        assign_mlines(trs, last_answer, next_mid + 1, next_mline_idx, recycled_mlines, result)
    end
  end

  defp assign_mlines([tr | trs], last_answer, next_mid, next_mline_idx, recycled_mlines, result) do
    assign_mlines(trs, last_answer, next_mid, next_mline_idx, recycled_mlines, [tr | result])
  end

  defp apply_local_description(%SessionDescription{type: type}, _state)
       when type in [:rollback, :pranswer],
       do: {:error, :"#{type}_not_implemented"}

  defp apply_local_description(%SessionDescription{type: type, sdp: raw_sdp}, state) do
    with {:ok, next_sig_state} <- next_signaling_state(state.signaling_state, :local, type),
         :ok <- check_altered(type, raw_sdp, state),
         {:ok, sdp} <- parse_sdp(raw_sdp),
         ice_lite <- SDPUtils.get_ice_lite(sdp) do
      # This has to be called before gathering candidates.
      if state.ice_transport.get_role(state.ice_pid) == nil do
        set_ice_role(state, :local, type, ice_lite)
      end

      if state.ice_gathering_state == :new do
        state.ice_transport.gather_candidates(state.ice_pid)
      end

      transceivers =
        sdp.media
        |> Enum.reject(&SDPUtils.data_channel?/1)
        |> process_mlines_local(state.transceivers, type, state.owner)

      # TODO re-think order of those functions
      # and demuxer update
      state =
        state
        |> set_description(:local, type, sdp)
        |> Map.replace!(:transceivers, transceivers)
        |> remove_stopped_transceivers(type, sdp)
        |> update_signaling_state(next_sig_state)
        |> Map.update!(:demuxer, &Demuxer.update(&1, sdp))

      if state.signaling_state == :stable do
        state = %{state | negotiation_needed: false}
        state = update_negotiation_needed(state)
        {:ok, state}
      else
        {:ok, state}
      end
    end
  end

  defp apply_remote_description(%SessionDescription{type: type}, _state)
       when type in [:rollback, :pranswer],
       do: {:error, :"#{type}_not_implemented"}

  defp apply_remote_description(%SessionDescription{type: type, sdp: raw_sdp}, state) do
    with {:ok, next_sig_state} <- next_signaling_state(state.signaling_state, :remote, type),
         {:ok, sdp} <- parse_sdp(raw_sdp),
         :ok <- SDPUtils.ensure_valid(sdp),
         {:ok, ice_creds} <- SDPUtils.get_ice_credentials(sdp),
         ice_lite <- SDPUtils.get_ice_lite(sdp),
         {:ok, {:fingerprint, {:sha256, peer_fingerprint}}} <- SDPUtils.get_cert_fingerprint(sdp),
         {:ok, dtls_role} <- SDPUtils.get_dtls_role(sdp) do
      config = Configuration.update(state.config, sdp)

      if state.ice_transport.get_role(state.ice_pid) == nil do
        set_ice_role(state, :remote, type, ice_lite)
      end

      twcc_id =
        (config.video_extensions ++ config.audio_extensions)
        |> Enum.find(&(&1.uri == @twcc_uri))
        |> then(&if(:twcc in config.features, do: &1.id, else: nil))

      state = %{state | config: config, twcc_extension_id: twcc_id}

      transceivers =
        sdp.media
        |> Enum.reject(&SDPUtils.data_channel?/1)
        |> process_mlines_remote(
          state.transceivers,
          type,
          Map.keys(state.demuxer.ssrc_to_mid),
          state.config,
          state.owner
        )

      # infer our role from the remote role
      dtls_role = if dtls_role in [:actpass, :passive], do: :active, else: :passive
      DTLSTransport.start_dtls(state.dtls_transport, dtls_role, peer_fingerprint)
      sctp_transport = SCTPTransport.set_role(state.sctp_transport, dtls_role)

      # ice_creds will be nil if all of the mlines in the description are rejected
      # in such case, if this is the first remote description, connection won't be established
      # TODO: this can result in ICE restart (when it should, e.g. when this is answer)
      case ice_creds do
        nil ->
          :ok

        {ice_ufrag, ice_pwd} ->
          :ok = state.ice_transport.set_remote_credentials(state.ice_pid, ice_ufrag, ice_pwd)

          for candidate <- SDPUtils.get_ice_candidates(sdp) do
            state.ice_transport.add_remote_candidate(state.ice_pid, candidate)
          end
      end

      state =
        state
        |> set_description(:remote, type, sdp)
        |> Map.replace!(:transceivers, transceivers)
        |> remove_stopped_transceivers(type, sdp)
        |> update_signaling_state(next_sig_state)
        |> Map.replace!(:sctp_transport, sctp_transport)
        |> Map.update!(:demuxer, &Demuxer.update(&1, sdp))
        |> maybe_connect_sctp()

      if state.signaling_state == :stable do
        state = %{state | negotiation_needed: false}
        state = update_negotiation_needed(state)
        {:ok, state}
      else
        {:ok, state}
      end
    else
      {:ok, {:fingerprint, {_hash_function, _fingerprint}}} ->
        {:error, :unsupported_cert_fingerprint_hash_function}

      {:error, _reason} = err ->
        err
    end
  end

  defp remove_stopped_transceivers(state, :answer, sdp) do
    # See W3C WebRTC 4.4.1.5-4.7.12
    transceivers =
      Enum.reject(state.transceivers, fn
        # This might result in unremovable transceiver when
        # we add and stop it before the first offer.
        # See https://github.com/w3c/webrtc-pc/issues/2923
        %{mid: nil} ->
          false

        tr ->
          mline = SDPUtils.find_mline_by_mid(sdp, tr.mid)
          tr.stopped == true and mline.port == 0
      end)

    %{state | transceivers: transceivers}
  end

  defp remove_stopped_transceivers(state, :offer, _sdp), do: state

  defp next_signaling_state(current_signaling_state, source, type)
  defp next_signaling_state(:stable, :remote, :offer), do: {:ok, :have_remote_offer}
  defp next_signaling_state(:stable, :local, :offer), do: {:ok, :have_local_offer}
  defp next_signaling_state(:stable, _, _), do: {:error, :invalid_state}
  defp next_signaling_state(:have_local_offer, :local, :offer), do: {:ok, :have_local_offer}
  defp next_signaling_state(:have_local_offer, :remote, :answer), do: {:ok, :stable}

  defp next_signaling_state(:have_local_offer, :remote, :pranswer),
    do: {:ok, :have_remote_pranswer}

  defp next_signaling_state(:have_local_offer, _, _), do: {:error, :invalid_state}
  defp next_signaling_state(:have_remote_offer, :remote, :offer), do: {:ok, :have_remote_offer}
  defp next_signaling_state(:have_remote_offer, :local, :answer), do: {:ok, :stable}
  defp next_signaling_state(:have_remote_offer, :local, :pranswer), do: {:ok, :stable}
  defp next_signaling_state(:have_remote_offer, _, _), do: {:error, :invalid_state}

  defp next_signaling_state(:have_local_pranswer, :local, :pranswer),
    do: {:ok, :have_local_pranswer}

  defp next_signaling_state(:have_local_pranswer, :local, :answer), do: {:ok, :stable}
  defp next_signaling_state(:have_local_pranswer, _, _), do: {:error, :invalid_state}

  defp next_signaling_state(:have_remote_pranswer, :remote, :pranswer),
    do: {:ok, :have_remote_pranswer}

  defp next_signaling_state(:have_remote_pranswer, :remote, :answer), do: {:ok, :stable}
  defp next_signaling_state(:have_remote_pranswer, _, _), do: {:error, :invalid_state}

  defp update_signaling_state(%{signaling_state: signaling_state} = state, signaling_state),
    do: state

  defp update_signaling_state(state, new_signaling_state) do
    Logger.debug(
      "Changing PeerConnection signaling state state: #{state.signaling_state} -> #{new_signaling_state}"
    )

    notify(state.owner, {:signaling_state_change, new_signaling_state})
    %{state | signaling_state: new_signaling_state}
  end

  defp check_altered(:offer, sdp, %{last_offer: sdp}), do: :ok
  defp check_altered(type, sdp, %{last_answer: sdp}) when type in [:answer, :pranswer], do: :ok
  defp check_altered(_type, _sdp, _state), do: {:error, :description_altered}

  defp set_description(state, :local, :answer, sdp) do
    # NOTICE: internally, we don't create SessionDescription
    # as it would require serialization of sdp
    %{
      state
      | current_local_desc: {:answer, sdp},
        current_remote_desc: state.pending_remote_desc,
        pending_local_desc: nil,
        pending_remote_desc: nil,
        # W3C 4.4.1.5 (.4.7.5.2) suggests setting these to "", not nil
        last_offer: nil,
        last_answer: nil
    }
  end

  defp set_description(state, :local, type, sdp) when type in [:offer, :pranswer] do
    %{state | pending_local_desc: {type, sdp}}
  end

  defp set_description(state, :remote, :answer, sdp) do
    %{
      state
      | current_remote_desc: {:answer, sdp},
        current_local_desc: state.pending_local_desc,
        pending_remote_desc: nil,
        pending_local_desc: nil,
        last_offer: nil,
        last_answer: nil
    }
  end

  defp set_description(state, :remote, type, sdp) when type in [:offer, :pranswer] do
    %{state | pending_remote_desc: {type, sdp}}
  end

  # See: https://www.w3.org/TR/webrtc/#ref-for-dfn-icerole-1
  defp set_ice_role(state, :local, :offer, false) do
    :ok = state.ice_transport.set_role(state.ice_pid, :controlling)
  end

  defp set_ice_role(state, :local, :offer, true) do
    :ok = state.ice_transport.set_role(state.ice_pid, :controlled)
  end

  defp set_ice_role(state, :remote, :offer, true) do
    :ok = state.ice_transport.set_role(state.ice_pid, :controlling)
  end

  defp set_ice_role(state, :remote, :offer, false) do
    :ok = state.ice_transport.set_role(state.ice_pid, :controlled)
  end

  defp parse_sdp(raw_sdp) do
    case ExSDP.parse(raw_sdp) do
      {:ok, _sdp} = res -> res
      {:error, _reason} -> {:error, :invalid_sdp_syntax}
    end
  end

  # See W3C WebRTC 4.4.1.4-4.7.10.1
  defp process_mlines_local(_mlines, transceivers, :offer, _owner), do: transceivers

  defp process_mlines_local([], transceivers, :answer, _owner), do: transceivers

  defp process_mlines_local([mline | mlines], transceivers, :answer, owner) do
    {:mid, mid} = ExSDP.get_attribute(mline, :mid)
    {idx, tr} = find_transceiver(transceivers, mid)
    direction = SDPUtils.get_media_direction(mline)

    # Consider scenario where the remote side offers
    # sendonly and we want to reject it by setting
    # transceiver's direction to inactive after SRD.
    # This should result in emitting track mute event.
    if direction in [:sendonly, :inactive] and
         tr.fired_direction in [:sendrecv, :recvonly] do
      notify(owner, {:track_muted, tr.receiver.track.id})
    end

    tr = %{tr | current_direction: direction, fired_direction: direction}

    # This is not defined in the W3C but see https://github.com/w3c/webrtc-pc/issues/2927
    tr =
      if SDPUtils.rejected?(mline),
        do: RTPTransceiver.stop(tr, on_track_ended(owner, tr.receiver.track.id)),
        else: tr

    transceivers = List.replace_at(transceivers, idx, tr)
    process_mlines_local(mlines, transceivers, :answer, owner)
  end

  # See W3C WebRTC 4.4.1.4-4.7.10.2
  defp process_mlines_remote(mlines, transceivers, sdp_type, demuxer_ssrcs, config, owner) do
    mlines_idx = Enum.with_index(mlines)
    do_process_mlines_remote(mlines_idx, transceivers, sdp_type, demuxer_ssrcs, config, owner)
  end

  defp do_process_mlines_remote([], transceivers, _sdp_type, _demuxer_ssrcs, _config, _owner),
    do: transceivers

  defp do_process_mlines_remote(
         [{mline, idx} | mlines],
         transceivers,
         sdp_type,
         demuxer_ssrcs,
         config,
         owner
       ) do
    direction =
      if SDPUtils.rejected?(mline),
        do: :inactive,
        else: SDPUtils.get_media_direction(mline) |> reverse_direction()

    {ssrc, rtx_ssrc} = generate_ssrcs(transceivers, demuxer_ssrcs)

    # Note: in theory we should update transceiver codecs
    # after processing remote track but this shouldn't have any impact
    {idx, tr} =
      case find_transceiver_from_remote(transceivers, mline) do
        {idx, tr} -> {idx, RTPTransceiver.update(tr, mline, config)}
        nil -> {nil, RTPTransceiver.from_mline(mline, idx, ssrc, rtx_ssrc, config)}
      end

    tr = process_remote_track(tr, direction, owner)
    tr = if sdp_type == :answer, do: %{tr | current_direction: direction}, else: tr

    tr =
      if SDPUtils.rejected?(mline),
        do: RTPTransceiver.stop(tr, on_track_ended(owner, tr.receiver.track.id)),
        else: tr

    case idx do
      nil ->
        transceivers = transceivers ++ [tr]
        do_process_mlines_remote(mlines, transceivers, sdp_type, demuxer_ssrcs, config, owner)

      idx ->
        transceivers = List.replace_at(transceivers, idx, tr)
        do_process_mlines_remote(mlines, transceivers, sdp_type, demuxer_ssrcs, config, owner)
    end
  end

  defp find_transceiver_from_remote(transceivers, mline) do
    {:mid, mid} = ExSDP.get_attribute(mline, :mid)

    case find_transceiver(transceivers, mid) do
      {idx, tr} -> {idx, tr}
      nil -> find_associable_transceiver(transceivers, mline)
    end
  end

  defp find_associable_transceiver(transceivers, mline) do
    transceivers
    |> Enum.with_index(fn tr, idx -> {idx, tr} end)
    |> Enum.find(fn {_idx, tr} -> RTPTransceiver.associable?(tr, mline) end)
  end

  # see W3C WebRTC 5.1.1
  defp process_remote_track(transceiver, direction, owner) do
    cond do
      direction in [:sendrecv, :recvonly] and
          transceiver.fired_direction not in [:sendrecv, :recvonly] ->
        notify(owner, {:track, transceiver.receiver.track})

      direction in [:sendonly, :inactive] and
          transceiver.fired_direction in [:sendrecv, :recvonly] ->
        notify(owner, {:track_muted, transceiver.receiver.track.id})

      true ->
        :ok
    end

    %{transceiver | fired_direction: direction}
  end

  defp reverse_direction(:recvonly), do: :sendonly
  defp reverse_direction(:sendonly), do: :recvonly
  defp reverse_direction(dir) when dir in [:sendrecv, :inactive], do: dir

  defp find_transceiver(transceivers, mid) do
    transceivers
    |> Enum.with_index(fn tr, idx -> {idx, tr} end)
    |> Enum.find(fn {_idx, tr} -> tr.mid == mid end)
  end

  defp find_next_mid(state) do
    # next mid must be unique, it's accomplished by looking for values
    # greater than any mid in remote description or our own transceivers
    crd_mids = get_desc_mids(state.current_remote_desc)
    tsc_mids = get_transceiver_mids(state.transceivers)

    Enum.max(crd_mids ++ tsc_mids, &>=/2, fn -> -1 end) + 1
  end

  defp get_desc_mids(nil), do: []

  defp get_desc_mids({_, remote_desc}) do
    Enum.flat_map(remote_desc.media, fn mline ->
      with {:mid, mid} <- ExSDP.get_attribute(mline, :mid),
           {mid, ""} <- Integer.parse(mid) do
        [mid]
      else
        _ -> []
      end
    end)
  end

  defp get_transceiver_mids(transceivers) do
    Enum.flat_map(transceivers, fn transceiver ->
      with mid when mid != nil <- transceiver.mid,
           {mid, ""} <- Integer.parse(mid) do
        [mid]
      else
        _ -> []
      end
    end)
  end

  defp get_last_answer(%{current_local_desc: {:answer, desc}}), do: desc
  defp get_last_answer(%{current_remote_desc: {:answer, desc}}), do: desc

  # TODO support :disconnected state - our ICE doesn't provide disconnected state for now
  # TODO support :closed state
  # the order of these clauses is important
  defp next_conn_state(ice_state, dtls_state)

  defp next_conn_state(ice_state, dtls_state) when ice_state == :failed or dtls_state == :failed,
    do: :failed

  defp next_conn_state(:failed, _dtls_state), do: :failed

  defp next_conn_state(_ice_state, :failed), do: :failed

  defp next_conn_state(:new, :new), do: :new

  defp next_conn_state(ice_state, dtls_state)
       when ice_state in [:new, :checking] or dtls_state in [:new, :connecting],
       do: :connecting

  defp next_conn_state(ice_state, :connected) when ice_state in [:connected, :completed],
    do: :connected

  defp update_conn_state(%{conn_state: conn_state} = state, conn_state), do: state

  defp update_conn_state(state, new_conn_state) do
    Logger.debug("Changing PeerConnection state: #{state.conn_state} -> #{new_conn_state}")
    notify(state.owner, {:connection_state_change, new_conn_state})
    %{state | conn_state: new_conn_state}
  end

  # If signaling state is not stable i.e. we are during negotiation,
  # don't fire negotiation needed notification.
  # We will do this when moving to the stable state as part of the
  # steps for setting remote description.
  defp update_negotiation_needed(%{signaling_state: sig_state} = state) when sig_state != :stable,
    do: state

  defp update_negotiation_needed(state) do
    negotiation_needed =
      tr_negotiation_needed?(state.transceivers, state) or
        dc_negotiation_needed?(state)

    cond do
      negotiation_needed == true and state.negotiation_needed == true ->
        state

      negotiation_needed == true ->
        notify(state.owner, :negotiation_needed)
        %{state | negotiation_needed: true}

      negotiation_needed == false ->
        # We need to clear the flag.
        # Consider scenario where we add a transceiver and then
        # remove it without performing negotiation.
        # At the end of the day, negotiation_needed flag has to be cleared.
        %{state | negotiation_needed: false}
    end
  end

  defp dc_negotiation_needed?(state) do
    first_channel = SCTPTransport.channel_count(state.sctp_transport) == 1

    has_channels =
      case state.current_local_desc do
        nil -> false
        {_, desc} -> Enum.any?(desc.media, &SDPUtils.data_channel?(&1))
      end

    first_channel and not has_channels
  end

  # We don't support MSIDs and stopping transceivers so
  # we only check 5.2 and 5.3 from 4.7.3#check-if-negotiation-is-needed
  # https://www.w3.org/TR/webrtc/#dfn-check-if-negotiation-is-needed
  defp tr_negotiation_needed?([], _), do: false

  defp tr_negotiation_needed?([tr | _transceivers], _state) when tr.mid == nil, do: true

  defp tr_negotiation_needed?([tr | transceivers], state) do
    {local_desc_type, local_desc} = state.current_local_desc
    {_, remote_desc} = state.current_remote_desc

    local_mline = SDPUtils.find_mline_by_mid(local_desc, tr.mid)
    remote_mline = SDPUtils.find_mline_by_mid(remote_desc, tr.mid)

    local_mline_direction = SDPUtils.get_media_direction(local_mline)
    remote_mline_direction = SDPUtils.get_media_direction(remote_mline) |> reverse_direction()

    cond do
      # Consider the following scenario:
      # 1. offerer offers sendrecv
      # 2. answerer answers with recvonly
      # 3. offerer changes from sendrecv to sendonly
      # We don't need to renegotiate in such a case.
      local_desc_type == :offer and
          tr.direction not in [local_mline_direction, remote_mline_direction] ->
        true

      # See https://github.com/w3c/webrtc-pc/issues/2919#issuecomment-1874081199
      local_desc_type == :answer and tr.direction != local_mline_direction ->
        true

      true ->
        tr_negotiation_needed?(transceivers, state)
    end
  end

  defp maybe_connect_sctp(%{current_remote_desc: {:answer, sdp}} = state) do
    has_channel? = Enum.any?(sdp.media, &SDPUtils.data_channel?(&1))
    connected? = state.dtls_state == :connected

    if has_channel? and connected? do
      {events, sctp_transport} = SCTPTransport.connect(state.sctp_transport)
      handle_sctp_events(events, state)
      %{state | sctp_transport: sctp_transport}
    else
      state
    end
  end

  defp maybe_connect_sctp(state), do: state

  defp handle_rtcp_packet(state, %ExRTCP.Packet.ReceiverReport{} = report) do
    with true <- :rtcp_reports in state.config.features,
         {:ok, mid} <- Demuxer.demux_ssrc(state.demuxer, report.ssrc),
         {_idx, transceiver} <- find_transceiver(state.transceivers, mid) do
      {transceiver.receiver.track.id, state}
    else
      _other ->
        {nil, state}
    end
  end

  defp handle_rtcp_packet(state, %ExRTCP.Packet.SenderReport{} = report) do
    with true <- :rtcp_reports in state.config.features,
         {:ok, mid} <- Demuxer.demux_ssrc(state.demuxer, report.ssrc),
         {idx, transceiver} <- find_transceiver(state.transceivers, mid) do
      transceiver = RTPTransceiver.receive_report(transceiver, report)
      transceivers = List.replace_at(state.transceivers, idx, transceiver)
      {transceiver.receiver.track.id, %{state | transceivers: transceivers}}
    else
      false ->
        {nil, state}

      _other ->
        Logger.warning("Unable to handle RTCP Sender Report, packet: #{inspect(report)}")
        {nil, state}
    end
  end

  defp handle_rtcp_packet(state, %ExRTCP.Packet.TransportFeedback.NACK{} = nack) do
    if :outbound_rtx in state.config.features do
      state.transceivers
      |> Enum.with_index()
      |> Enum.find(fn {tr, _idx} -> tr.sender.ssrc == nack.media_ssrc end)
      |> case do
        nil ->
          {nil, state}

        {%{sender: %{track: nil}}, _idx} ->
          {nil, state}

        # in case NACK was received, but RTX was not negotiated
        # as NACK and RTX are negotiated independently
        {%{sender: %{rtx_pt: nil}} = tr, _idx} ->
          {tr.sender.track.id, state}

        {tr, idx} ->
          {packets, tr} = RTPTransceiver.receive_nack(tr, nack)
          for packet <- packets, do: send_rtp(self(), tr.sender.track.id, packet, rtx?: true)
          transceivers = List.replace_at(state.transceivers, idx, tr)
          {tr.sender.track.id, %{state | transceivers: transceivers}}
      end
    else
      {nil, state}
    end
  end

  defp handle_rtcp_packet(state, %ExRTCP.Packet.PayloadFeedback.PLI{} = pli) do
    state.transceivers
    |> Enum.with_index()
    |> Enum.find(fn {tr, _idx} -> tr.sender.ssrc == pli.media_ssrc end)
    |> case do
      nil ->
        {nil, state}

      {%{sender: %{track: nil}}, _idx} ->
        {nil, state}

      {tr, idx} ->
        tr = RTPTransceiver.receive_pli(tr, pli)
        transceivers = List.replace_at(state.transceivers, idx, tr)
        {tr.sender.track.id, %{state | transceivers: transceivers}}
    end
  end

  defp handle_rtcp_packet(state, _packet), do: {nil, state}

  defp handle_sctp_events(events, state) do
    for event <- events do
      case event do
        {:transmit, packets} ->
          Enum.each(packets, &DTLSTransport.send_data(state.dtls_transport, &1))

        {:channel, channel} ->
          notify(state.owner, {:data_channel, channel})

        {:state_change, ref, new_state} ->
          notify(state.owner, {:data_channel_state_change, ref, new_state})

        {:data, ref, data} ->
          notify(state.owner, {:data, ref, data})
      end
    end
  end

  defp do_get_description(nil, _candidates), do: nil

  defp do_get_description({type, sdp}, candidates) do
    sdp = SDPUtils.add_ice_candidates(sdp, candidates)
    %SessionDescription{type: type, sdp: to_string(sdp)}
  end

  defp generate_ssrcs(state) do
    generate_ssrcs(state.transceivers, Map.keys(state.demuxer.ssrc_to_mid))
  end

  defp generate_ssrcs(transceivers, demuxer_ssrcs) do
    rtp_sender_ssrcs = Enum.map(transceivers, & &1.sender.ssrc)
    ssrcs = MapSet.new(demuxer_ssrcs ++ rtp_sender_ssrcs)
    ssrc = do_generate_ssrc(ssrcs)
    rtx_ssrc = do_generate_ssrc(MapSet.put(ssrcs, ssrc))
    {ssrc, rtx_ssrc}
  end

  # this is practically impossible so it's easier to raise
  # than to propagate the error up to the user
  defp do_generate_ssrc(ssrcs, max_attempts \\ 200)

  defp do_generate_ssrc(_ssrcs, 0), do: raise("Couldn't find free SSRC")

  defp do_generate_ssrc(ssrcs, max_attempts) do
    ssrc = Enum.random(0..((1 <<< 32) - 1))
    if ssrc in ssrcs, do: do_generate_ssrc(ssrcs, max_attempts - 1), else: ssrc
  end

  defp on_track_ended(owner, track_id), do: fn -> notify(owner, {:track_ended, track_id}) end

  defp notify(pid, msg), do: send(pid, {:ex_webrtc, self(), msg})
end
