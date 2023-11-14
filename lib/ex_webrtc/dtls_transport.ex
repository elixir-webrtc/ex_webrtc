defmodule ExWebRTC.DTLSTransport do
  @moduledoc false

  use GenServer

  require Logger

  alias ExICE.ICEAgent

  @impl true
  def init([peer_connection, ice_agent]) do
    # temporary hack to generate certs
    {:ok, cert_client} = ExDTLS.start_link(client_mode: true, dtls_srtp: true)
    {:ok, cert} = ExDTLS.get_cert(cert_client)
    {:ok, pkey} = ExDTLS.get_pkey(cert_client)
    {:ok, fingerprint} = ExDTLS.get_cert_fingerprint(cert_client)
    :ok = ExDTLS.stop(cert_client)

    srtp = ExLibSRTP.new()

    state = %{
      peer_connection: peer_connection,
      ice_agent: ice_agent,
      buffered_packets: nil,
      cert: cert,
      pkey: pkey,
      fingerprint: fingerprint,
      srtp: srtp,
      dtls_state: :new
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:send_data, data}, %{dtls_state: :connected, ice_state: ice_state} = state)
      when ice_state in [:connected, :completed] do
    # TODO encrypt

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:send_data, data}, state) do
    {:reply, {:error, :unable_to_send}, state}
  end

  @impl true
  def handle_call({:start, _mode}, %{client: _client} = state) do
    # is there a case when mode will change and new handshake will be needed?
    {:reply, {:error, :already_started}, state}
  end

  @impl true
  def handle_call({:start, mode}, state) when mode in [:active, :passive] do
    {:ok, client} =
      ExDTLS.start_link(
        client_mode: mode == :active,
        dtls_srtp: true,
        pkey: dtls.pkey,
        cert: dtls.cert
      )

    {:reply, :ok, %{state | client: client, mode: mode}}
  end

  @impl true
  def handle_info({:ex_dtls, _from, msg}, state) do
    state = handle_dtls(msg, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, msg}, state) do
    state = handle_ice(msg, state)
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
    case ExLibSRTP.unprotect(dtls.srtp, data) do
      {:ok, payload} ->
        send(state.peer_connection, {:rtp_data, payload})

      {:error, _reason} = err ->
        Logger.warn("Failed to decrypt SRTP, reason: #{inspect(reason)}")
    end

    state
  end

  defp handle_ice({:data, _data}, state) do
    Logger.warn("Received RTP/RTCP packets, but DTLS handshake hasn't been finished yet")
    state
  end

  # I hope ExICE will be refactord so new state is a tuple
  def handle_ice(new_state, %{dtls_state: :new} = state)
      when new_state in [:connected, :completed] do
    state =
      if dtls.mode == :active do
        {:ok, packets} = ExDTLS.do_handshake(dtls.client)
        :ok = ICEAgent.send_data(dtls.ice_agent, packets)
        %{state | dtls_state: :connecting}
      else
        state
      end

    %{state | ice_state: new_state}
  end

  def handle_ice(new_state, state)
      when new_state in [:connected, :completed] do
    if state.buffered_packets do
      Logger.debug("Sending buffered DTLS packets")
      :ok = ICEAgent.send_data(dtls.ice_agent, dtls.buffered_packets)
      %{state | buffered_packets: nil}
    else
      state
    end
  end

  def handle_ice(new_state, state) when is_atom(new_state) do
    %{state | ice_state: new_state}
  end

  def handel_ice(_msg, state), do: state

  def handle_dtls({:retransmit, packets}, %{ice_state: ice_state} = state)
      when ice_state in [:connected, :completed] do
    ICEAgent.send_data(state.ice_agent, packets)
    state
  end

  def handle_dtls({:retransmit, packets}, %{buffered_packets: packets} = state) do
    # we got DTLS packets from the other side but
    # we haven't established ICE connection yet so
    # packets to retransmit have to be the same as dtls_buffered_packets
    dtls
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
