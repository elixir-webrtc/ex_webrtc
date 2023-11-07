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
    :srtp,
    finished: false
  ]

  def new(ice_agent) do
    # temporary hack to generate certs
    {:ok, cert_client} = ExDTLS.start_link(client_mode: true, dtls_srtp: true)
    {:ok, cert} = ExDTLS.get_cert(cert_client)
    {:ok, pkey} = ExDTLS.get_pkey(cert_client)
    {:ok, fingerprint} = ExDTLS.get_cert_fingerprint(cert_client)
    :ok = ExDTLS.stop(cert_client)

    srtp = ExLibSRTP.new()

    %__MODULE__{
      ice_agent: ice_agent,
      cert: cert,
      pkey: pkey,
      fingerprint: fingerprint,
      srtp: srtp
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

    %__MODULE__{dtls | client: client, mode: :passive}
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
    %__MODULE__{dtls | client: client, mode: :active}
  end

  def update_ice_state(dtls, :connected) do
    if dtls.mode == :active do
      {:ok, packets} = ExDTLS.do_handshake(dtls.client)
      :ok = ICEAgent.send_data(dtls.ice_agent, packets)
    end

    dtls =
      if dtls.buffered_packets do
        Logger.debug("Sending buffered DTLS packets")
        :ok = ICEAgent.send_data(dtls.ice_agent, dtls.buffered_packets)
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

  def process_data(dtls, <<f, _::binary>> = data) when f in 20..63 and not dtls.finished do
    case ExDTLS.process(dtls.client, data) do
      {:handshake_packets, packets} when dtls.ice_state in [:connected, :completed] ->
        :ok = ICEAgent.send_data(dtls.ice_agent, packets)
        {:ok, dtls}

      {:handshake_packets, packets} ->
        Logger.debug("""
        Generated local DTLS packets but ICE is not in the connected or completed state yet.
        We will send those packets once ICE is ready.
        """)

        {:ok, %__MODULE__{dtls | buffered_packets: packets}}

      {:handshake_finished, keying_material, packets} ->
        Logger.debug("DTLS handshake finished")
        ICEAgent.send_data(dtls.ice_agent, packets)
        # TODO: validate fingerprint
        dtls = setup_srtp(dtls, keying_material)
        {:ok, %__MODULE__{dtls | finished: true}}

      {:handshake_finished, keying_material} ->
        Logger.debug("DTLS handshake finished")
        dtls = setup_srtp(dtls, keying_material)
        {:ok, %__MODULE__{dtls | finished: true}}

      :handshake_want_read ->
        {:ok, dtls}
    end
  end

  def process_data(dtls, <<f, _::binary>> = data) when f in 128..191 and dtls.finished do
    case ExLibSRTP.unprotect(dtls.srtp, data) do
      {:ok, payload} ->
        {:ok, dtls, payload}

      {:error, _reason} = err ->
        err
    end
  end

  def process_data(_dtls, _data) do
    {:error, :invalid_data}
  end

  defp setup_srtp(dtls, keying_material) do
    {_local_material, remote_material, profile} = keying_material

    {:ok, crypto_profile} =
      ExLibSRTP.Policy.crypto_profile_from_dtls_srtp_protection_profile(profile)

    policy = %ExLibSRTP.Policy{
      ssrc: :any_inbound,
      key: remote_material,
      rtp: crypto_profile,
      rtcp: crypto_profile
    }

    :ok = ExLibSRTP.add_stream(dtls.srtp, policy)
    dtls
  end
end
