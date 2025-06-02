defmodule ExWebRTC.DTLSTransport do
  @moduledoc false

  use GenServer

  require Logger

  alias ExWebRTC.{DefaultICETransport, ICETransport, Utils}

  @type dtls_transport() :: pid()

  @typedoc """
  Messages sent by the DTLSTransport.
  """
  @type signal() :: {:dtls_transport, pid(), state_change() | rtp_rtcp()}

  @typedoc """
  Message sent when DTLSTransport changes its state.
  """
  @type state_change() :: {:state_change, dtls_state()}

  @typedoc """
  Message sent when a new RTP/RTCP packet arrives.

  Packet is decrypted.
  """
  @type rtp_rtcp() :: {:rtp | :rtcp, binary()}

  @typedoc """
  Possible DTLSTransport states.

  For the exact meaning, refer to the [WebRTC W3C, sec. 5.5.1](https://www.w3.org/TR/webrtc/#rtcdtlstransportstate-enum)
  """
  @type dtls_state() :: :new | :connecting | :connected | :closed | :failed

  @typedoc """
  Information about DTLS certificate.

  * `fingerprint` - hex dump of the cert fingerprint
  * `fingerprint_algorithm` - always `:sha_256`
  * `base64_certificate` - base 64 encoded certificate
  """
  @type cert_info :: %{
          fingerprint: binary(),
          fingerprint_algorithm: :sha_256,
          base64_certificate: binary()
        }

  @spec start_link(ICETransport.t(), pid()) :: GenServer.on_start()
  def start_link(ice_transport \\ DefaultICETransport, ice_pid) do
    behaviour = ice_transport.__info__(:attributes)[:behaviour] || []

    unless ICETransport in behaviour do
      raise "DTLSTransport requires ice_transport to implement ExWebRTC.ICETransport behaviour."
    end

    GenServer.start_link(__MODULE__, [ice_transport, ice_pid, self()])
  end

  @spec set_ice_connected(dtls_transport()) :: :ok
  def set_ice_connected(dtls_transport) do
    GenServer.call(dtls_transport, :set_ice_connected)
  end

  @spec get_certs_info(dtls_transport()) :: %{
          local_cert_info: cert_info(),
          remote_cert_info: cert_info() | nil
        }
  def get_certs_info(dtls_transport) do
    GenServer.call(dtls_transport, :get_certs_info)
  end

  @spec get_fingerprint(dtls_transport()) :: binary()
  def get_fingerprint(dtls_transport) do
    GenServer.call(dtls_transport, :get_fingerprint)
  end

  @spec start_dtls(dtls_transport(), :active | :passive, binary()) ::
          :ok | {:error, :already_started}
  def start_dtls(dtls_transport, mode, peer_fingerprint) do
    GenServer.call(dtls_transport, {:start_dtls, mode, peer_fingerprint})
  end

  @spec send_rtp(dtls_transport(), binary()) :: :ok
  def send_rtp(dtls_transport, data) do
    GenServer.cast(dtls_transport, {:send_rtp, data})
  end

  @spec send_rtcp(dtls_transport(), binary()) :: :ok
  def send_rtcp(dtls_transport, data) do
    GenServer.cast(dtls_transport, {:send_rtcp, data})
  end

  @spec send_data(dtls_transport(), binary()) :: :ok
  def send_data(dtls_transport, data) do
    GenServer.cast(dtls_transport, {:send_data, data})
  end

  @spec set_packet_loss(dtls_transport(), 0..100) :: :ok
  def set_packet_loss(dtls_transport, packet_loss) do
    GenServer.cast(dtls_transport, {:set_packet_loss, packet_loss})
  end

  @spec close(dtls_transport()) :: :ok
  def close(dtls_transport) do
    GenServer.call(dtls_transport, :close)
  end

  @spec stop(dtls_transport()) :: :ok
  def stop(dtls_transport) do
    GenServer.stop(dtls_transport)
  end

  @impl true
  def init([ice_transport, ice_pid, owner]) do
    {pkey, cert} = ExDTLS.generate_key_cert()
    fingerprint = ExDTLS.get_cert_fingerprint(cert)

    state = %{
      owner: owner,
      ice_transport: ice_transport,
      ice_pid: ice_pid,
      ice_connected: false,
      buffered_local_packets: nil,
      buffered_remote_packets: nil,
      buffered_remote_rtp_packets: [],
      cert: cert,
      base64_cert: Base.encode64(cert),
      pkey: pkey,
      fingerprint: fingerprint,
      remote_cert: nil,
      remote_base64_cert: nil,
      remote_fingerprint: nil,
      in_srtp: ExLibSRTP.new(),
      out_srtp: ExLibSRTP.new(),
      # sha256 hex dump
      peer_fingerprint: nil,
      dtls_state: :new,
      dtls: nil,
      mode: nil,
      packet_loss: 0
    }

    notify(state.owner, {:state_change, :new})

    {:ok, state}
  end

  @impl true
  def handle_call(:set_ice_connected, _from, %{dtls_state: :new} = state) do
    state = %{state | ice_connected: true}

    if state.mode == :active do
      {:ok, packets, timeout} = ExDTLS.do_handshake(state.dtls)
      Process.send_after(self(), :dtls_timeout, timeout)
      :ok = do_send(state, packets)
      state = update_dtls_state(state, :connecting)
      Logger.debug("Started DTLS handshake")
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:set_ice_connected, _from, %{dtls_state: :connecting} = state) do
    state = %{state | ice_connected: true}

    if state.buffered_local_packets do
      Logger.debug("Sending buffered DTLS packets")
      :ok = do_send(state, state.buffered_local_packets)
      state = %{state | buffered_local_packets: nil}
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:set_ice_connected, _from, state) do
    Logger.debug("""
    Setting ice connected in unexpected DTLS state: #{state.dtls_state}. \
    DTLS handshake won't be performed.\
    """)

    state = %{state | ice_connected: true}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_certs_info, _from, state) do
    local_cert_info = %{
      fingerprint: Utils.hex_dump(state.fingerprint),
      fingerprint_algorithm: :sha_256,
      base64_certificate: state.base64_cert
    }

    rem_fp = state.remote_fingerprint

    remote_cert_info = %{
      fingerprint: rem_fp && Utils.hex_dump(rem_fp),
      fingerprint_algorithm: rem_fp && :sha_256,
      base64_certificate: state.remote_base64_cert
    }

    certs_info = %{
      local_cert_info: local_cert_info,
      remote_cert_info: remote_cert_info
    }

    {:reply, certs_info, state}
  end

  @impl true
  def handle_call(:get_fingerprint, _from, state) do
    {:reply, state.fingerprint, state}
  end

  @impl true
  def handle_call({:start_dtls, mode, peer_fingerprint}, _from, %{dtls: nil} = state)
      when mode in [:active, :passive] do
    Logger.debug("Started DTLSTransport with role #{mode}")
    ex_dtls_mode = if mode == :active, do: :client, else: :server

    dtls =
      ExDTLS.init(
        mode: ex_dtls_mode,
        dtls_srtp: true,
        pkey: state.pkey,
        cert: state.cert,
        verify_peer: true
      )

    # plant the buffered remote packets in the mailbox
    # as if it came from the ICE transport
    case state.buffered_remote_packets do
      nil -> :ok
      data -> send(self(), {:ex_ice, state.ice_pid, {:data, data}})
    end

    state = %{
      state
      | dtls: dtls,
        mode: mode,
        peer_fingerprint: peer_fingerprint,
        buffered_remote_packets: nil
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:start_dtls, _mode, _peer_fingerprint}, _from, state) do
    # is there a case when mode will change and new handshake will be needed?
    {:reply, {:error, :already_started}, state}
  end

  @impl true
  def handle_call(:close, _from, %{state: :closed} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    {:ok, packets} = ExDTLS.close(state.dtls)
    :ok = do_send(state, packets)
    state = update_dtls_state(state, :closed, notify: false)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:send_rtp, data}, %{dtls_state: :connected, ice_connected: true} = state) do
    case ExLibSRTP.protect(state.out_srtp, data) do
      {:ok, protected} -> :ok = do_send(state, protected)
      {:error, reason} -> Logger.warning("Unable to protect RTP: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_rtp, _data}, state) do
    Logger.debug("Attempted to send RTP in wrong DTLS state: #{state.dtls_state}. Ignoring.")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_rtcp, data}, %{dtls_state: :connected, ice_connected: true} = state) do
    case ExLibSRTP.protect_rtcp(state.out_srtp, data) do
      {:ok, protected} -> do_send(state, protected)
      {:error, reason} -> Logger.warning("Unable to protect RTCP: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_rtcp, _data}, state) do
    Logger.debug("Attempted to send RTCP in wrong DTLS state: #{state.dtls_state}. Ignoring.")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_data, data}, %{dtls_state: :connected, ice_connected: true} = state) do
    case ExDTLS.write_data(state.dtls, data) do
      {:ok, packets} -> :ok = do_send(state, packets)
      {:error, reason} -> Logger.warning("Unable to protect data: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_data, _data}, state) do
    Logger.debug("Attempted to send data in wrong DTLS state: #{state.dtls_state}. Ignoring.")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_packet_loss, value}, state) do
    state = %{state | packet_loss: value}
    {:noreply, state}
  end

  @impl true
  def handle_info(:dtls_timeout, %{buffered_local_packets: buffered_local_packets} = state) do
    case ExDTLS.handle_timeout(state.dtls) do
      {:retransmit, packets, timeout} when state.ice_connected ->
        :ok = do_send(state, packets)
        Logger.debug("Retransmitted DTLS packets")
        Process.send_after(self(), :dtls_timeout, timeout)

      {:retransmit, ^buffered_local_packets, timeout} ->
        # we got DTLS packets from the other side but
        # we haven't established ICE connection yet so
        # packets to retransmit have to be the same as dtls_buffered_packets
        Process.send_after(self(), :dtls_timeout, timeout)

      {:retransmit, _packets, timeout} ->
        Logger.warning(
          "DTLSTransport: Packets to retransmit differ from buffered local packets despite ICE not being connected"
        )

        Process.send_after(self(), :dtls_timeout, timeout)

      :ok ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:ex_ice, _from, {:data, _data} = msg}, state) do
    case handle_ice_data(msg, state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, :peer_closed_for_writing} ->
        # See W3C WebRTC sec. 5.5.1
        # peer_closed_for_writing is returned when the remote side
        # sends close_notify alert
        ExDTLS.close(state.dtls)
        state = update_dtls_state(state, :closed)
        {:noreply, state}

      {:error, _reason} ->
        # See W3C WebRTC sec. 5.5.
        state = update_dtls_state(state, :failed)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("DTLSTransport received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug("Stopping DTLSTransport with reason: #{inspect(reason)}")
  end

  defp handle_ice_data({:data, _data}, %{dtls_state: dtls_state} = state)
       when dtls_state in [:failed, :closed] do
    Logger.debug("Received DTLS packets in state #{dtls_state}. Ignoring.")
    {:ok, state}
  end

  defp handle_ice_data({:data, data}, %{dtls: nil} = state) do
    # received DTLS data from remote peer before receiving an
    # SDP answer and initializing the DTLS Transport, will buffer the data
    state = %{state | buffered_remote_packets: data}
    {:ok, state}
  end

  defp handle_ice_data({:data, <<f, _rest::binary>> = data}, state) when f in 20..63 do
    case ExDTLS.handle_data(state.dtls, data) do
      {:handshake_packets, packets, timeout} when state.ice_connected ->
        :ok = do_send(state, packets)
        Process.send_after(self(), :dtls_timeout, timeout)
        state = update_dtls_state(state, :connecting)
        {:ok, state}

      {:handshake_packets, packets, timeout} ->
        Logger.debug("""
        Generated local DTLS packets but ICE is not in the connected state yet.
        We will send those packets once ICE is ready.
        """)

        Process.send_after(self(), :dtls_timeout, timeout)
        state = %{state | buffered_local_packets: packets}
        state = update_dtls_state(state, :connecting)
        {:ok, state}

      {:handshake_finished, lkm, rkm, profile, packets} ->
        Logger.debug("DTLS handshake finished")
        state = update_remote_cert_info(state)
        :ok = do_send(state, packets)

        peer_fingerprint =
          state.dtls
          |> ExDTLS.get_peer_cert()
          |> ExDTLS.get_cert_fingerprint()
          |> Utils.hex_dump()

        if peer_fingerprint == state.peer_fingerprint do
          :ok = setup_srtp(state, lkm, rkm, profile)
          state = update_dtls_state(state, :connected)
          state = flush_buffered_remote_rtp_packets(state)
          {:ok, state}
        else
          Logger.debug("Non-matching peer cert fingerprint.")
          state = update_dtls_state(state, :failed)
          {:ok, state}
        end

      {:handshake_finished, lkm, rkm, profile} ->
        Logger.debug("DTLS handshake finished")
        :ok = setup_srtp(state, lkm, rkm, profile)
        state = update_dtls_state(state, :connected)
        state = flush_buffered_remote_rtp_packets(state)
        state = update_remote_cert_info(state)
        {:ok, state}

      :handshake_want_read ->
        {:ok, state}

      {:ok, data} ->
        notify(state.owner, {:data, data})
        {:ok, state}

      {:error, reason} = error ->
        # TODO: consider buffering DTLS packets that came out of order during the handshake
        Logger.debug("DTLS error: #{reason}")
        error
    end
  end

  defp handle_ice_data({:data, <<f, _rest::binary>> = data}, %{dtls_state: :connected} = state)
       when f in 128..191 do
    {type, unprotect} =
      case data do
        <<_, s, _::binary>> when s in 192..223 -> {:rtcp, &ExLibSRTP.unprotect_rtcp/2}
        _ -> {:rtp, &ExLibSRTP.unprotect/2}
      end

    case unprotect.(state.in_srtp, data) do
      {:ok, payload} ->
        notify(state.owner, {type, payload})

      {:error, reason} ->
        type = type |> Atom.to_string() |> String.upcase()
        Logger.warning("Failed to decrypt #{type}, reason: #{inspect(reason)}")
    end

    {:ok, state}
  end

  defp handle_ice_data({:data, data}, state) do
    Logger.debug("""
    Received RTP/RTCP packets, but DTLS handshake hasn't been finished yet. \
    They will be processed after the completion of the handshake.\
    """)

    state = %{state | buffered_remote_rtp_packets: [data | state.buffered_remote_rtp_packets]}
    {:ok, state}
  end

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

    :ok
  end

  defp update_dtls_state(state, dtls_state, otps \\ [])
  defp update_dtls_state(%{dtls_state: dtls_state} = state, dtls_state, _opts), do: state

  defp update_dtls_state(state, new_dtls_state, opts) do
    Logger.debug("Changing DTLS state: #{state.dtls_state} -> #{new_dtls_state}")

    if opts[:notify] != false do
      notify(state.owner, {:state_change, new_dtls_state})
    end

    %{state | dtls_state: new_dtls_state}
  end

  defp update_remote_cert_info(state) do
    cert = ExDTLS.get_cert(state.dtls)
    fingerprint = ExDTLS.get_cert_fingerprint(cert)
    base64_cert = Base.encode64(cert)

    %{state | remote_cert: cert, remote_base64_cert: base64_cert, remote_fingerprint: fingerprint}
  end

  defp flush_buffered_remote_rtp_packets(state) do
    for data <- Enum.reverse(state.buffered_remote_rtp_packets) do
      send(self(), {:ex_ice, state.ice_pid, {:data, data}})
    end

    %{state | buffered_remote_rtp_packets: []}
  end

  defp do_send(state, data) when is_list(data) do
    Enum.each(data, &(:ok = do_send(state, &1)))
  end

  defp do_send(%{packet_loss: 0} = state, data),
    do: state.ice_transport.send_data(state.ice_pid, data)

  defp do_send(state, data) do
    if Enum.random(1..100) > state.packet_loss do
      state.ice_transport.send_data(state.ice_pid, data)
    else
      :ok
    end
  end

  defp notify(dst, msg), do: send(dst, {:dtls_transport, self(), msg})
end
