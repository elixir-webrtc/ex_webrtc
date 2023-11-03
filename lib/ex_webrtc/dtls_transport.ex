defmodule ExWebRTC.DTLSTransport do
  @moduledoc false

  require Logger

  alias ExICE.ICEAgent

  defstruct [
    :ice_agent,
    :ice_state,
    :client,
    :buffered_packets,
    :cert,
    :pkey,
    :fingerprint,
    :mode,
    finished: false,
    should_start: false
  ]

  def new(ice_agent) do
    # temporary hack to generate certs
    {:ok, cert_client} = ExDTLS.start_link(client_mode: true, dtls_srtp: true)
    {:ok, cert} = ExDTLS.get_cert(cert_client)
    {:ok, pkey} = ExDTLS.get_pkey(cert_client)
    {:ok, fingerprint} = ExDTLS.get_cert_fingerprint(cert_client)
    :ok = ExDTLS.stop(cert_client)

    %__MODULE__{
      ice_agent: ice_agent,
      cert: cert,
      pkey: pkey,
      fingerprint: fingerprint
    }
  end

  def start(dtls, :passive) do
    {:ok, client} =
      ExDTLS.start_link(
        client_mode: false,
        dtls_srtp: true,
        pkey: dtls.pkey,
        cert: dtls.cert
      )

    %__MODULE__{dtls | client: client}
  end

  def start(dtls, :active) do
    {:ok, client} =
      ExDTLS.start_link(
        client_mode: true,
        dtls_srtp: true,
        pkey: dtls.pkey,
        cert: dtls.cert
      )

    # we assume that ICE in not in connected state yet
    %__MODULE__{dtls | client: client, should_start: true}
  end

  def update_ice_state(dtls, :connected) do
    dtls =
      if dtls.should_start do
        {:ok, packets} = ExDTLS.do_handshake(dtls.client)
        :ok = ICEAgent.send_data(dtls.ice_agent, packets)
        %__MODULE__{dtls | should_start: false}
      else
        dtls
      end

    dtls =
      if dtls.buffered_packets do
        Logger.debug("Sending buffered DTLS packets")
        ICEAgent.send_data(dtls.ice_agent, dtls.buffered_packets)
        %__MODULE__{dtls | buffered_packets: nil}
      else
        dtls
      end

    %__MODULE__{dtls | ice_state: :connected}
  end

  def update_ice_state(dtls, new_state) do
    %__MODULE__{dtls | ice_state: new_state}
  end

  def handle_info(dtls, {:retransmit, packets})
      when dtls.ice_state in [:connected, :completed] do
    ICEAgent.send_data(dtls.ice_agent, packets)
    dtls
  end

  def handle_info(%{buffered_packets: packets} = dtls, {:retransmit, packets}) do
    # we got DTLS packets from the other side but
    # we haven't established ICE connection yet so
    # packets to retransmit have to be the same as dtls_buffered_packets
    dtls
  end

  def process_data(dtls, data) do
    case ExDTLS.process(dtls.client, data) do
      {:handshake_packets, packets} when dtls.ice_state in [:connected, :completed] ->
        :ok = ICEAgent.send_data(dtls.ice_agent, packets)
        dtls

      {:handshake_packets, packets} ->
        Logger.debug("""
        Generated local DTLS packets but ICE is not in the connected or completed state yet.
        We will send those packets once ICE is ready.
        """)

        %__MODULE__{dtls | buffered_packets: packets}

      {:handshake_finished, _keying_material, packets} ->
        Logger.debug("DTLS handshake finished")
        ICEAgent.send_data(dtls.ice_agent, packets)
        %__MODULE__{dtls | finished: true}

      {:handshake_finished, _keying_material} ->
        Logger.debug("DTLS handshake finished")
        %__MODULE__{dtls | finished: true}

      :handshake_want_read ->
        dtls
    end
  end
end
