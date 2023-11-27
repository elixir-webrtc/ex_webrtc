defmodule ExWebRTC.DTLSTransportTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{DTLSTransport, Utils}

  {_pkey, cert} = ExDTLS.generate_key_cert()

  @fingerprint cert
               |> ExDTLS.get_cert_fingerprint()
               |> Utils.hex_dump()

  defmodule MockICETransport do
    @behaviour ExWebRTC.ICETransport

    use GenServer

    @impl true
    def start_link(_mode, config), do: GenServer.start_link(__MODULE__, {self(), config})

    @impl true
    def send_data(ice_pid, data), do: GenServer.cast(ice_pid, {:send_data, data})

    @impl true
    def add_remote_candidate(ice_pid, _candidate), do: ice_pid

    @impl true
    def end_of_candidates(ice_pid), do: ice_pid

    @impl true
    def gather_candidates(ice_pid), do: ice_pid

    @impl true
    def get_local_credentials(_state), do: {:ok, "testufrag", "testpwd"}

    @impl true
    def restart(ice_pid), do: ice_pid

    @impl true
    def set_remote_credentials(ice_pid, _ufrag, _pwd), do: ice_pid

    def send_dtls(ice_pid, data), do: GenServer.cast(ice_pid, {:send_dtls, data})

    @impl true
    def init({dtls, tester: tester}),
      do: {:ok, %{dtls: dtls, tester: tester}}

    @impl true
    def handle_cast({:send_data, data}, state) do
      send(state.tester, {:fake_ice, data})
      {:noreply, state}
    end

    @impl true
    def handle_cast({:send_dtls, data}, state) do
      send(state.dtls, {:ex_ice, self(), data})
      {:noreply, state}
    end
  end

  setup do
    assert {:ok, dtls} = DTLSTransport.start_link(MockICETransport, tester: self())
    assert_receive {:dtls_transport, ^dtls, {:state_change, :new}}
    {ice_transport, ice_pid} = DTLSTransport.get_ice_transport(dtls)

    %{dtls: dtls, ice_transport: ice_transport, ice_pid: ice_pid}
  end

  test "forwards non-data ICE messages", %{ice_transport: ice_transport, ice_pid: ice_pid} do
    message = :connected

    ice_transport.send_dtls(ice_pid, message)
    assert_receive {:ex_ice, _from, ^message}

    ice_transport.send_dtls(ice_pid, {:data, <<1, 2, 3>>})
    refute_receive {:ex_ice, _from, _msg}
  end

  test "cannot send data when handshake not finished", %{dtls: dtls} do
    DTLSTransport.send_rtp(dtls, <<1, 2, 3>>)

    refute_receive {:fake_ice, _data}
  end

  test "cannot start dtls more than once", %{dtls: dtls} do
    assert :ok = DTLSTransport.start_dtls(dtls, :passive, @fingerprint)
    assert {:error, :already_started} = DTLSTransport.start_dtls(dtls, :passive, @fingerprint)
  end

  test "initiates DTLS handshake when in active mode", %{
    dtls: dtls,
    ice_transport: ice_transport,
    ice_pid: ice_pid
  } do
    :ok = DTLSTransport.start_dtls(dtls, :active, @fingerprint)

    ice_transport.send_dtls(ice_pid, {:connection_state_change, :connected})

    assert_receive {:fake_ice, packets}
    assert is_binary(packets)
  end

  test "won't initiate DTLS handshake when in passive mode", %{
    dtls: dtls,
    ice_transport: ice_transport,
    ice_pid: ice_pid
  } do
    :ok = DTLSTransport.start_dtls(dtls, :passive, @fingerprint)

    ice_transport.send_dtls(ice_pid, {:connection_state_change, :connected})

    refute_receive({:fake_ice, _msg})
  end

  test "will retransmit after initiating handshake", %{
    dtls: dtls,
    ice_transport: ice_transport,
    ice_pid: ice_pid
  } do
    :ok = DTLSTransport.start_dtls(dtls, :active, @fingerprint)

    ice_transport.send_dtls(ice_pid, {:connection_state_change, :connected})

    assert_receive {:fake_ice, _packets}

    assert_receive {:fake_ice, _retransmited},
                   1000 + ExUnit.configuration()[:assert_receive_timeout]
  end

  test "will buffer packets and send when connected", %{
    dtls: dtls,
    ice_transport: ice_transport,
    ice_pid: ice_pid
  } do
    :ok = DTLSTransport.start_dtls(dtls, :passive, @fingerprint)

    remote_dtls = ExDTLS.init(mode: :client, dtls_srtp: true)
    {packets, _timeout} = ExDTLS.do_handshake(remote_dtls)

    ice_transport.send_dtls(ice_pid, {:data, packets})
    refute_receive {:fake_ice, _packets}

    ice_transport.send_dtls(ice_pid, {:connection_state_change, :connected})
    assert_receive {:fake_ice, packets}
    assert is_binary(packets)
  end

  test "finishes handshake in active mode", %{
    dtls: dtls,
    ice_transport: ice_transport,
    ice_pid: ice_pid
  } do
    :ok = DTLSTransport.start_dtls(dtls, :active, @fingerprint)
    remote_dtls = ExDTLS.init(mode: :server, dtls_srtp: true)

    ice_transport.send_dtls(ice_pid, {:connection_state_change, :connected})

    assert :ok = check_handshake(dtls, ice_transport, ice_pid, remote_dtls)
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connecting}}
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connected}}
  end

  test "finishes handshake in passive mode", %{
    dtls: dtls,
    ice_transport: ice_transport,
    ice_pid: ice_pid
  } do
    remote_dtls = ExDTLS.init(mode: :client, dtls_srtp: true)

    remote_fingerprint =
      remote_dtls
      |> ExDTLS.get_cert()
      |> ExDTLS.get_cert_fingerprint()
      |> Utils.hex_dump()

    :ok = DTLSTransport.start_dtls(dtls, :passive, remote_fingerprint)

    {packets, _timeout} = ExDTLS.do_handshake(remote_dtls)
    ice_transport.send_dtls(ice_pid, {:connection_state_change, :connected})

    ice_transport.send_dtls(ice_pid, {:data, packets})

    assert :ok == check_handshake(dtls, ice_transport, ice_pid, remote_dtls)
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connecting}}
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connected}}
  end

  defp check_handshake(dtls, ice_transport, ice_pid, remote_dtls) do
    assert_receive {:fake_ice, packets}

    case ExDTLS.handle_data(remote_dtls, packets) do
      {:handshake_packets, packets, _timeout} ->
        ice_transport.send_dtls(ice_pid, {:data, packets})
        check_handshake(dtls, ice_transport, ice_pid, remote_dtls)

      {:handshake_finished, _, _, _, packets} ->
        ice_transport.send_dtls(ice_pid, {:data, packets})
        :ok

      {:handshake_finished, _, _, _} ->
        :ok
    end
  end
end
