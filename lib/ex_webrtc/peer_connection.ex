defmodule ExWebRTC.PeerConnection do
  @moduledoc false

  use GenServer

  require Logger

  alias __MODULE__.Configuration
  alias ExICE.ICEAgent

  alias ExWebRTC.{
    DTLSTransport,
    IceCandidate,
    MediaStreamTrack,
    RTPTransceiver,
    SDPUtils,
    SessionDescription,
    Utils
  }

  @type peer_connection() :: GenServer.server()

  @type offer_options() :: [ice_restart: boolean()]
  @type answer_options() :: []

  @type transceiver_options() :: [
          direction: RTPTransceiver.direction(),
          send_encodings: [:TODO],
          streams: [:TODO]
        ]

  @enforce_keys [:config, :owner]
  defstruct @enforce_keys ++
              [
                :current_local_desc,
                :pending_local_desc,
                :current_remote_desc,
                :pending_remote_desc,
                :ice_agent,
                :ice_state,
                :dtls_transport,
                transceivers: [],
                signaling_state: :stable,
                last_offer: nil,
                last_answer: nil
              ]

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

  @spec get_transceivers(peer_connection()) :: [RTPTransceiver.t()]
  def get_transceivers(peer_connection) do
    GenServer.call(peer_connection, :get_transceivers)
  end

  @spec add_transceiver(
          peer_connection(),
          RTPTransceiver.kind() | MediaStreamTrack.t(),
          transceiver_options()
        ) :: {:ok, RTPTransceiver.t()} | {:error, :TODO}
  def add_transceiver(peer_connection, track_or_kind, options \\ []) do
    GenServer.call(peer_connection, {:add_transceiver, track_or_kind, options})
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
    dtls_transport = DTLSTransport.new(ice_agent)

    state = %__MODULE__{
      owner: owner,
      config: config,
      ice_agent: ice_agent,
      dtls_transport: dtls_transport
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_offer, _options}, _from, %{signaling_state: ss} = state)
      when ss not in [:stable, :have_local_offer] do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_call({:create_offer, options}, _from, state) do
    # TODO: handle subsequent offers

    if Keyword.get(options, :ice_restart, false) do
      :ok = ICEAgent.restart(state.ice_agent)
    end

    next_mid = find_next_mid(state)
    transceivers = assign_mids(state.transceivers, next_mid)

    {:ok, ice_ufrag, ice_pwd} = ICEAgent.get_local_credentials(state.ice_agent)

    offer =
      %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
      # we support trickle ICE only
      |> ExSDP.add_attribute({:ice_options, "trickle"})

    config =
      [
        ice_ufrag: ice_ufrag,
        ice_pwd: ice_pwd,
        ice_options: "trickle",
        fingerprint: {:sha256, Utils.hex_dump(state.dtls_transport.fingerprint)},
        setup: :actpass,
        rtcp: true
      ]

    mlines =
      Enum.map(transceivers, fn transceiver ->
        SDPUtils.to_offer_mline(transceiver, config)
      end)

    mids =
      Enum.map(mlines, fn mline ->
        {:mid, mid} = ExSDP.Media.get_attribute(mline, :mid)
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

    {:ok, ice_ufrag, ice_pwd} = ICEAgent.get_local_credentials(state.ice_agent)

    answer =
      %ExSDP{ExSDP.new() | timing: %ExSDP.Timing{start_time: 0, stop_time: 0}}
      # we only support trickle ICE, so non-trickle offers should be rejected earlier
      |> ExSDP.add_attribute({:ice_options, "trickle"})

    config =
      [
        ice_ufrag: ice_ufrag,
        ice_pwd: ice_pwd,
        ice_options: "trickle",
        fingerprint: {:sha256, Utils.hex_dump(state.dtls_transport.fingerprint)},
        setup: :active
      ]

    # TODO: rejected media sections
    mlines =
      Enum.map(remote_offer.media, fn mline ->
        {:mid, mid} = ExSDP.Media.get_attribute(mline, :mid)
        {_ix, transceiver} = RTPTransceiver.find_by_mid(state.transceivers, mid)
        SDPUtils.get_answer_mline(mline, transceiver, config)
      end)

    mids =
      Enum.map(mlines, fn mline ->
        {:mid, mid} = ExSDP.Media.get_attribute(mline, :mid)
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
    %SessionDescription{type: type, sdp: sdp} = desc

    case type do
      :rollback ->
        {:reply, :ok, state}

      other_type ->
        with {:ok, next_state} <- maybe_next_state(state.signaling_state, :local, other_type),
             :ok <- check_desc_altered(type, sdp, state),
             {:ok, sdp} <- ExSDP.parse(sdp),
             {:ok, state} <- apply_local_description(other_type, sdp, state) do
          {:reply, :ok, %{state | signaling_state: next_state}}
        else
          error -> {:reply, error, state}
        end
    end
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

  @impl true
  def handle_call({:add_ice_candidate, candidate}, _from, state) do
    with "candidate:" <> attr <- candidate.candidate do
      ICEAgent.add_remote_candidate(state.ice_agent, attr)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_transceivers, _from, state) do
    {:reply, state.transceivers, state}
  end

  @impl true
  def handle_call({:add_transceiver, :audio, options}, _from, state) do
    # TODO: proper implementation, change the :audio above to track_or_kind
    direction = Keyword.get(options, :direction, :sendrcv)

    # hardcoded audio codec
    codecs = [
      %ExWebRTC.RTPCodecParameters{
        payload_type: 111,
        mime_type: "audio/opus",
        clock_rate: 48_000,
        channels: 2
      }
    ]

    transceiver = %RTPTransceiver{mid: nil, direction: direction, kind: :audio, codecs: codecs}
    transceivers = List.insert_at(state.transceivers, -1, transceiver)
    {:reply, {:ok, transceiver}, %{state | transceivers: transceivers}}
  end

  @impl true
  def handle_info({:ex_ice, _from, :connected}, state) do
    dtls = DTLSTransport.update_ice_state(state.dtls_transport, :connected)
    {:noreply, %__MODULE__{state | dtls_transport: dtls, ice_state: :connected}}
  end

  @impl true
  def handle_info({:ex_ice, _from, {:new_candidate, candidate}}, state) do
    candidate = %IceCandidate{
      candidate: "candidate:" <> candidate,
      sdp_mid: 0,
      sdp_m_line_index: 0
      # username_fragment: "vx/1"
    }

    notify(state.owner, {:ice_candidate, candidate})

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, {:data, data}}, state)
      when not state.dtls_transport.finished do
    dtls = DTLSTransport.process_data(state.dtls_transport, data)
    {:noreply, %__MODULE__{state | dtls_transport: dtls}}
  end

  @impl true
  def handle_info({:ex_dtls, _from, msg}, state) do
    dtls = DTLSTransport.handle_info(state.dtls_transport, msg)
    {:noreply, %__MODULE__{state | dtls_transport: dtls}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.info("OTHER MSG #{inspect(msg)}")
    {:noreply, state}
  end

  defp apply_local_description(type, sdp, state) do
    new_transceivers = update_local_transceivers(type, state.transceivers, sdp)
    state = set_description(:local, type, sdp, state)

    dtls =
      if type == :answer do
        {:setup, setup} = ExSDP.Media.get_attribute(hd(sdp.media), :setup)
        DTLSTransport.start(state.dtls_transport, setup)
      else
        state.dtls_transport
      end

    {:ok, %{state | transceivers: new_transceivers, dtls_transport: dtls}}
  end

  defp update_local_transceivers(:offer, transceivers, _sdp) do
    # TODO: at the moment, we assign mids in create_offer
    transceivers
  end

  defp update_local_transceivers(:answer, transceivers, _sdp) do
    transceivers
  end

  defp apply_remote_description(type, sdp, state) do
    # TODO apply steps listed in RFC 8829 5.10
    with :ok <- SDPUtils.ensure_mid(sdp),
         :ok <- SDPUtils.ensure_bundle(sdp),
         {:ok, {ice_ufrag, ice_pwd}} <- SDPUtils.get_ice_credentials(sdp),
         {:ok, new_transceivers} <- update_remote_transceivers(state.transceivers, sdp) do
      :ok = ICEAgent.set_remote_credentials(state.ice_agent, ice_ufrag, ice_pwd)
      :ok = ICEAgent.gather_candidates(state.ice_agent)

      new_remote_tracks =
        new_transceivers
        # only take new transceivers that can receive tracks
        |> Enum.filter(fn tr ->
          RTPTransceiver.find_by_mid(state.transceivers, tr.mid) == nil and
            tr.direction in [:recvonly, :sendrecv]
        end)
        |> Enum.map(fn tr -> MediaStreamTrack.from_transceiver(tr) end)

      for track <- new_remote_tracks do
        notify(state.owner, {:track, track})
      end

      state = set_description(:remote, type, sdp, state)

      dtls =
        if type == :answer do
          {:setup, setup} = ExSDP.Media.get_attribute(hd(sdp.media), :setup)

          setup =
            case setup do
              :active -> :passive
              :passive -> :active
            end

          DTLSTransport.start(state.dtls_transport, setup)
        else
          state.dtls_transport
        end

      {:ok, %{state | transceivers: new_transceivers, dtls_transport: dtls}}
    else
      error -> error
    end
  end

  defp update_remote_transceivers(transceivers, sdp) do
    Enum.reduce_while(sdp.media, {:ok, transceivers}, fn mline, {:ok, transceivers} ->
      case ExSDP.Media.get_attribute(mline, :mid) do
        {:mid, mid} ->
          transceivers = RTPTransceiver.update_or_create(transceivers, mid, mline)
          {:cont, {:ok, transceivers}}

        _other ->
          {:halt, {:error, :missing_mid}}
      end
    end)
  end

  defp assign_mids(transceivers, next_mid) do
    {new_transceivers, _next_mid} =
      Enum.map_reduce(transceivers, next_mid, fn
        %{mid: nil} = t, nm -> {%{t | mid: to_string(nm)}, nm + 1}
        other, nm -> {other, nm}
      end)

    new_transceivers
  end

  defp find_next_mid(state) do
    # next mid must be unique, it's acomplished by looking for values
    # greater than any mid in remote description or our own transceivers
    crd_mids =
      if is_nil(state.current_remote_desc) do
        []
      else
        for mline <- state.current_remote_desc.media,
            {:mid, mid} <- ExSDP.Media.get_attribute(mline, :mid),
            {mid, ""} <- Integer.parse(mid) do
          mid
        end
      end

    tsc_mids =
      for %RTPTransceiver{mid: mid} when mid != nil <- state.transceivers,
          {mid, ""} <- Integer.parse(mid) do
        mid
      end

    Enum.max(crd_mids ++ tsc_mids, &>=/2, fn -> -1 end) + 1
  end

  defp check_desc_altered(:offer, sdp, %{last_offer: offer}) when sdp == offer, do: :ok
  defp check_desc_altered(:offer, _sdp, _state), do: {:error, :offer_altered}
  defp check_desc_altered(:answer, sdp, %{last_answer: answer}) when sdp == answer, do: :ok
  defp check_desc_altered(:answer, _sdp, _state), do: {:error, :answer_altered}

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

  defp set_description(:local, :answer, sdp, state) do
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

  defp set_description(:local, other, sdp, state) when other in [:offer, :pranswer] do
    %{state | pending_local_desc: {other, sdp}}
  end

  defp set_description(:remote, :answer, sdp, state) do
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

  defp set_description(:remote, other, sdp, state) when other in [:offer, :pranswer] do
    %{state | pending_remote_desc: {other, sdp}}
  end

  defp notify(pid, msg), do: send(pid, {:ex_webrtc, self(), msg})
end
