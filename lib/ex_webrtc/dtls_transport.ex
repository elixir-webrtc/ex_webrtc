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
  @spec start_dtls(dtls_transport(), :active | :passive, binary()) ::
          :ok | {:error, :already_started}
  def start_dtls(dtls_transport, mode, peer_fingerprint) do
    GenServer.call(dtls_transport, {:start_dtls, mode})
  end

  @doc false
  @spec send_data(dtls_transport(), binary()) :: :ok
  def send_data(dtls_transport, data) do
    GenServer.cast(dtls_transport, {:send_data, data})
  end

  @impl true
  def init([ice_config, ice_module, owner]) do
    {pkey, cert} = ExDTLS.generate_key_cert()
    fingerprint = ExDTLS.get_cert_fingerprint()

    {:ok, ice_agent} = ice_module.start_link(:controlled, ice_config)
    srtp = ExLibSRTP.new()

    state = %{
      owner: owner,
      ice_agent: ice_agent,
      ice_state: nil,
      buffered_packets: nil,
      cert: cert,
      pkey: pkey,
      fingerprint: fingerprint,
      peer_fingerprint: nil,
      srtp: srtp,
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
  def handle_call({:start_dtls, mode, peer_fingerprint}, _from, %{dtls: nil} = state)
      when mode in [:active, :passive] and is_binary(peer_fingerprint) do
    dtls =
      ExDTLS.init(
        client_mode: mode == :active,
        dtls_srtp: true,
        pkey: state.pkey,
        cert: state.cert,
        verify_peer: true
      )

    state = %{state | dtls: dtls, mode: mode, peer_fingerprint: peer_fingerprint}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:start_dtls, _mode}, _from, state) do
    # is there a case when mode will change and new handshake will be needed?
    {:reply, {:error, :already_started}, state}
  end

  @impl true
  def handle_cast({:send_data, _data}, %{dtls_state: :connected, ice_state: ice_state} = state)
      when ice_state in [:connected, :completed] do
    # TODO
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_data, _data}, state) do
    Logger.error(
      "Attempted to send data when DTLS handshake was not finished or ICE Transport is unavailable"
    )

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

      {:handshake_finished, _, remote_keying_material, profile, packets} ->
        Logger.debug("DTLS handshake finished")
        ICEAgent.send_data(state.ice_agent, packets)

        peer_fingerprint =
          state.dtls
          |> ExDTLS.get_peer_cert()
          |> ExDTLS.get_cert_fingerprint()

        if peer_fingerprint == state.peer_fingerprint do
          state = setup_srtp(state, remote_keying_material, profile)
          %{state | dtls_state: :connected}
        else
          %{state | dtls_state: :failed}
        end

      {:handshake_finished, _, remote_keying_material, profile} ->
        Logger.debug("DTLS handshake finished")
        state = setup_srtp(state, remote_keying_material, profile)
        %{state | dtls_state: :connected}

      :handshake_want_read ->
        state
    end
  end

  defp handle_ice({:data, <<f, _rest::binary>> = data}, %{dtls_state: :connected} = state)
       when f in 128..191 do
    case ExLibSRTP.unprotect(state.srtp, data) do
      {:ok, payload} ->
        # TODO: temporarily, everything goes to peer connection process
        notify(state.owner, {:rtp_data, payload})

      {:error, reason} ->
        Logger.warning("Failed to decrypt SRTP, reason: #{inspect(reason)}")
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

  defp setup_srtp(state, remote_keying_material, profile) do
    {:ok, crypto_profile} =
      ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(profile)

    policy = %ExLibSRTP.Policy{
      ssrc: :any_inbound,
      key: remote_keying_material,
      rtp: crypto_profile,
      rtcp: crypto_profile
    }

    :ok = ExLibSRTP.add_stream(state.srtp, policy)
    state
  end

  defp notify(dst, msg), do: send(dst, {:dtls_transport, self(), msg})
end
