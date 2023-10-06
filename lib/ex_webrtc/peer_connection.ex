defmodule ExWebRTC.PeerConnection do
  @moduledoc false

  use GenServer

  require Logger

  alias __MODULE__.Configuration
  alias ExICE.ICEAgent
  alias ExWebRTC.{IceCandidate, SessionDescription}

  import ExWebRTC.Utils

  @type peer_connection() :: GenServer.server()

  @type offer_options() :: [ice_restart: boolean()]
  @type answer_options() :: []

  @enforce_keys [:config, :owner]
  defstruct @enforce_keys ++
              [
                :current_local_desc,
                :pending_local_desc,
                :current_remote_desc,
                :pending_remote_desc,
                :ice_agent,
                :ice_state,
                :dtls_client,
                :dtls_buffered_packets,
                dtls_finished: false,
                transceivers: [],
                signaling_state: :stable
              ]

  @dummy_sdp """
  v=0
  o=- 7596991810024734139 2 IN IP4 127.0.0.1
  s=-
  t=0 0
  a=group:BUNDLE 0
  a=extmap-allow-mixed
  a=msid-semantic: WMS
  m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126
  c=IN IP4 0.0.0.0
  a=rtcp:9 IN IP4 0.0.0.0
  a=ice-ufrag:vx/1
  a=ice-pwd:ldFUrCsXvndFY2L1u0UQ7ikf
  a=ice-options:trickle
  a=fingerprint:sha-256 76:61:77:1E:7C:2E:BB:CD:19:B5:27:4E:A7:40:84:06:6B:17:97:AB:C4:61:90:16:EE:96:9F:9E:BD:42:96:3D
  a=setup:passive
  a=mid:0
  a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
  a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
  a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
  a=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid
  a=recvonly
  a=rtcp-mux
  a=rtpmap:111 opus/48000/2
  a=rtcp-fb:111 transport-cc
  a=fmtp:111 minptime=10;useinbandfec=1
  a=rtpmap:63 red/48000/2
  a=fmtp:63 111/111
  a=rtpmap:9 G722/8000
  a=rtpmap:0 PCMU/8000
  a=rtpmap:8 PCMA/8000
  a=rtpmap:13 CN/8000
  a=rtpmap:110 telephone-event/48000
  a=rtpmap:126 telephone-event/8000
  """

  #### API ####

  def start_link(configuration \\ []) do
    GenServer.start_link(__MODULE__, {self(), configuration})
  end

  def start(configuration \\ []) do
    GenServer.start(__MODULE__, {self(), configuration})
  end

  @spec create_offer(peer_connection(), offer_options()) ::
          {:ok, SessionDescription.t()} | {:error, :TODO}
  def create_offer(peer_connection, options \\ []) do
    GenServer.call(peer_connection, {:create_offer, options})
  end

  @spec create_answer(peer_connection(), answer_options()) ::
          {:ok, SessionDescription.t()} | {:error, :TODO}
  def create_answer(peer_connection, options \\ []) do
    GenServer.call(peer_connection, {:create_answer, options})
  end

  @spec set_local_description(peer_connection(), SessionDescription.t()) ::
          :ok | {:error, :TODO}
  def set_local_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_local_description, description})
  end

  @spec set_remote_description(peer_connection(), SessionDescription.t()) ::
          :ok | {:error, :TODO}
  def set_remote_description(peer_connection, description) do
    GenServer.call(peer_connection, {:set_remote_description, description})
  end

  @spec add_ice_candidate(peer_connection(), IceCandidate.t()) ::
          :ok | {:error, :TODO}
  def add_ice_candidate(peer_connection, candidate) do
    GenServer.call(peer_connection, {:add_ice_candidate, candidate})
  end

  #### CALLBACKS ####

  @impl true
  def init({owner, config}) do
    config = struct(Configuration, config)
    :ok = Configuration.check_support(config)

    # ATM, ExICE does not support relay via TURN
    stun_servers =
      config.ice_servers
      |> Enum.flat_map(&if(is_list(&1.urls), do: &1.urls, else: [&1.urls]))
      |> Enum.filter(&String.starts_with?(&1, "stun:"))

    {:ok, ice_agent} = ICEAgent.start_link(:controlled, stun_servers: stun_servers)
    {:ok, dtls_client} = ExDTLS.start_link(client_mode: false, dtls_srtp: true)

    state = %__MODULE__{
      owner: owner,
      config: config,
      ice_agent: ice_agent,
      dtls_client: dtls_client
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_offer, _options}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:create_answer, _options}, _from, state)
      when state.signaling_state in [:have_remote_offer, :have_local_pranswer] do
    {:ok, ufrag, pwd} = ICEAgent.get_local_credentials(state.ice_agent)

    {:ok, dtls_fingerprint} = ExDTLS.get_cert_fingerprint(state.dtls_client)

    sdp = ExSDP.parse!(@dummy_sdp)
    media = hd(sdp.media)

    attrs =
      Enum.map(media.attributes, fn
        {:ice_ufrag, _} ->
          {:ice_ufrag, ufrag}

        {:ice_pwd, _} ->
          {:ice_pwd, pwd}

        {:fingerprint, {hash_function, _}} ->
          {:fingerprint, {hash_function, hex_dump(dtls_fingerprint)}}

        other ->
          other
      end)

    media = Map.put(media, :attributes, attrs)

    sdp =
      sdp
      |> Map.put(:media, [media])
      |> to_string()

    desc = %SessionDescription{type: :answer, sdp: sdp}
    {:reply, {:ok, desc}, state}
  end

  def handle_call({:create_answer, _options}, _from, state) do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_call({:set_local_description, _desc}, _from, state) do
    # temporary, so the dialyzer will shut up
    maybe_next_state(:stable, :local, :offer)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_remote_description, desc}, _from, state) do
    %SessionDescription{type: type, sdp: sdp} = desc

    case type do
      :rollback ->
        {:reply, :ok, state}

      other_type ->
        with {:ok, next_state} <- maybe_next_state(state.signaling_state, :remote, other_type),
             {:ok, sdp} <- ExSDP.parse(sdp),
             {:ok, state} <- apply_remote_description(other_type, sdp, state) do
          {:reply, :ok, %{state | signaling_state: next_state}}
        else
          error -> {:reply, error, state}
        end
    end
  end

  def handle_call({:add_ice_candidate, candidate}, _from, state) do
    with "candidate:" <> attr <- candidate.candidate do
      ICEAgent.add_remote_candidate(state.ice_agent, attr)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, :connected}, state) do
    if state.dtls_buffered_packets do
      Logger.debug("Sending buffered DTLS packets")
      ICEAgent.send_data(state.ice_agent, state.dtls_buffered_packets)
    end

    {:noreply, %__MODULE__{state | ice_state: :connected, dtls_buffered_packets: nil}}
  end

  @impl true
  def handle_info({:ex_ice, _from, {:new_candidate, candidate}}, state) do
    candidate = %IceCandidate{
      candidate: "candidate:" <> candidate,
      sdp_mid: 0,
      sdp_m_line_index: 0
      # username_fragment: "vx/1"
    }

    send(state.owner, {:ex_webrtc, {:ice_candidate, candidate}})

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, {:data, data}}, %{dtls_finished: false} = state) do
    case ExDTLS.process(state.dtls_client, data) do
      {:handshake_packets, packets} when state.ice_state in [:connected, :completed] ->
        :ok = ICEAgent.send_data(state.ice_agent, packets)

      {:handshake_packets, packets} ->
        Logger.debug("""
        Generated local DTLS packets but ICE is not in the connected or completed state yet.
        We will send those packets once ICE is ready.
        """)

        {:noreply, %__MODULE__{state | dtls_buffered_packets: packets}}

      {:handshake_finished, _keying_material, packets} ->
        Logger.debug("DTLS handshake finished")
        ICEAgent.send_data(state.ice_agent, packets)
        {:noreply, %__MODULE__{state | dtls_finished: true}}

      {:handshake_finished, _keying_material} ->
        Logger.debug("DTLS handshake finished")
        {:noreply, %__MODULE__{state | dtls_finished: true}}

      :handshake_want_read ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:ex_dtls, _from, {:retransmit, packets}}, state)
      when state.ice_state in [:connected, :completed] do
    ICEAgent.send_data(state.ice_agent, packets)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:ex_dtls, _from, {:retransmit, packets}},
        %{dtls_buffered_packets: packets} = state
      ) do
    # we got DTLS packets from the other side but
    # we haven't established ICE connection yet so 
    # packets to retransmit have to be the same as dtls_buffered_packets
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.info("OTHER MSG #{inspect(msg)}")
    {:noreply, state}
  end

  defp apply_remote_description(_type, sdp, state) do
    # TODO apply steps listed in RFC 8829 5.10
    media = hd(sdp.media)
    {:ice_ufrag, ufrag} = ExSDP.Media.get_attribute(media, :ice_ufrag)
    {:ice_pwd, pwd} = ExSDP.Media.get_attribute(media, :ice_pwd)

    :ok = ICEAgent.set_remote_credentials(state.ice_agent, ufrag, pwd)
    :ok = ICEAgent.gather_candidates(state.ice_agent)

    {:ok, %{state | current_remote_desc: sdp}}
  end

  # Signaling state machine, RFC 8829 3.2
  defp maybe_next_state(:stable, :remote, :offer), do: {:ok, :have_remote_offer}
  defp maybe_next_state(:stable, :local, :offer), do: {:ok, :have_local_offer}
  defp maybe_next_state(:stable, _, _), do: {:error, :invalid_transition}

  defp maybe_next_state(:have_local_offer, :local, :offer), do: {:ok, :have_local_offer}
  defp maybe_next_state(:have_local_offer, :remote, :answer), do: {:ok, :stable}
  defp maybe_next_state(:have_local_offer, :remote, :pranswer), do: {:ok, :have_remote_pranswer}
  defp maybe_next_state(:have_local_offer, _, _), do: {:error, :invalid_transition}

  defp maybe_next_state(:have_remote_offer, :remote, :offer), do: {:ok, :have_remote_offer}
  defp maybe_next_state(:have_remote_offer, :local, :answer), do: {:ok, :stable}
  defp maybe_next_state(:have_remote_offer, :local, :pranswer), do: {:ok, :stable}
  defp maybe_next_state(:have_remote_offer, _, _), do: {:error, :invalid_transition}

  defp maybe_next_state(:have_local_pranswer, :local, :pranswer), do: {:ok, :have_local_pranswer}
  defp maybe_next_state(:have_local_pranswer, :local, :answer), do: {:ok, :stable}
  defp maybe_next_state(:have_local_pranswer, _, _), do: {:error, :invalid_transition}

  defp maybe_next_state(:have_remote_pranswer, :remote, :pranswer),
    do: {:ok, :have_remote_pranswer}

  defp maybe_next_state(:have_remote_pranswer, :remote, :answer), do: {:ok, :stable}
  defp maybe_next_state(:have_remote_pranswer, _, _), do: {:error, :invalid_transition}
end
