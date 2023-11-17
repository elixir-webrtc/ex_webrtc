defmodule ExWebRTC.DTLSTransportTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.DTLSTransport

  defmodule FakeICEAgent do
    use GenServer

    def start_link(_mode, config) do
      GenServer.start_link(__MODULE__, config)
    end

    def send_data(ice_agent, data) do
      GenServer.cast(ice_agent, {:send_data, data})
    end

    @impl true
    def init(tester: tester), do: {:ok, tester}

    @impl true
    def handle_cast({:send_data, data}, tester) do
      send(tester, {:fake_ice, data})
      {:noreply, tester}
    end
  end

  setup do
    assert {:ok, dtls} = DTLSTransport.start_link([tester: self()], FakeICEAgent)

    %{dtls: dtls}
  end

  test "forwards non-data ICE messages", %{dtls: dtls} do
    message = "test message"

    send_ice(dtls, message)
    assert_receive {:ex_ice, _from, ^message}

    send_ice(dtls, {:data, <<1, 2, 3>>})
    refute_receive {:ex_ice, _from, _msg}
  end

  test "cannot send data when handshake not finished", %{dtls: dtls} do
    DTLSTransport.send_data(dtls, <<1, 2, 3>>)

    refute_receive {:fake_ice, _data}
  end

  test "cannot start dtls more than once", %{dtls: dtls} do
    assert :ok = DTLSTransport.start_dtls(dtls, :passive)
    assert {:error, :already_started} = DTLSTransport.start_dtls(dtls, :passive)
  end

  test "initiates DTLS handshake when in active mode", %{dtls: dtls} do
    :ok = DTLSTransport.start_dtls(dtls, :active)

    send_ice(dtls, :connected)

    assert_receive {:fake_ice, packets}
    assert is_binary(packets)
  end

  test "won't initiate DTLS handshake when in passive mode", %{dtls: dtls} do
    :ok = DTLSTransport.start_dtls(dtls, :passive)

    send_ice(dtls, :connected)

    refute_receive({:fake_ice, _msg})
  end

  test "will retransmit after initiating handshake", %{dtls: dtls} do
    :ok = DTLSTransport.start_dtls(dtls, :active)

    send_ice(dtls, :connected)

    assert_receive {:fake_ice, _packets}
    assert_receive {:fake_ice, _retransmited}, 1200
  end

  test "will buffer packets and send when connected", %{dtls: dtls} do
    :ok = DTLSTransport.start_dtls(dtls, :passive)

    remote_dtls = ExDTLS.init(client_mode: true, dtls_srtp: true)
    {packets, _timeout} = ExDTLS.do_handshake(remote_dtls)

    send_ice(dtls, {:data, packets})
    refute_receive {:fake_ice, _packets}

    send_ice(dtls, :connected)
    assert_receive {:fake_ice, packets}
    assert is_binary(packets)
  end

  test "finishes handshake in actice mode", %{dtls: dtls} do
    :ok = DTLSTransport.start_dtls(dtls, :active)
    remote_dtls = ExDTLS.init(client_mode: false, dtls_srtp: true)

    send_ice(dtls, :connected)

    assert :ok = check_handshake(dtls, remote_dtls)
  end

  test "finishes handshake in passive mode", %{dtls: dtls} do
    :ok = DTLSTransport.start_dtls(dtls, :passive)
    send_ice(dtls, :connected)

    remote_dtls = ExDTLS.init(client_mode: true, dtls_srtp: true)
    {packets, _timeout} = ExDTLS.do_handshake(remote_dtls)
    send_ice(dtls, {:data, packets})

    assert :ok == check_handshake(dtls, remote_dtls)
  end

  defp check_handshake(dtls, remote_dtls) do
    assert_receive {:fake_ice, packets}

    case ExDTLS.handle_data(remote_dtls, packets) do
      {:handshake_packets, packets, _timeout} ->
        send_ice(dtls, {:data, packets})
        check_handshake(dtls, remote_dtls)

      {:handshake_finished, _, _, _, packets} ->
        send_ice(dtls, {:data, packets})
        :ok

      {:handshake_finished, _, _, _} ->
        :ok
    end
  end

  defp send_ice(dtls, msg), do: send(dtls, {:ex_ice, "dummy_pid", msg})
end
