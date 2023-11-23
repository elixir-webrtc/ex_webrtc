defmodule ExWebRTC.DTLSTransportTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.DTLSTransport

  defmodule FakeICEAgent do
    use GenServer

    def start_link(_mode, config) do
      GenServer.start_link(__MODULE__, {self(), config})
    end

    def send_data(ice_agent, data) do
      GenServer.cast(ice_agent, {:send_data, data})
    end

    def send_dtls(ice_agent, data) do
      GenServer.cast(ice_agent, {:send_dtls, data})
    end

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
    assert {:ok, dtls} = DTLSTransport.start_link([tester: self()], FakeICEAgent)
    assert_receive {:dtls_transport, ^dtls, {:state_change, :new}}
    ice = DTLSTransport.get_ice_agent(dtls)
    assert is_pid(ice)

    %{dtls: dtls, ice: ice}
  end

  test "forwards non-data ICE messages", %{ice: ice} do
    message = :connected

    FakeICEAgent.send_dtls(ice, message)
    assert_receive {:ex_ice, _from, ^message}

    FakeICEAgent.send_dtls(ice, {:data, <<1, 2, 3>>})
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

  test "initiates DTLS handshake when in active mode", %{dtls: dtls, ice: ice} do
    :ok = DTLSTransport.start_dtls(dtls, :active)

    FakeICEAgent.send_dtls(ice, :connected)

    assert_receive {:fake_ice, packets}
    assert is_binary(packets)
  end

  test "won't initiate DTLS handshake when in passive mode", %{dtls: dtls, ice: ice} do
    :ok = DTLSTransport.start_dtls(dtls, :passive)

    FakeICEAgent.send_dtls(ice, :connected)

    refute_receive({:fake_ice, _msg})
  end

  test "will retransmit after initiating handshake", %{dtls: dtls, ice: ice} do
    :ok = DTLSTransport.start_dtls(dtls, :active)

    FakeICEAgent.send_dtls(ice, :connected)

    assert_receive {:fake_ice, _packets}
    assert_receive {:fake_ice, _retransmited}, 1100
  end

  test "will buffer packets and send when connected", %{dtls: dtls, ice: ice} do
    :ok = DTLSTransport.start_dtls(dtls, :passive)

    remote_dtls = ExDTLS.init(client_mode: true, dtls_srtp: true)
    {packets, _timeout} = ExDTLS.do_handshake(remote_dtls)

    FakeICEAgent.send_dtls(ice, {:data, packets})
    refute_receive {:fake_ice, _packets}

    FakeICEAgent.send_dtls(ice, :connected)
    assert_receive {:fake_ice, packets}
    assert is_binary(packets)
  end

  test "finishes handshake in active mode", %{dtls: dtls, ice: ice} do
    :ok = DTLSTransport.start_dtls(dtls, :active)
    remote_dtls = ExDTLS.init(client_mode: false, dtls_srtp: true)

    FakeICEAgent.send_dtls(ice, :connected)

    assert :ok = check_handshake(dtls, ice, remote_dtls)
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connecting}}
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connected}}
  end

  test "finishes handshake in passive mode", %{dtls: dtls, ice: ice} do
    :ok = DTLSTransport.start_dtls(dtls, :passive)
    FakeICEAgent.send_dtls(ice, :connected)

    remote_dtls = ExDTLS.init(client_mode: true, dtls_srtp: true)
    {packets, _timeout} = ExDTLS.do_handshake(remote_dtls)
    FakeICEAgent.send_dtls(ice, {:data, packets})

    assert :ok == check_handshake(dtls, ice, remote_dtls)
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connecting}}
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connected}}
  end

  defp check_handshake(dtls, ice, remote_dtls) do
    assert_receive {:fake_ice, packets}

    case ExDTLS.handle_data(remote_dtls, packets) do
      {:handshake_packets, packets, _timeout} ->
        FakeICEAgent.send_dtls(ice, {:data, packets})
        check_handshake(dtls, ice, remote_dtls)

      {:handshake_finished, _, _, _, packets} ->
        FakeICEAgent.send_dtls(ice, {:data, packets})
        :ok

      {:handshake_finished, _, _, _} ->
        :ok
    end
  end
end
