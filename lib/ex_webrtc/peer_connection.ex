defmodule ExWebRTC.PeerConnection do
  @moduledoc false

  use GenServer

  alias __MODULE__.Configuration
  alias ExICE.ICEAgent
  alias ExWebRTC.{IceCandidate, SessionDescription}

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
                transceivers: [],
                signaling_state: :stable
              ]

  @dummy_sdp "
  v=0\r\n
  o=- 7596991810024734139 2 IN IP4 127.0.0.1\r\n
  s=-\r\n
  t=0 0\r\n
  a=group:BUNDLE 0\r\n
  a=extmap-allow-mixed\r\n
  a=msid-semantic: WMS\r\n
  m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126\r\n
  c=IN IP4 0.0.0.0\r\n
  a=rtcp:9 IN IP4 0.0.0.0\r\n
  a=ice-ufrag:vx/1\r\n
  a=ice-pwd:ldFUrCsXvndFY2L1u0UQ7ikf\r\n
  a=ice-options:trickle\r\n
  a=fingerprint:sha-256 76:61:77:1E:7C:2E:BB:CD:19:B5:27:4E:A7:40:84:06:6B:17:97:AB:C4:61:90:16:EE:96:9F:9E:BD:42:96:3D\r\n
  a=setup:passive\r\n
  a=mid:0\r\n
  a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n
  a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\n
  a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n
  a=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid\r\n
  a=recvonly\r\n
  a=rtcp-mux\r\n
  a=rtpmap:111 opus/48000/2\r\n
  a=rtcp-fb:111 transport-cc\r\n
  a=fmtp:111 minptime=10;useinbandfec=1\r\n
  a=rtpmap:63 red/48000/2\r\n
  a=fmtp:63 111/111\r\n
  a=rtpmap:9 G722/8000\r\n
  a=rtpmap:0 PCMU/8000\r\n
  a=rtpmap:8 PCMA/8000\r\n
  a=rtpmap:13 CN/8000\r\n
  a=rtpmap:110 telephone-event/48000\r\n
  a=rtpmap:126 telephone-event/8000\r\n
  "

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

    state = %__MODULE__{owner: owner, config: config, ice_agent: ice_agent}
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

    sdp = ExSDP.parse!(@dummy_sdp)
    media = hd(sdp.media)

    attrs =
      Enum.map(media.attributes, fn
        {:ice_ufrag, _} -> {:ice_ufrag, ufrag}
        {:ice_pwd, _} -> {:ice_pwd, pwd}
        other -> other
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
  def handle_info(msg, state) do
    IO.inspect(msg, label: :OTHER_MSG)
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
