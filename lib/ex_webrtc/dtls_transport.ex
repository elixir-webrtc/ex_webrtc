defmodule ExWebRTC.DTLSTransport do
  @moduledoc """
  DTLSTransport
  """

  use GenServer

  require Logger

  alias ExICE.ICEAgent

  @type dtls_transport() :: GenServer.server()

  @doc false
  @spec start_link(ExICE.ICEAgent.opts(), GenServer.server()) :: GenServer.on_start()
  def start_link(ice_config, ice_module \\ ICEAgent) do
    GenServer.start_link(__MODULE__, [ice_config, ice_module, self()])
  end

  @doc false
  @spec get_ice_agent(dtls_transport()) :: GenServer.server()
  def get_ice_agent(dtls_transport) do
    GenServer.call(dtls_transport, :get_ice_agent)
  end

  @doc false
  @spec get_fingerprint(dtls_transport()) :: binary()
  def get_fingerprint(dtls_transport) do
    GenServer.call(dtls_transport, :get_fingerprint)
  end

  @doc false
  @spec start_dtls(dtls_transport(), :active | :passive) :: :ok | {:error, :already_started}
  def start_dtls(dtls_transport, mode) do
    GenServer.call(dtls_transport, {:start_dtls, mode})
  end

  @doc false
  @spec send_rtp(dtls_transport(), binary()) :: :ok
  def send_rtp(dtls_transport, data) do
    GenServer.cast(dtls_transport, {:send_rtp, data})
  end

  @doc false
  @spec send_rtcp(dtls_transport(), binary()) :: :ok
  def send_rtcp(dtls_transport, data) do
    GenServer.cast(dtls_transport, {:send_rtcp, data})
  end

  @impl true
  def init([ice_config, ice_module, owner]) do
    # temporary hack to generate certs
    dtls = ExDTLS.init(client_mode: true, dtls_srtp: true)
    cert = ExDTLS.get_cert(dtls)
    pkey = ExDTLS.get_pkey(dtls)
    fingerprint = ExDTLS.get_cert_fingerprint(dtls)

    {:ok, ice_agent} = ice_module.start_link(:controlled, ice_config)

    state = %{
      owner: owner,
      ice_agent: ice_agent,
      ice_state: nil,
      buffered_packets: nil,
      cert: cert,
      pkey: pkey,
      fingerprint: fingerprint,
      in_srtp: ExLibSRTP.new(),
      out_srtp: ExLibSRTP.new(),
      dtls_state: :new,
      dtls: nil,
      mode: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_ice_agent, _from, state) do
    {:reply, state.ice_agent, state}
  end

  @impl true
  def handle_call(:get_fingerprint, _from, state) do
    {:reply, state.fingerprint, state}
  end

  @impl true
  def handle_call({:start_dtls, mode}, _from, %{dtls: nil} = state)
      when mode in [:active, :passive] do
    dtls =
      ExDTLS.init(
        client_mode: mode == :active,
        dtls_srtp: true,
        pkey: state.pkey,
        cert: state.cert
      )

    state = %{state | dtls: dtls, mode: mode}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:start_dtls, _mode}, _from, state) do
    # is there a case when mode will change and new handshake will be needed?
    {:reply, {:error, :already_started}, state}
  end

  @impl true
  def handle_cast({:send_rtp, data}, %{dtls_state: :connected, ice_state: ice_state} = state)
      when ice_state in [:connected, :completed] do
    case ExLibSRTP.protect(state.out_srtp, data) do
      {:ok, protected} -> ICEAgent.send_data(state.ice_agent, protected)
      {:error, reason} -> Logger.error("Unable to protect RTP: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_rtcp, _data}, state) do
    # TODO: implement
    {:noreply, state}
  end

  @impl true
  def handle_info(
        :dtls_timeout,
        %{ice_state: ice_state, buffered_packets: buffered_packets} = state
      ) do
    case ExDTLS.handle_timeout(state.dtls) do
      {:retransmit, packets, timeout} when ice_state in [:connected, :completed] ->
        ICEAgent.send_data(state.ice_agent, packets)
        Process.send_after(self(), :dtls_timeout, timeout)

      {:retransmit, ^buffered_packets, timeout} ->
        # we got DTLS packets from the other side but
        # we haven't established ICE connection yet so
        # packets to retransmit have to be the same as dtls_buffered_packets
        Process.send_after(self(), :dtls_timeout, timeout)

      :ok ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, msg} = ice_msg, state) do
    state = handle_ice(msg, state)

    # forward everything, except for data, to peer connection process
    case msg do
      {:data, _data} -> :ok
      _other -> send(state.owner, ice_msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("DTLSTransport received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_ice({:data, <<f, _rest::binary>> = data}, state) when f in 20..64 do
    case ExDTLS.handle_data(state.dtls, data) do
      {:handshake_packets, packets, timeout} when state.ice_state in [:connected, :completed] ->
        :ok = ICEAgent.send_data(state.ice_agent, packets)
        Process.send_after(self(), :dtls_timeout, timeout)
        %{state | dtls_state: :connecting}

      {:handshake_packets, packets, timeout} ->
        Logger.debug("""
        Generated local DTLS packets but ICE is not in the connected or completed state yet.
        We will send those packets once ICE is ready.
        """)

        Process.send_after(self(), :dtls_timeout, timeout)
        %{state | dtls_state: :connecting, buffered_packets: packets}

      {:handshake_finished, lkm, rkm, profile, packets} ->
        Logger.debug("DTLS handshake finished")
        ICEAgent.send_data(state.ice_agent, packets)
        # TODO: validate fingerprint
        state = setup_srtp(state, lkm, rkm, profile)
        %{state | dtls_state: :connected}

      {:handshake_finished, lkm, rkm, profile} ->
        Logger.debug("DTLS handshake finished")
        state = setup_srtp(state, lkm, rkm, profile)
        %{state | dtls_state: :connected}

      :handshake_want_read ->
        state
    end
  end

  defp handle_ice({:data, <<f, _rest::binary>> = data}, %{dtls_state: :connected} = state)
       when f in 128..191 do
    {type, unprotect} =
      case data do
        <<_, s, _::binary>> when s in 192..223 -> {:rtcp, &ExLibSRTP.unprotect_rtcp/2}
        _ -> {:rtp, &ExLibSRTP.unprotect/2}
      end

    case unprotect.(state.in_srtp, data) do
      {:ok, payload} ->
        send(state.owner, {type, payload})

      {:error, reason} ->
        Logger.error("Failed to decrypt SRTP/SRTCP, reason: #{inspect(reason)}")
    end

    state
  end

  defp handle_ice({:data, _data}, state) do
    Logger.warning(
      "Received RTP/RTCP packets, but DTLS handshake hasn't been finished yet. Ignoring."
    )

    state
  end

  # I hope ExICE will be refactord so new state is a tuple
  defp handle_ice(new_state, %{dtls_state: :new} = state)
       when new_state in [:connected, :completed] do
    state =
      if state.mode == :active do
        {packets, timeout} = ExDTLS.do_handshake(state.dtls)
        Process.send_after(self(), :dtls_timeout, timeout)
        :ok = ICEAgent.send_data(state.ice_agent, packets)
        %{state | dtls_state: :connecting}
      else
        state
      end

    %{state | ice_state: new_state}
  end

  defp handle_ice(new_state, state)
       when new_state in [:connected, :completed] do
    if state.buffered_packets do
      Logger.debug("Sending buffered DTLS packets")
      :ok = ICEAgent.send_data(state.ice_agent, state.buffered_packets)
      %{state | ice_state: new_state, buffered_packets: nil}
    else
      state
    end
  end

  defp handle_ice(new_state, state) when is_atom(new_state) do
    %{state | ice_state: new_state}
  end

  defp handle_ice(_msg, state), do: state

  defp setup_srtp(state, local_keying_material, remote_keying_material, profile) do
    {:ok, crypto_profile} =
      ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(profile)

    inbound_policy = %ExLibSRTP.Policy{
      ssrc: :any_inbound,
      key: remote_keying_material,
      rtp: crypto_profile,
      rtcp: crypto_profile
    }

    :ok = ExLibSRTP.add_stream(state.in_srtp, inbound_policy)

    outbound_policy = %ExLibSRTP.Policy{
      ssrc: :any_outbound,
      key: local_keying_material,
      rtp: crypto_profile,
      rtcp: crypto_profile
    }

    :ok = ExLibSRTP.add_stream(state.out_srtp, outbound_policy)

    state
  end
end
