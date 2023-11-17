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
  def start_link(ice_config, peer_connection \\ self()) do
    GenServer.start_link(__MODULE__, [ice_config, peer_connection])
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
  @spec send_data(dtls_transport(), binary()) :: :ok
  def send_data(dtls_transport, data) do
    GenServer.cast(dtls_transport, {:send_data, data})
  end

  @impl true
  def init([ice_config, peer_connection]) do
    # temporary hack to generate certs
    {:ok, cert_client} = ExDTLS.start_link(client_mode: true, dtls_srtp: true)
    {:ok, cert} = ExDTLS.get_cert(cert_client)
    {:ok, pkey} = ExDTLS.get_pkey(cert_client)
    {:ok, fingerprint} = ExDTLS.get_cert_fingerprint(cert_client)
    :ok = ExDTLS.stop(cert_client)

    {:ok, ice_agent} = ICEAgent.start_link(:controlled, ice_config)
    srtp = ExLibSRTP.new()

    state = %{
      peer_connection: peer_connection,
      ice_agent: ice_agent,
      ice_state: nil,
      buffered_packets: nil,
      cert: cert,
      pkey: pkey,
      fingerprint: fingerprint,
      srtp: srtp,
      dtls_state: :new,
      client: nil,
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
  def handle_call({:start_dtls, mode}, _from, %{client: nil} = state)
      when mode in [:active, :passive] do
    {:ok, client} =
      ExDTLS.start_link(
        client_mode: mode == :active,
        dtls_srtp: true,
        pkey: state.pkey,
        cert: state.cert
      )

    state = %{state | client: client, mode: mode}
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
  def handle_info({:ex_dtls, _from, msg}, state) do
    state = handle_dtls(msg, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, msg} = ice_msg, state) do
    state = handle_ice(msg, state)

    # forward everything, except for data, to peer connection process
    case msg do
      {:data, _data} -> :ok
      _other -> send(state.peer_connection, ice_msg)
    end

    {:noreply, state}
  end

  defp handle_ice({:data, <<f, _rest::binary>> = data}, state) when f in 20..64 do
    case ExDTLS.process(state.client, data) do
      {:handshake_packets, packets} when state.ice_state in [:connected, :completed] ->
        :ok = ICEAgent.send_data(state.ice_agent, packets)
        %{state | dtls_state: :connecting}

      {:handshake_packets, packets} ->
        Logger.debug("""
        Generated local DTLS packets but ICE is not in the connected or completed state yet.
        We will send those packets once ICE is ready.
        """)

        %{state | dtls_state: :connecting, buffered_packets: packets}

      {:handshake_finished, keying_material, packets} ->
        Logger.debug("DTLS handshake finished")
        ICEAgent.send_data(state.ice_agent, packets)
        # TODO: validate fingerprint
        state = setup_srtp(state, keying_material)
        %{state | dtls_state: :connected}

      {:handshake_finished, keying_material} ->
        Logger.debug("DTLS handshake finished")
        state = setup_srtp(state, keying_material)
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
        send(state.peer_connection, {:rtp_data, payload})

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
        {:ok, packets} = ExDTLS.do_handshake(state.client)
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

  defp handle_dtls({:retransmit, packets}, %{ice_state: ice_state} = state)
       when ice_state in [:connected, :completed] do
    ICEAgent.send_data(state.ice_agent, packets)
    state
  end

  defp handle_dtls({:retransmit, packets}, %{buffered_packets: packets} = state) do
    # we got DTLS packets from the other side but
    # we haven't established ICE connection yet so
    # packets to retransmit have to be the same as dtls_buffered_packets
    state
  end

  defp setup_srtp(state, keying_material) do
    {_local_material, remote_material, profile} = keying_material

    {:ok, crypto_profile} =
      ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(profile)

    policy = %ExLibSRTP.Policy{
      ssrc: :any_inbound,
      key: remote_material,
      rtp: crypto_profile,
      rtcp: crypto_profile
    }

    :ok = ExLibSRTP.add_stream(state.srtp, policy)
    state
  end
end
