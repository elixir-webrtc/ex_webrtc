defmodule ExWebRTC.PeerConnection do
  @moduledoc """
  Implementation of the [RTCPeerConnection](https://www.w3.org/TR/webrtc/#dom-rtcpeerconnection).
  """

  use GenServer

  import Bitwise

  require Logger

  alias __MODULE__.{Configuration, Demuxer, TWCCRecorder}

  alias ExWebRTC.{
    DefaultICETransport,
    DTLSTransport,
    ICECandidate,
    MediaStreamTrack,
    RTPTransceiver,
    RTPSender,
    RTPReceiver,
    SDPUtils,
    SessionDescription,
    Utils
  }

  @twcc_interval 100

  @type peer_connection() :: GenServer.server()

  @type offer_options() :: [ice_restart: boolean()]
  @type answer_options() :: []

  @type transceiver_options() :: [direction: RTPTransceiver.direction()]

  @typedoc """
  Messages sent by the ExWebRTC.
  """
  @type signal() ::
          {:ex_webrtc, pid(),
           :negotiation_needed
           | {:ice_candidate, ICECandidate.t()}
           | {:signaling_state_change, signaling_state()}
           | {:connection_state_change, connection_state()}
           | {:track, MediaStreamTrack.t()}
           | {:track_muted, MediaStreamTrack.id()}
           | {:track_ended, MediaStreamTrack.id()}
           | {:rtp, MediaStreamTrack.id(), ExRTP.Packet.t()}}

  @typedoc """
  Possible PeerConnection signaling states.

  For the exact meaning, refer to the [WebRTC W3C, section 4.3.1](https://www.w3.org/TR/webrtc/#dom-rtcsignalingstate)
  """
  @type signaling_state() :: :stable | :have_local_offer | :have_remote_offer

  @typedoc """
  Possible PeerConnection states.

  For the exact meaning, refer to the [WebRTC W3C, section 4.3.3](https://www.w3.org/TR/webrtc/#rtcpeerconnectionstate-enum)
  """
  @type connection_state() :: :closed | :failed | :disconnected | :new | :connecting | :connected

  @twcc_uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"

  #### API ####
  @doc """
  Returns a list of all running peer connections.
  """
  @spec get_all_running() :: [pid()]
  def get_all_running() do
    Registry.select(ExWebRTC.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.filter(fn pid -> Process.alive?(pid) end)
  end

  @spec start_link(Configuration.options()) :: GenServer.on_start()
  def start_link(options \\ []) do
    {controlling_process, options} = Keyword.pop(options, :controlling_process)
    controlling_process = controlling_process || self()
    configuration = Configuration.from_options!(options)
    GenServer.start_link(__MODULE__, {controlling_process, configuration})
  end

  @spec start(Configuration.options()) :: GenServer.on_start()
  def start(options \\ []) do
    configuration = Configuration.from_options!(options)
    GenServer.start(__MODULE__, {self(), configuration})
  end

  @spec controlling_process(peer_connection(), pid()) :: :ok
  def controlling_process(peer_connection, controlling_process) do
    GenServer.call(peer_connection, {:controlling_process, controlling_process})
  end

  @spec create_offer(peer_connection(), offer_options()) ::
          {:ok, SessionDescription.t()} | {:error, :invalid_state}
  def create_offer(peer_connection, options \\ []) do
    GenServer.call(peer_connection, {:create_offer, options})
  end

  @spec create_answer(peer_connection(), answer_options()) ::
          {:ok, SessionDescription.t()} | {:error, :invalid_state}
  def create_answer(peer_connection, options \\ []) do
    GenServer.call(peer_connection, {:create_answer, options})
  end

  @spec set_local_description(peer_connection(), SessionDescription.t()) ::
          :ok | {:error, atom()}
  def set_local_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_local_description, description})
  end

  @spec get_local_description(peer_connection()) :: SessionDescription.t() | nil
  def get_local_description(peer_connection) do
    GenServer.call(peer_connection, :get_local_description)
  end

  @spec get_current_local_description(peer_connection()) :: SessionDescription.t() | nil
  def get_current_local_description(peer_connection) do
    GenServer.call(peer_connection, :get_current_local_description)
  end

  @spec set_remote_description(peer_connection(), SessionDescription.t()) ::
          :ok | {:error, atom()}
  def set_remote_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_remote_description, description})
  end

  @spec get_remote_description(peer_connection()) :: SessionDescription.t() | nil
  def get_remote_description(peer_connection) do
    GenServer.call(peer_connection, :get_remote_description)
  end

  @spec get_current_remote_description(peer_connection()) :: SessionDescription.t() | nil
  def get_current_remote_description(peer_connection) do
    GenServer.call(peer_connection, :get_current_remote_description)
  end

  @spec add_ice_candidate(peer_connection(), ICECandidate.t()) ::
          :ok | {:error, :no_remote_description}
  def add_ice_candidate(peer_connection, candidate) do
    GenServer.call(peer_connection, {:add_ice_candidate, candidate})
  end

  @spec get_transceivers(peer_connection()) :: [RTPTransceiver.t()]
  def get_transceivers(peer_connection) do
    GenServer.call(peer_connection, :get_transceivers)
  end

  @spec add_transceiver(
          peer_connection(),
          RTPTransceiver.kind() | MediaStreamTrack.t(),
          transceiver_options()
        ) :: {:ok, RTPTransceiver.t()}
  def add_transceiver(peer_connection, kind_or_track, options \\ []) do
    GenServer.call(peer_connection, {:add_transceiver, kind_or_track, options})
  end

  @spec set_transceiver_direction(
          peer_connection(),
          RTPTransceiver.id(),
          RTPTransceiver.direction()
        ) :: :ok | {:error, :invalid_transceiver_id}
  def set_transceiver_direction(peer_connection, transceiver_id, direction)
      when direction in [:sendrecv, :sendonly, :recvonly, :inactive] do
    GenServer.call(peer_connection, {:set_transceiver_direction, transceiver_id, direction})
  end

  @spec stop_transceiver(peer_connection(), RTPTransceiver.id()) ::
          :ok | {:error, :invalid_transceiver_id}
  def stop_transceiver(peer_connection, transceiver_id) do
    GenServer.call(peer_connection, {:stop_transceiver, transceiver_id})
  end

  @spec add_track(peer_connection(), MediaStreamTrack.t()) :: {:ok, RTPSender.t()}
  def add_track(peer_connection, track) do
    GenServer.call(peer_connection, {:add_track, track})
  end

  @spec replace_track(peer_connection(), RTPSender.id(), MediaStreamTrack.t()) ::
          :ok | {:error, :invalid_sender_id | :invalid_track_type}
  def replace_track(peer_connection, sender_id, track) do
    GenServer.call(peer_connection, {:replace_track, sender_id, track})
  end

  @spec remove_track(peer_connection(), RTPSender.id()) :: :ok | {:error, :invalid_sender_id}
  def remove_track(peer_connection, sender_id) do
    GenServer.call(peer_connection, {:remove_track, sender_id})
  end

  @doc """
  Send an RTP packet to the remote peer using specified track or its id.
  """
  @spec send_rtp(
          peer_connection(),
          MediaStreamTrack.t() | MediaStreamTrack.id(),
          ExRTP.Packet.t()
        ) :: :ok
  def send_rtp(peer_connection, %MediaStreamTrack{id: track_id}, packet),
    do: send_rtp(peer_connection, track_id, packet)

  def send_rtp(peer_connection, track_id, packet) when is_integer(track_id) do
    GenServer.cast(peer_connection, {:send_rtp, track_id, packet})
  end

  @doc """
  Returns peer connection's statistics.

  See [RTCStatsReport](https://www.w3.org/TR/webrtc/#rtcstatsreport-object) for the output structure.
  """
  @spec get_stats(peer_connection()) :: %{(atom() | integer()) => map()}
  def get_stats(peer_connection) do
    GenServer.call(peer_connection, :get_stats)
  end

  @spec close(peer_connection()) :: :ok
  def close(peer_connection) do
    GenServer.stop(peer_connection)
  end

  #### CALLBACKS ####

  @impl true
  def init({owner, config}) do
    {:ok, _} = Registry.register(ExWebRTC.Registry, self(), self())
    ice_config = [stun_servers: config.ice_servers, ip_filter: config.ice_ip_filter, on_data: nil]
    {:ok, ice_pid} = DefaultICETransport.start_link(:controlled, ice_config)
    {:ok, dtls_transport} = DTLSTransport.start_link(DefaultICETransport, ice_pid)
    # route data to the DTLSTransport
    :ok = DefaultICETransport.on_data(ice_pid, dtls_transport)

    # TODO: should keep track of previous ice candidates
    # and add them to local description

    state = %{
      owner: owner,
      config: config,
      current_local_desc: nil,
      pending_local_desc: nil,
      current_remote_desc: nil,
      pending_remote_desc: nil,
      negotiation_needed: false,
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
      twcc_recorder: TWCCRecorder.new()
    }

    Process.send_after(self(), :send_twcc_feedback, @twcc_interval)
    notify(state.owner, {:connection_state_change, :new})
    notify(state.owner, {:signaling_state_change, :stable})

    {:ok, state}
  end

  @impl true
  def handle_call({:controlling_process, controlling_process}, _from, state) do
    state = %{state | owner: controlling_process}
    {:reply, :ok, state}
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

    mids =
      Enum.map(mlines, fn mline ->
        {:mid, mid} = ExSDP.get_attribute(mline, :mid)
        mid
      end)

    offer =
      offer
      |> ExSDP.add_attributes([
        %ExSDP.Attribute.Group{semantics: "BUNDLE", mids: mids},
        "extmap-allow-mixed"
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
  def handle_call({:create_answer, _options}, _from, %{signaling_state: ss} = state)
      when ss not in [:have_remote_offer, :have_local_pranswer] do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_call({:create_answer, _options}, _from, state) do
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
        {_ix, transceiver} = find_transceiver(state.transceivers, mid)
        RTPTransceiver.to_answer_mline(transceiver, mline, opts)
      end)

    mids =
      Enum.map(mlines, fn mline ->
        {:mid, mid} = ExSDP.get_attribute(mline, :mid)
        mid
      end)

    answer =
      answer
      |> ExSDP.add_attributes([
        %ExSDP.Attribute.Group{semantics: "BUNDLE", mids: mids},
        # always allow for mixing one- and two-byte RTP header extensions
        # TODO ensure this was also offered
        "extmap-allow-mixed"
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
  def handle_call(:get_current_remote_description, _from, state) do
    candidates = state.ice_transport.get_remote_candidates(state.ice_pid)
    desc = do_get_description(state.current_remote_desc, candidates)
    {:reply, desc, state}
  end

  @impl true
  def handle_call({:add_ice_candidate, _}, _from, %{current_remote_desc: nil} = state) do
    {:reply, {:error, :no_remote_description}, state}
  end

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
    {:reply, state.transceivers, state}
  end

  @impl true
  def handle_call({:add_transceiver, kind, options}, _from, state)
      when kind in [:audio, :video] do
    options = Keyword.put(options, :ssrc, generate_ssrc(state))
    transceiver = RTPTransceiver.new(kind, nil, state.config, options)
    state = %{state | transceivers: state.transceivers ++ [transceiver]}

    state = update_negotiation_needed(state)

    {:reply, {:ok, transceiver}, state}
  end

  @impl true
  def handle_call({:add_transceiver, %MediaStreamTrack{} = track, options}, _from, state) do
    options = Keyword.put(options, :ssrc, generate_ssrc(state))
    transceiver = RTPTransceiver.new(track.kind, track, state.config, options)
    state = %{state | transceivers: state.transceivers ++ [transceiver]}

    state = update_negotiation_needed(state)

    {:reply, {:ok, transceiver}, state}
  end

  @impl true
  def handle_call({:set_transceiver_direction, tr_id, direction}, _from, state) do
    idx = Enum.find_index(state.transceivers, fn tr -> tr.id == tr_id end)

    case idx do
      nil ->
        {:reply, {:error, :invalid_transceiver_id}, state}

      idx ->
        tr = Enum.at(state.transceivers, idx)
        tr = %RTPTransceiver{tr | direction: direction}
        transceivers = List.replace_at(state.transceivers, idx, tr)
        state = %{state | transceivers: transceivers}
        state = update_negotiation_needed(state)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:stop_transceiver, tr_id}, _from, state) do
    idx = Enum.find_index(state.transceivers, fn tr -> tr.id == tr_id end)

    case idx do
      nil ->
        {:reply, {:error, :invalid_transceiver_id}, state}

      idx ->
        tr = Enum.at(state.transceivers, idx)

        if tr.stopping do
          {:reply, :ok, state}
        else
          on_track_ended = on_track_ended(state.owner, tr.receiver.track.id)
          tr = RTPTransceiver.stop_sending_and_receiving(tr, on_track_ended)
          transceivers = List.replace_at(state.transceivers, idx, tr)
          state = %{state | transceivers: transceivers}
          state = update_negotiation_needed(state)
          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call({:add_track, %MediaStreamTrack{kind: kind} = track}, _from, state) do
    # we ignore the condition that sender has never been used to send
    free_transceiver_idx =
      Enum.find_index(state.transceivers, fn
        %RTPTransceiver{
          kind: ^kind,
          sender: %RTPSender{track: nil},
          current_direction: direction
        }
        when direction not in [:sendrecv, :sendonly] ->
          true

        _other ->
          false
      end)

    {transceivers, sender} =
      case free_transceiver_idx do
        nil ->
          options = [direction: :sendrecv, ssrc: generate_ssrc(state), added_by_add_track: true]
          tr = RTPTransceiver.new(kind, track, state.config, options)
          {state.transceivers ++ [tr], tr.sender}

        idx ->
          tr = Enum.at(state.transceivers, idx)
          tr = RTPTransceiver.add_track(tr, track, generate_ssrc(state))
          {List.replace_at(state.transceivers, idx, tr), tr.sender}
      end

    state = %{state | transceivers: transceivers}

    state = update_negotiation_needed(state)

    {:reply, {:ok, sender}, state}
  end

  @impl true
  def handle_call({:replace_track, sender_id, track}, _from, state) do
    tr_idx = Enum.find_index(state.transceivers, fn tr -> tr.sender.id == sender_id end)

    case tr_idx do
      nil ->
        {:reply, {:error, :invalid_sender_id}, state}

      tr_idx ->
        tr = Enum.at(state.transceivers, tr_idx)

        cond do
          track != nil and tr.kind != track.kind ->
            {:reply, {:error, :invalid_track_type}, state}

          tr.direction in [:sendrecv, :sendonly] ->
            tr = RTPTransceiver.replace_track(tr, track, generate_ssrc(state))
            transceivers = List.replace_at(state.transceivers, tr_idx, tr)
            state = %{state | transceivers: transceivers}
            {:reply, :ok, state}

          true ->
            # that's not compliant with the W3C but it's safer not
            # to allow for this until we have clear use case
            {:reply, {:error, :invalid_transceiver_direction}, state}
        end
    end
  end

  @impl true
  def handle_call({:remove_track, sender_id}, _from, state) do
    tr_idx =
      state.transceivers
      |> Stream.with_index()
      |> Enum.find(fn {tr, _idx} -> tr.sender.id == sender_id end)

    case tr_idx do
      nil ->
        {:reply, {:error, :invalid_sender_id}, state}

      {tr, _idx} when tr.sender.track == nil ->
        {:reply, :ok, state}

      {tr, idx} ->
        tr = RTPTransceiver.remove_track(tr)
        transceivers = List.replace_at(state.transceivers, idx, tr)
        state = %{state | transceivers: transceivers}
        state = update_negotiation_needed(state)
        {:reply, :ok, state}
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

    rtp_stats =
      Enum.flat_map(state.transceivers, fn tr ->
        tr_stats = %{kind: tr.kind, mid: tr.mid}

        case tr.current_direction do
          :sendonly ->
            stats = RTPSender.get_stats(tr.sender, timestamp)
            [Map.merge(stats, tr_stats)]

          :recvonly ->
            stats = RTPReceiver.get_stats(tr.receiver, timestamp)
            [Map.merge(stats, tr_stats)]

          :sendrecv ->
            sender_stats = RTPSender.get_stats(tr.sender, timestamp)
            receiver_stats = RTPReceiver.get_stats(tr.receiver, timestamp)

            [
              Map.merge(sender_stats, tr_stats),
              Map.merge(receiver_stats, tr_stats)
            ]

          _other ->
            []
        end
      end)
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
        ice_role: ice_stats.role,
        ice_local_ufrag: ice_stats.local_ufrag,
        dtls_state: state.dtls_state,
        bytes_sent: ice_stats.bytes_sent,
        bytes_received: ice_stats.bytes_received,
        packets_sent: ice_stats.packets_sent,
        packets_received: ice_stats.packets_received
      }
    }

    stats =
      stats
      |> Map.merge(local_cands)
      |> Map.merge(remote_cands)
      |> Map.merge(rtp_stats)

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:send_rtp, track_id, packet}, state) do
    # TODO: iterating over transceivers is not optimal
    # but this is, most likely, going to be refactored anyways
    {transceiver, idx} =
      state.transceivers
      |> Stream.with_index()
      |> Enum.find(fn
        {%{sender: %{track: %{id: id}}}, _idx} -> id == track_id
        _ -> false
      end)

    case transceiver do
      %RTPTransceiver{} ->
        {packet, state} =
          case Map.fetch(state.config.video_rtp_hdr_exts, @twcc_uri) do
            {:ok, %{id: id}} ->
              twcc =
                ExRTP.Packet.Extension.TWCC.new(state.sent_packets)
                |> ExRTP.Packet.Extension.TWCC.to_raw(id)

              packet = ExRTP.Packet.add_extension(packet, twcc)
              state = %{state | sent_packets: state.sent_packets + 1 &&& 0xFFFF}
              {packet, state}

            :error ->
              {packet, state}
          end

        {packet, transceiver} = RTPTransceiver.send_packet(transceiver, packet)
        :ok = DTLSTransport.send_rtp(state.dtls_transport, packet)

        transceivers = List.replace_at(state.transceivers, idx, transceiver)
        state = %{state | transceivers: transceivers}

        {:noreply, state}

      nil ->
        Logger.warning(
          "Attempted to send packet to track with unrecognized id: #{inspect(track_id)}"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ex_ice, _from, {:connection_state_change, new_ice_state}}, state) do
    state = %{state | ice_state: new_ice_state}
    next_conn_state = next_conn_state(new_ice_state, state.dtls_state)
    state = update_conn_state(state, next_conn_state)

    if new_ice_state == :connected do
      :ok = DTLSTransport.set_ice_connected(state.dtls_transport)
    end

    if next_conn_state == :failed do
      Logger.debug("Stopping PeerConnection")
      {:stop, {:shutdown, :conn_state_failed}, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ex_ice, _from, {:gathering_state_change, new_gathering_state}}, state) do
    state = %{state | ice_gathering_state: new_gathering_state}
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, {:new_candidate, candidate}}, state) do
    candidate = %ICECandidate{
      candidate: "candidate:" <> candidate,
      sdp_mid: 0,
      sdp_m_line_index: 0
      # username_fragment: "vx/1"
    }

    notify(state.owner, {:ice_candidate, candidate})

    {:noreply, state}
  end

  @impl true
  def handle_info({:dtls_transport, _pid, {:state_change, new_dtls_state}}, state) do
    state = %{state | dtls_state: new_dtls_state}
    next_conn_state = next_conn_state(state.ice_state, new_dtls_state)
    state = update_conn_state(state, next_conn_state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:dtls_transport, _pid, {:rtp, data}}, state) do
    with {:ok, demuxer, mid, packet} <- Demuxer.demux(state.demuxer, data),
         {idx, %RTPTransceiver{} = t} <- find_transceiver(state.transceivers, mid) do
      # we always update the ssrc's for the one's from the latest packet
      # although this is not a necessity, the feedbacks are transport-wide
      twcc_recorder = %TWCCRecorder{
        state.twcc_recorder
        | media_ssrc: packet.ssrc,
          sender_ssrc: t.sender.ssrc
      }

      twcc_recorder =
        with {:ok, %{id: id}} <- Map.fetch(state.config.video_rtp_hdr_exts, @twcc_uri),
             {:ok, raw_ext} <- ExRTP.Packet.fetch_extension(packet, id),
             {:ok, %{sequence_number: seq_no}} <- ExRTP.Packet.Extension.TWCC.from_raw(raw_ext) do
          TWCCRecorder.record_packet(twcc_recorder, seq_no)
        else
          _other -> twcc_recorder
        end

      t = RTPTransceiver.receive_packet(t, packet, byte_size(data))
      transceivers = List.replace_at(state.transceivers, idx, t)

      notify(state.owner, {:rtp, t.receiver.track.id, packet})

      state = %{
        state
        | demuxer: demuxer,
          transceivers: transceivers,
          twcc_recorder: twcc_recorder
      }

      {:noreply, state}
    else
      nil ->
        Logger.warning("Received RTP with unrecognized MID: #{inspect(data)}")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Unable to demux RTP, reason: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:dtls_transport, _pid, {:rtcp, data}}, state) do
    case ExRTCP.CompoundPacket.decode(data) do
      {:ok, packets} ->
        transceivers =
          Enum.reduce(packets, state.transceivers, fn packet, transceivers ->
            handle_report(packet, transceivers)
          end)

        notify(state.owner, {:rtcp, packets})
        {:noreply, %{state | transceivers: transceivers}}

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
  def handle_info({:send_report, type, transceiver_id}, state) do
    transceiver =
      state.transceivers
      |> Enum.with_index()
      |> Enum.find(fn {tr, _idx} -> tr.id == transceiver_id end)

    transceivers =
      case transceiver do
        nil ->
          state.transceivers

        {tr, idx} ->
          {report, tr} = RTPTransceiver.get_report(tr, type)

          if report != nil do
            encoded = ExRTCP.Packet.encode(report)
            :ok = DTLSTransport.send_rtcp(state.dtls_transport, encoded)
          end

          List.replace_at(state.transceivers, idx, tr)
      end

    {:noreply, %{state | transceivers: transceivers}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.info("OTHER MSG #{inspect(msg)}")
    {:noreply, state}
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

    {transceivers, _next_mid} =
      Enum.map_reduce(state.transceivers, next_mid, fn
        # In the initial offer, we can't have stopped transceivers, only stopping ones.
        # Also, stopped transceivers are immediately removed.
        %RTPTransceiver{stopping: true, mid: nil} = tr, nm ->
          {tr, nm}

        %RTPTransceiver{stopping: false, mid: nil} = tr, nm ->
          tr = RTPTransceiver.assign_mid(tr, to_string(nm))
          # in the initial offer, mline_idx is the same as mid
          tr = %RTPTransceiver{tr | mline_idx: nm}
          {tr, nm + 1}
      end)

    mlines =
      transceivers
      |> Enum.reject(fn tr -> tr.stopping == true end)
      |> Enum.map(&RTPTransceiver.to_offer_mline(&1, opts))

    {transceivers, mlines}
  end

  defp generate_offer_mlines(state, opts) do
    last_answer = get_last_answer(state)
    next_mid = find_next_mid(state)
    next_mline_idx = Enum.count(last_answer.media)

    transceivers = assign_mlines(state.transceivers, last_answer, next_mid, next_mline_idx)

    # The idea is as follows:
    # * Iterate ower current local mlines
    # * If there is transceiver's mline that should replace
    # mline from the last offer/answer, do it (i.e. recycle free mline)
    # * If there is no transceiver's mline, just rewrite
    # mline from the offer/answer respecting its port number i.e. whether
    # it is rejected or not.
    # This is to preserve the same number of mlines
    # between subsequent offer/anser exchanges.
    # * At the end, add remaining transceiver mlines
    {_, current_local_desc} = state.current_local_desc

    final_mlines =
      current_local_desc.media
      |> Stream.with_index()
      |> Enum.map(fn {local_mline, idx} ->
        case Enum.find(transceivers, &(&1.mline_idx == idx)) do
          # if there is no transceiver, the mline must have been rejected
          # in the past (in the offer or answer) so we always set the port to 0
          nil ->
            %{local_mline | port: 0}

          tr ->
            RTPTransceiver.to_offer_mline(tr, opts)
        end
      end)

    fm_cnt = Enum.count(final_mlines)

    rem_mlines =
      transceivers
      |> Stream.filter(fn tr -> tr.mline_idx >= fm_cnt end)
      |> Enum.map(&RTPTransceiver.to_offer_mline(&1, opts))

    final_mlines = final_mlines ++ rem_mlines

    {transceivers, final_mlines}
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

  defp assign_mlines([], _, _, _, _, result), do: Enum.reverse(result)

  defp assign_mlines(
         [%RTPTransceiver{mid: nil, mline_idx: nil, stopped: false} = tr | trs],
         last_answer,
         next_mid,
         next_mline_idx,
         recycled_mlines,
         result
       ) do
    tr = RTPTransceiver.assign_mid(tr, to_string(next_mid))

    case SDPUtils.find_free_mline_idx(last_answer, recycled_mlines) do
      nil ->
        tr = %RTPTransceiver{tr | mline_idx: next_mline_idx}
        result = [tr | result]
        assign_mlines(trs, last_answer, next_mid + 1, next_mline_idx + 1, recycled_mlines, result)

      idx ->
        tr = %RTPTransceiver{tr | mline_idx: idx}
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
         {:ok, sdp} <- parse_sdp(raw_sdp) do
      if state.ice_gathering_state == :new do
        state.ice_transport.gather_candidates(state.ice_pid)
      end

      transceivers = process_mlines_local(sdp.media, state.transceivers, type, state.owner)

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
         :ok <- SDPUtils.ensure_mid(sdp),
         :ok <- SDPUtils.ensure_bundle(sdp),
         :ok <- SDPUtils.ensure_rtcp_mux(sdp),
         {:ok, {ice_ufrag, ice_pwd}} <- SDPUtils.get_ice_credentials(sdp),
         {:ok, {:fingerprint, {:sha256, peer_fingerprint}}} <- SDPUtils.get_cert_fingerprint(sdp),
         {:ok, dtls_role} <- SDPUtils.get_dtls_role(sdp) do
      config = Configuration.update(state.config, sdp)
      state = %{state | config: config}

      transceivers =
        process_mlines_remote(sdp.media, state.transceivers, type, state.config, state.owner)

      # TODO: this can result in ICE restart (when it should, e.g. when this is answer)
      :ok = state.ice_transport.set_remote_credentials(state.ice_pid, ice_ufrag, ice_pwd)

      for candidate <- SDPUtils.get_ice_candidates(sdp) do
        state.ice_transport.add_remote_candidate(state.ice_pid, candidate)
      end

      # infer our role from the remote role
      dtls_role = if dtls_role in [:actpass, :passive], do: :active, else: :passive
      DTLSTransport.start_dtls(state.dtls_transport, dtls_role, peer_fingerprint)

      state =
        state
        |> set_description(:remote, type, sdp)
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
        %RTPTransceiver{mid: nil} ->
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
    # NOTICE: internaly, we don't create SessionDescription
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

  defp parse_sdp(raw_sdp) do
    case ExSDP.parse(raw_sdp) do
      {:ok, _sdp} = res -> res
      {:error, _reason} -> {:error, :invalid_sdp_syntax}
    end
  end

  # See W3C WebRTC 4.4.1.5-4.7.10.1
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

    tr = %RTPTransceiver{tr | current_direction: direction, fired_direction: direction}

    # This is not defined in the W3C but see https://github.com/w3c/webrtc-pc/issues/2927
    tr =
      if SDPUtils.rejected?(mline),
        do: RTPTransceiver.stop(tr, on_track_ended(owner, tr.receiver.track.id)),
        else: tr

    transceivers = List.replace_at(transceivers, idx, tr)
    process_mlines_local(mlines, transceivers, :answer, owner)
  end

  # See W3C WebRTC 4.4.1.5-4.7.10.2
  defp process_mlines_remote(mlines, transceivers, sdp_type, config, owner) do
    mlines_idx = Enum.with_index(mlines)
    do_process_mlines_remote(mlines_idx, transceivers, sdp_type, config, owner)
  end

  defp do_process_mlines_remote([], transceivers, _sdp_type, _config, _owner), do: transceivers

  defp do_process_mlines_remote([{mline, idx} | mlines], transceivers, sdp_type, config, owner) do
    direction =
      if SDPUtils.rejected?(mline),
        do: :inactive,
        else: SDPUtils.get_media_direction(mline) |> reverse_direction()

    # Note: in theory we should update transceiver codecs
    # after processing remote track but this shouldn't have any impact
    {idx, tr} =
      case find_transceiver_from_remote(transceivers, mline) do
        {idx, %RTPTransceiver{} = tr} -> {idx, RTPTransceiver.update(tr, mline, config)}
        nil -> {nil, RTPTransceiver.from_mline(mline, idx, config)}
      end

    tr = process_remote_track(tr, direction, owner)
    tr = if sdp_type == :answer, do: %RTPTransceiver{tr | current_direction: direction}, else: tr

    tr =
      if SDPUtils.rejected?(mline),
        do: RTPTransceiver.stop(tr, on_track_ended(owner, tr.receiver.track.id)),
        else: tr

    case idx do
      nil ->
        transceivers = transceivers ++ [tr]
        do_process_mlines_remote(mlines, transceivers, sdp_type, config, owner)

      idx ->
        transceivers = List.replace_at(transceivers, idx, tr)
        do_process_mlines_remote(mlines, transceivers, sdp_type, config, owner)
    end
  end

  defp find_transceiver_from_remote(transceivers, mline) do
    {:mid, mid} = ExSDP.get_attribute(mline, :mid)

    case find_transceiver(transceivers, mid) do
      {idx, %RTPTransceiver{} = tr} -> {idx, tr}
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

    %RTPTransceiver{transceiver | fired_direction: direction}
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
    # next mid must be unique, it's acomplished by looking for values
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
    negotiation_needed = negotiation_needed?(state.transceivers, state)

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

  # We don't support MSIDs and stopping transceivers so
  # we only check 5.2 and 5.3 from 4.7.3#check-if-negotiation-is-needed
  # https://www.w3.org/TR/webrtc/#dfn-check-if-negotiation-is-needed
  defp negotiation_needed?([], _), do: false

  defp negotiation_needed?([tr | _transceivers], _state) when tr.mid == nil, do: true

  defp negotiation_needed?([tr | transceivers], state) do
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
        negotiation_needed?(transceivers, state)
    end
  end

  defp handle_report(%ExRTCP.Packet.SenderReport{} = report, transceivers) do
    transceiver =
      transceivers
      |> Enum.with_index()
      |> Enum.find(fn {tr, _idx} -> tr.receiver.ssrc == report.ssrc end)

    case transceiver do
      nil ->
        transceivers

      {tr, idx} ->
        tr = RTPTransceiver.receive_report(tr, report)
        List.replace_at(transceivers, idx, tr)
    end
  end

  defp handle_report(_report, transceivers), do: transceivers

  defp do_get_description(nil, _candidates), do: nil

  defp do_get_description({type, sdp}, candidates) do
    sdp = SDPUtils.add_ice_candidates(sdp, candidates)
    %SessionDescription{type: type, sdp: to_string(sdp)}
  end

  defp generate_ssrc(state) do
    rtp_sender_ssrcs = Enum.map(state.transceivers, & &1.sender.ssrc)
    ssrcs = MapSet.new(Map.keys(state.demuxer.ssrc_to_mid) ++ rtp_sender_ssrcs)
    do_generate_ssrc(ssrcs, 200)
  end

  # this is practically impossible so it's easier to raise
  # than to propagate the error up to the user
  defp do_generate_ssrc(_ssrcs, 0), do: raise("Couldn't find free SSRC")

  defp do_generate_ssrc(ssrcs, max_attempts) do
    ssrc = Enum.random(0..((1 <<< 32) - 1))
    if ssrc in ssrcs, do: do_generate_ssrc(ssrcs, max_attempts - 1), else: ssrc
  end

  defp on_track_ended(owner, track_id), do: fn -> notify(owner, {:track_ended, track_id}) end

  defp notify(pid, msg), do: send(pid, {:ex_webrtc, self(), msg})
end
