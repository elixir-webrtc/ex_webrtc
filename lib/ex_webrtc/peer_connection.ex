defmodule ExWebRTC.PeerConnection do
  @moduledoc """
  PeerConnection
  """

  use GenServer

  require Logger

  alias __MODULE__.{Configuration, Demuxer}

  alias ExWebRTC.{
    DefaultICETransport,
    DTLSTransport,
    IceCandidate,
    MediaStreamTrack,
    RTPTransceiver,
    RTPReceiver,
    RTPSender,
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

  @typedoc """
  Messages sent by the ExWebRTC.
  """
  @type signal() :: {:ex_webrtc, pid(), connection_state_change()}

  @type connection_state_change() :: {:connection_state_change, connection_state()}

  @typedoc """
  Possible PeerConnection states.

  For the exact meaning, refer to the [WebRTC W3C, section 4.3.3](https://www.w3.org/TR/webrtc/#rtcpeerconnectionstate-enum)
  """
  @type connection_state() :: :closed | :failed | :disconnected | :new | :connecting | :connected

  #### API ####
  @spec start_link(Configuration.options()) :: GenServer.on_start()
  def start_link(options \\ []) do
    configuration = Configuration.from_options!(options)
    GenServer.start_link(__MODULE__, {self(), configuration})
  end

  @spec start(Configuration.options()) :: GenServer.on_start()
  def start(options \\ []) do
    configuration = Configuration.from_options!(options)
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
        ) ::
          {:ok, RTPTransceiver.t()} | {:error, :TODO}
  def add_transceiver(peer_connection, kind_or_track, options \\ []) do
    GenServer.call(peer_connection, {:add_transceiver, kind_or_track, options})
  end

  @spec add_track(peer_connection(), MediaStreamTrack.t()) ::
          {:ok, RTPSender.t()} | {:error, :TODO}
  def add_track(peer_connection, track) do
    GenServer.call(peer_connection, {:add_track, track})
  end

  @spec close(peer_connection()) :: :ok
  def close(peer_connection) do
    GenServer.stop(peer_connection)
  end

  @spec send_rtp(peer_connection(), String.t(), ExRTP.Packet.t()) :: :ok
  def send_rtp(peer_connection, track_id, packet) do
    GenServer.cast(peer_connection, {:send_rtp, track_id, packet})
  end

  #### CALLBACKS ####

  @impl true
  def init({owner, config}) do
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
      peer_fingerprint: nil
    }

    notify(state.owner, {:connection_state_change, :new})
    notify(state.owner, {:signaling_state_change, :stable})

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
      :ok = state.ice_transport.restart(state.ice_pid)
    end

    next_mid = find_next_mid(state)
    transceivers = assign_mids(state.transceivers, next_mid)

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

    mlines = Enum.map(transceivers, &RTPTransceiver.to_offer_mline(&1, opts))

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

    # TODO: rejected media sections
    mlines =
      Enum.map(remote_offer.media, fn mline ->
        {:mid, mid} = ExSDP.Media.get_attribute(mline, :mid)
        {_ix, transceiver} = find_transceiver(state.transceivers, mid)
        RTPTransceiver.to_answer_mline(transceiver, mline, opts)
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
    case apply_local_description(desc, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:set_remote_description, desc}, _from, state) do
    case apply_remote_description(desc, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, _reason} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:add_ice_candidate, _}, _from, %{current_remote_desc: nil} = state) do
    {:reply, {:error, :no_remote_description}, state}
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
    transceiver = new_transceiver(kind, nil, state.config, options)
    transceivers = state.transceivers ++ [transceiver]

    {:reply, {:ok, transceiver}, %{state | transceivers: transceivers}}
  end

  @impl true
  def handle_call({:add_transceiver, %MediaStreamTrack{} = track, options}, _from, state) do
    transceiver = new_transceiver(track.kind, track, state.config, options)
    transceivers = state.transceivers ++ [transceiver]

    {:reply, {:ok, transceiver}, %{state | transceivers: transceivers}}
  end

  @impl true
  def handle_call({:add_track, %MediaStreamTrack{kind: kind} = track}, _from, state) do
    # we ignore the condition that sender has never been used to send
    free_transceiver =
      Enum.find_index(state.transceivers, fn
        %RTPTransceiver{
          kind: ^kind,
          sender: %RTPSender{track: nil},
          current_direction: cr
        }
        when cr not in [:sendrecv, :sendonly] ->
          true

        _other ->
          false
      end)

    {transceivers, sender} =
      case free_transceiver do
        nil ->
          tr = new_transceiver(kind, track, state.config, direction: :sendrecv)
          {state.transceivers ++ [tr], tr.sender}

        ix ->
          tr = Enum.at(state.transceivers, ix)
          sender = %RTPSender{tr.sender | track: track}

          direction =
            case tr.direction do
              :recvonly -> :sendrecv
              :inactive -> :sendonly
              other -> other
            end

          tr = %RTPTransceiver{tr | sender: sender, direction: direction}
          {List.replace_at(state.transceivers, ix, tr), tr.sender}
      end

    {:reply, {:ok, sender}, %{state | transceivers: transceivers}}
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
        {packet, sender} = RTPSender.send(transceiver.sender, packet)
        :ok = DTLSTransport.send_rtp(state.dtls_transport, packet)

        transceivers = List.update_at(state.transceivers, idx, &%{&1 | sender: sender})
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
  def handle_info({:ex_ice, _from, {:gathering_state_changed, new_gathering_state}}, state) do
    state = %{state | ice_gathering_state: new_gathering_state}
    {:noreply, state}
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
  def handle_info({:dtls_transport, _pid, {:state_change, new_dtls_state}}, state) do
    state = %{state | dtls_state: new_dtls_state}
    next_conn_state = next_conn_state(state.ice_state, new_dtls_state)
    state = update_conn_state(state, next_conn_state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:dtls_transport, _pid, {:rtp, data}}, state) do
    with {:ok, demuxer, mid, packet} <- Demuxer.demux(state.demuxer, data),
         %RTPTransceiver{} = t <- Enum.find(state.transceivers, &(&1.mid == mid)) do
      track_id = t.receiver.track.id
      notify(state.owner, {:rtp, track_id, packet})
      {:noreply, %{state | demuxer: demuxer}}
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
  def handle_info(msg, state) do
    Logger.info("OTHER MSG #{inspect(msg)}")
    {:noreply, state}
  end

  defp new_transceiver(kind, sender_track, config, options) do
    direction = Keyword.get(options, :direction, :sendrecv)

    {rtp_hdr_exts, codecs} =
      case kind do
        :audio -> {config.audio_rtp_hdr_exts, config.audio_codecs}
        :video -> {config.video_rtp_hdr_exts, config.video_codecs}
      end

    # When we create sendonly or sendrecv transceiver, we always only take one codec
    # to avoid ambiguity when assigning payload type for RTP packets in RTPSender.
    # In other case, if PeerConnection negotiated multiple codecs,
    # user would have to pass RTP codec when sending RTP packets,
    # or assing payload type on their own.
    codecs =
      if direction in [:sendrecv, :sendonly] do
        Enum.slice(codecs, 0, 1)
      else
        codecs
      end

    track = MediaStreamTrack.new(kind)

    %RTPTransceiver{
      mid: nil,
      direction: direction,
      current_direction: nil,
      kind: kind,
      codecs: codecs,
      rtp_hdr_exts: rtp_hdr_exts,
      receiver: %RTPReceiver{track: track},
      sender: RTPSender.new(sender_track, List.first(codecs), rtp_hdr_exts)
    }
  end

  defp apply_local_description(%SessionDescription{type: type}, _state)
       when type in [:rollback, :pranswer],
       do: {:error, :not_implemented}

  defp apply_local_description(%SessionDescription{type: type, sdp: raw_sdp}, state) do
    with {:ok, next_sig_state} <- next_signaling_state(state.signaling_state, :local, type),
         :ok <- check_altered(type, raw_sdp, state),
         {:ok, sdp} <- parse_sdp(raw_sdp) do
      if state.ice_gathering_state == :new do
        state.ice_transport.gather_candidates(state.ice_pid)
      end

      transceivers = update_transceiver_directions(state.transceivers, sdp, :local, type)

      state =
        state
        |> set_description(:local, type, sdp)
        |> update_signaling_state(next_sig_state)
        |> Map.update!(:demuxer, &Demuxer.update(&1, sdp))
        |> Map.replace!(:transceivers, transceivers)

      {:ok, state}
    end
  end

  defp apply_remote_description(%SessionDescription{type: type}, _state)
       when type in [:rollback, :pranswer],
       do: {:error, :not_implemented}

  defp apply_remote_description(%SessionDescription{type: type, sdp: raw_sdp}, state) do
    with {:ok, next_sig_state} <- next_signaling_state(state.signaling_state, :remote, type),
         {:ok, sdp} <- parse_sdp(raw_sdp),
         :ok <- SDPUtils.ensure_mid(sdp),
         :ok <- SDPUtils.ensure_bundle(sdp),
         :ok <- SDPUtils.ensure_rtcp_mux(sdp),
         {:ok, {ice_ufrag, ice_pwd}} <- SDPUtils.get_ice_credentials(sdp),
         {:ok, {:fingerprint, {:sha256, peer_fingerprint}}} <- SDPUtils.get_cert_fingerprint(sdp),
         {:ok, dtls_role} <- SDPUtils.get_dtls_role(sdp) do
      transceivers =
        state
        |> update_transceivers(sdp)
        |> update_transceiver_directions(sdp, :remote, type)

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
        |> update_signaling_state(next_sig_state)
        |> Map.update!(:demuxer, &Demuxer.update(&1, sdp))
        |> Map.replace!(:transceivers, transceivers)

      {:ok, state}
    else
      {:ok, {:fingerprint, {_hash_function, _fingerprint}}} ->
        {:error, :unsupported_cert_fingerprint_hash_function}

      {:error, _reason} = err ->
        err
    end
  end

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

  defp update_transceivers(state, sdp) do
    Enum.reduce(sdp.media, state.transceivers, fn mline, transceivers ->
      {:mid, mid} = ExSDP.Media.get_attribute(mline, :mid)

      # TODO: consider recycled transceivers
      case find_transceiver(transceivers, mid) do
        {idx, %RTPTransceiver{} = tr} ->
          new_tr = RTPTransceiver.update(tr, mline, state.config)
          notify_if_new_track(mline, new_tr, state.owner)

          List.replace_at(transceivers, idx, new_tr)

        nil ->
          new_tr = RTPTransceiver.from_mline(mline, state.config)
          notify_if_new_track(mline, new_tr, state.owner)
          transceivers ++ [new_tr]
      end
    end)
  end

  defp notify_if_new_track(mline, tr, owner) do
    # TODO: applying offers back to back (without answer)
    # will result in multiple messages for the same track
    # because current_direction is set in set_remote_description
    direction = SDPUtils.get_media_direction(mline)

    if direction in [:sendrecv, :sendonly] and
         tr.current_direction not in [:sendrecv, :recvonly] do
      notify(owner, {:track, tr.receiver.track})
    end
  end

  defp update_transceiver_directions(transceivers, sdp, source, :answer) do
    Enum.reduce(sdp.media, transceivers, fn mline, transceivers ->
      {:mid, mid} = ExSDP.Media.get_attribute(mline, :mid)
      {idx, transceiver} = find_transceiver(transceivers, mid)

      direction = SDPUtils.get_media_direction(mline)

      direction =
        case source do
          :local -> direction
          :remote -> reverse_direction(direction)
        end

      transceiver = %RTPTransceiver{transceiver | current_direction: direction}
      List.replace_at(transceivers, idx, transceiver)
    end)
  end

  defp update_transceiver_directions(transceivers, sdp, :remote, :offer) do
    # TODO: currently, we don't handle remote recvonly mlines
    # as they need to be handled diffrently (i.e. transceiver set to inactive)
    # and we have no way to check that when applying answer
    Enum.each(sdp.media, fn mline ->
      if SDPUtils.get_media_direction(mline) == :recvonly do
        raise "Unable to handle remote `recvonly` mline"
      end
    end)

    transceivers
  end

  defp update_transceiver_directions(transceivers, _sdp, _source, _type),
    do: transceivers

  defp reverse_direction(:recvonly), do: :sendonly
  defp reverse_direction(:sendonly), do: :recvonly
  defp reverse_direction(dir) when dir in [:sendrecv, :inactive], do: dir

  defp find_transceiver(transceivers, mid) do
    transceivers
    |> Enum.with_index(fn tr, idx -> {idx, tr} end)
    |> Enum.find(fn {_idx, tr} -> tr.mid == mid end)
  end

  defp assign_mids(transceivers, next_mid) do
    {new_transceivers, _next_mid} =
      Enum.map_reduce(transceivers, next_mid, fn
        %{mid: nil} = t, nm ->
          {RTPTransceiver.assign_mid(t, to_string(nm)), nm + 1}

        other, nm ->
          {other, nm}
      end)

    new_transceivers
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
      with {:mid, mid} <- ExSDP.Media.get_attribute(mline, :mid),
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

  defp notify(pid, msg), do: send(pid, {:ex_webrtc, self(), msg})
end
