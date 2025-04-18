defmodule ExWebRTC.DTLSTransportTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{DTLSTransport, Utils}

  {_pkey, cert} = ExDTLS.generate_key_cert()

  @fingerprint cert
               |> ExDTLS.get_cert_fingerprint()
               |> Utils.hex_dump()

  @rtp_header <<1::1, 0::1, 0::1, 0::1, 0::4, 0::1, 96::7, 1::16, 1::32, 1::32>>
  @rtp_payload <<0>>
  @rtp_packet <<@rtp_header::binary, @rtp_payload::binary>>

  # empty rr packet
  @rtcp_rr_header <<2::2, 0::1, 0::5, 201::8, 1::16, 1::32>>
  @rtcp_rr_packet <<@rtcp_rr_header::binary>>

  defmodule MockICETransport do
    @behaviour ExWebRTC.ICETransport

    use GenServer

    @impl true
    def start_link(config), do: GenServer.start_link(__MODULE__, config)

    @impl true
    def on_data(ice_pid, dst_pid), do: GenServer.call(ice_pid, {:on_data, dst_pid})

    @impl true
    def send_data(ice_pid, data), do: GenServer.cast(ice_pid, {:send_data, data})

    @impl true
    def add_remote_candidate(ice_pid, _candidate), do: ice_pid

    @impl true
    def end_of_candidates(ice_pid), do: ice_pid

    @impl true
    def gather_candidates(ice_pid), do: ice_pid

    @impl true
    def get_role(ice_pid) do
      GenServer.call(ice_pid, :get_role)
    end

    @impl true
    def get_local_credentials(_state), do: {:ok, "testufrag", "testpwd"}

    @impl true
    def get_local_candidates(_ice_pid), do: []

    @impl true
    def get_remote_candidates(_ice_pid), do: []

    @impl true
    def restart(ice_pid), do: ice_pid

    @impl true
    def set_remote_credentials(ice_pid, _ufrag, _pwd), do: ice_pid

    @impl true
    def set_role(ice_pid, role) do
      GenServer.cast(ice_pid, {:set_role, role})
    end

    @impl true
    def get_stats(_ice_pid), do: %{}

    @impl true
    def stop(ice_pid), do: GenServer.stop(ice_pid)

    def send_dtls(ice_pid, data), do: GenServer.cast(ice_pid, {:send_dtls, data})

    @impl true
    def init(tester: tester),
      do: {:ok, %{role: nil, on_data_dst: nil, tester: tester}}

    @impl true
    def handle_call({:on_data, dst_pid}, _from, state) do
      {:reply, :ok, %{state | on_data_dst: dst_pid}}
    end

    @impl true
    def handle_call(:get_role, _from, state) do
      {:reply, state.role, state}
    end

    @impl true
    def handle_cast({:set_role, role}, state) do
      {:noreply, %{state | role: role}}
    end

    @impl true
    def handle_cast({:send_data, data}, state) do
      send(state.tester, {:mock_ice, data})
      {:noreply, state}
    end

    @impl true
    def handle_cast({:send_dtls, data}, state) do
      send(state.on_data_dst, {:ex_ice, self(), data})
      {:noreply, state}
    end
  end

  setup do
    {:ok, ice_pid} = MockICETransport.start_link(tester: self())
    assert {:ok, dtls} = DTLSTransport.start_link(MockICETransport, ice_pid)
    MockICETransport.on_data(ice_pid, dtls)
    assert_receive {:dtls_transport, ^dtls, {:state_change, :new}}

    %{dtls: dtls, ice_transport: MockICETransport, ice_pid: ice_pid}
  end

  test "cannot send data when handshake not finished", %{dtls: dtls} do
    DTLSTransport.send_rtp(dtls, @rtp_packet)

    refute_receive {:mock_ice, _data}
  end

  test "buffers incoming data if DTLSTransport has not been started", %{
    dtls: dtls,
    ice_transport: ice_transport,
    ice_pid: ice_pid
  } do
    :ok = DTLSTransport.set_ice_connected(dtls)

    remote_dtls = ExDTLS.init(mode: :client, dtls_srtp: true)
    {packets, _timeout} = ExDTLS.do_handshake(remote_dtls)

    Enum.each(packets, &ice_transport.send_dtls(ice_pid, {:data, &1}))
    refute_receive {:mock_ice, _packets}

    :ok = DTLSTransport.start_dtls(dtls, :passive, @fingerprint)

    assert_receive {:mock_ice, packets}
    assert is_binary(packets)
  end

  test "cannot start dtls more than once", %{dtls: dtls} do
    assert :ok = DTLSTransport.start_dtls(dtls, :passive, @fingerprint)
    assert {:error, :already_started} = DTLSTransport.start_dtls(dtls, :passive, @fingerprint)
  end

  test "initiates DTLS handshake when in active mode", %{dtls: dtls} do
    :ok = DTLSTransport.start_dtls(dtls, :active, @fingerprint)

    :ok = DTLSTransport.set_ice_connected(dtls)

    assert_receive {:mock_ice, packets}
    assert is_binary(packets)
  end

  test "won't initiate DTLS handshake when in passive mode", %{dtls: dtls} do
    :ok = DTLSTransport.start_dtls(dtls, :passive, @fingerprint)

    :ok = DTLSTransport.set_ice_connected(dtls)

    refute_receive({:mock_ice, _msg})
  end

  test "will retransmit after initiating handshake", %{dtls: dtls} do
    :ok = DTLSTransport.start_dtls(dtls, :active, @fingerprint)

    :ok = DTLSTransport.set_ice_connected(dtls)

    assert_receive {:mock_ice, _packets}

    assert_receive {:mock_ice, _retransmitted},
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

    Enum.each(packets, &ice_transport.send_dtls(ice_pid, {:data, &1}))
    refute_receive {:mock_ice, _packets}

    :ok = DTLSTransport.set_ice_connected(dtls)
    assert_receive {:mock_ice, packets}
    assert is_binary(packets)
  end

  test "finishes handshake in active mode", %{
    dtls: dtls,
    ice_transport: ice_transport,
    ice_pid: ice_pid
  } do
    :ok = DTLSTransport.start_dtls(dtls, :active, @fingerprint)
    remote_dtls = ExDTLS.init(mode: :server, dtls_srtp: true)

    :ok = DTLSTransport.set_ice_connected(dtls)

    assert :ok = check_handshake(dtls, ice_transport, ice_pid, remote_dtls)
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connecting}}
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connected}}

    # assert we can send data
    assert :ok = DTLSTransport.send_rtp(dtls, @rtp_packet)
    assert_receive {:mock_ice, <<@rtp_header::binary, _payload::binary>>}
    assert :ok = DTLSTransport.send_rtcp(dtls, @rtcp_rr_packet)
    assert_receive {:mock_ice, <<@rtcp_rr_header::binary, _payload::binary>>}
    assert :ok = DTLSTransport.send_data(dtls, <<1, 2, 3>>)
    assert_receive {:mock_ice, _datachannel_packet}
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
    :ok = DTLSTransport.set_ice_connected(dtls)

    Enum.each(packets, &ice_transport.send_dtls(ice_pid, {:data, &1}))

    assert :ok == check_handshake(dtls, ice_transport, ice_pid, remote_dtls)
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connecting}}
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connected}}

    # assert we can send data
    assert :ok = DTLSTransport.send_rtp(dtls, @rtp_packet)
    assert_receive {:mock_ice, <<@rtp_header::binary, _payload::binary>>}
    assert :ok = DTLSTransport.send_rtcp(dtls, @rtcp_rr_packet)
    assert_receive {:mock_ice, <<@rtcp_rr_header::binary, _payload::binary>>}
    assert :ok = DTLSTransport.send_data(dtls, <<1, 2, 3>>)
    assert_receive {:mock_ice, _datachannel_packet}
  end

  test "drops packets when packet loss is set", %{
    dtls: dtls,
    ice_transport: ice_transport,
    ice_pid: ice_pid
  } do
    :ok = DTLSTransport.start_dtls(dtls, :active, @fingerprint)
    remote_dtls = ExDTLS.init(mode: :server, dtls_srtp: true)

    :ok = DTLSTransport.set_ice_connected(dtls)

    assert :ok = check_handshake(dtls, ice_transport, ice_pid, remote_dtls)
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connecting}}
    assert_receive {:dtls_transport, ^dtls, {:state_change, :connected}}

    # assert we can send data
    DTLSTransport.send_rtp(dtls, @rtp_packet)
    assert_receive {:mock_ice, <<@rtp_header::binary, _payload::binary>>}
    DTLSTransport.send_rtcp(dtls, @rtcp_rr_packet)
    assert_receive {:mock_ice, <<@rtcp_rr_packet::binary, _rest::binary>>}
    DTLSTransport.send_data(dtls, <<1, 2, 3>>)
    assert_receive {:mock_ice, _datachannel_packet}

    # now set packet-loss
    DTLSTransport.set_packet_loss(dtls, 100)
    DTLSTransport.send_rtp(dtls, @rtp_packet)
    refute_receive {:mock_ice, _rtp_packet}
    DTLSTransport.send_rtcp(dtls, @rtcp_rr_packet)
    refute_receive {:mock_ice, _rtcp_rr_packet}
    DTLSTransport.send_data(dtls, <<1, 2, 3>>)
    refute_receive {:mock_ice, _datachannel_packet}
  end

  defp check_handshake(dtls, ice_transport, ice_pid, remote_dtls) do
    assert_receive {:mock_ice, packets}

    case ExDTLS.handle_data(remote_dtls, packets) do
      :handshake_want_read ->
        check_handshake(dtls, ice_transport, ice_pid, remote_dtls)

      {:handshake_packets, packets, _timeout} ->
        Enum.each(packets, &ice_transport.send_dtls(ice_pid, {:data, &1}))
        check_handshake(dtls, ice_transport, ice_pid, remote_dtls)

      {:handshake_finished, _, _, _, packets} ->
        Enum.each(packets, &ice_transport.send_dtls(ice_pid, {:data, &1}))
        :ok

      {:handshake_finished, _, _, _} ->
        :ok
    end
  end

  test "stop/1", %{dtls: dtls} do
    assert :ok == DTLSTransport.stop(dtls)
    assert false == Process.alive?(dtls)
  end
end
