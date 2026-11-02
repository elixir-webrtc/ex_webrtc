defmodule ExWebRTC.SCTPTransportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ExWebRTC.{DataChannel, SCTPTransport}
  alias ExWebRTC.SCTPTransport.DCEP

  @dcep_ppi 50
  @string_ppi 51

  test "locally opened channel is open right after OPEN is sent" do
    {local, remote, ref, _remote_events} = connected_with_channel("label", true)

    assert %DataChannel{ready_state: :open, id: 0} = SCTPTransport.get_channel(local, ref)

    assert_delivered(local, remote, ref, "hi")
  end

  test "peer that never ACKs but sends data" do
    {local, remote, ref, _remote_events} = connected_with_channel("label", true)

    :ok = ExSCTP.send(remote, 0, @string_ppi, "hello")
    {local_events, _remote_events, local} = drain_remote(local, remote)

    assert local_events == [{:data, ref, "hello"}]
    assert %DataChannel{ready_state: :open} = SCTPTransport.get_channel(local, ref)

    :ok = ExSCTP.send(remote, 0, @dcep_ppi, DCEP.encode(%DCEP.DataChannelAck{}))
    {local_events, _remote_events, local} = drain_remote(local, remote)

    assert local_events == []
    assert %DataChannel{ready_state: :open} = SCTPTransport.get_channel(local, ref)

    assert_delivered(local, remote, ref, "still there")
  end

  test "compliant peer ACKs" do
    {local, remote, ref, _remote_events} = connected_with_channel("label", true)

    :ok = ExSCTP.send(remote, 0, @dcep_ppi, DCEP.encode(%DCEP.DataChannelAck{}))
    {local_events, _remote_events, local} = drain_remote(local, remote)

    # :open was already emitted when OPEN was sent, the ACK confirms silently
    assert local_events == []
    assert %DataChannel{ready_state: :open} = SCTPTransport.get_channel(local, ref)

    local = assert_delivered(local, remote, ref, "ping")

    # remote holds new data until its ACK is SACKed, which happens on local's delayed-SACK timer
    :ok = ExSCTP.send(remote, 0, @string_ppi, "pong")
    {local_events, _remote_events, local} = drain_remote(local, remote)
    {local_events, _local} = await_local_event(local, remote, {:data, ref, "pong"}, local_events)

    assert local_events == [{:data, ref, "pong"}]
  end

  test "ACK on a stream without a channel is ignored" do
    {local, remote} = connected_pair()

    :ok = ExSCTP.open_stream(remote, 1)
    :ok = ExSCTP.send(remote, 1, @dcep_ppi, DCEP.encode(%DCEP.DataChannelAck{}))
    {local_events, remote_events, local} = drain_remote(local, remote)

    assert local_events == []
    refute {:stream_closed, 1} in remote_events
    assert SCTPTransport.channel_count(local) == 0

    {:ok, events, %DataChannel{ref: ref}, local} =
      SCTPTransport.add_channel(local, "after", true, "", nil, nil)

    {local_events, remote_events, local} = pump({events, local}, remote)

    assert local_events == [{:state_change, ref, :open}]
    assert %DataChannel{ready_state: :open, id: 0} = SCTPTransport.get_channel(local, ref)
    assert %DCEP.DataChannelOpen{label: "after"} = received_open(remote_events, 0)
  end

  test "unordered channel" do
    {local, remote, ref, remote_events} = connected_with_channel("u", false)

    assert %DCEP.DataChannelOpen{label: "u", order: :unordered} = received_open(remote_events, 0)

    :ok = ExSCTP.send(remote, 0, @string_ppi, "hello")
    {local_events, _remote_events, local} = drain_remote(local, remote)

    assert local_events == [{:data, ref, "hello"}]

    assert %DataChannel{ready_state: :open, ordered: false} =
             SCTPTransport.get_channel(local, ref)

    assert_delivered(local, remote, ref, "hi")
  end

  test "closing an unconfirmed channel" do
    {local, remote, ref, _remote_events} = connected_with_channel("label", true)

    {close_events, local} = SCTPTransport.close_channel(local, ref)
    assert SCTPTransport.channel_count(local) == 0

    # queue the ACK before the stream reset reaches remote,
    # so it is delivered to local after the channel was popped
    :ok = ExSCTP.send(remote, 0, @dcep_ppi, DCEP.encode(%DCEP.DataChannelAck{}))

    log =
      capture_log(fn ->
        {local_events, _remote_events, local} = pump({close_events, local}, remote)

        assert local_events == [{:state_change, ref, :closed}]
        assert SCTPTransport.channel_count(local) == 0
      end)

    assert log =~ "Received DCEP Ack without sending the DCEP Open message on stream 0"
    refute log =~ "Received invalid DCEP message"
  end

  defp connected_pair do
    {local, remote, [], _remote_events} = connect(SCTPTransport.new())
    {local, remote}
  end

  defp connected_with_channel(label, ordered) do
    {:ok, [], %DataChannel{ref: ref, id: nil, ready_state: :connecting}, local} =
      SCTPTransport.add_channel(SCTPTransport.new(), label, ordered, "", nil, nil)

    {local, remote, local_events, remote_events} = connect(local)

    assert local_events == [{:state_change, ref, :open}]
    assert {:stream_opened, 0} in remote_events
    assert %DCEP.DataChannelOpen{label: ^label} = received_open(remote_events, 0)

    {local, remote, ref, remote_events}
  end

  # Connects `local` (as the active side, so its channel ids are even) to a fresh raw
  # `ExSCTP` peer and returns both plus the events each side saw during the handshake.
  defp connect(local) do
    local = SCTPTransport.set_role(local, :active)
    remote = ExSCTP.new()

    {local_events, remote_events, local} = pump(SCTPTransport.connect(local), remote)
    assert :connected in remote_events

    {local, remote, local_events, remote_events}
  end

  defp received_open(remote_events, id) do
    Enum.find_value(remote_events, fn
      {:data, ^id, @dcep_ppi, bin} ->
        {:ok, %DCEP.DataChannelOpen{} = dco} = DCEP.decode(bin)
        dco

      _other ->
        nil
    end)
  end

  # Forwards local transmits to `remote`, then drains `remote`, feeding its transmits back
  # into `local`, until neither side has anything left to send.
  # Returns `{local_events, remote_events, local}` without transmits/timeouts.
  defp pump({events, local}, remote, {local_acc, remote_acc} \\ {[], []}) do
    {packets, local_events} = Enum.split_with(events, &match?({:transmit, _}, &1))

    Enum.each(packets, fn {:transmit, pkts} ->
      Enum.each(pkts, &(:ok = ExSCTP.handle_data(remote, &1)))
    end)

    drain_remote(local, remote, {local_acc ++ local_events, remote_acc})
  end

  # Fires local SCTP timers (scheduled as `:sctp_timeout` messages) and pumps
  # until `expected` shows up among local events.
  defp await_local_event(local, remote, expected, acc) do
    if expected in acc do
      {acc, local}
    else
      assert_receive :sctp_timeout, 1_000
      {local_events, _remote_events, local} = pump(SCTPTransport.handle_timeout(local), remote)
      await_local_event(local, remote, expected, acc ++ local_events)
    end
  end

  defp assert_delivered(local, remote, ref, msg) do
    {local_events, remote_events, local} =
      pump(SCTPTransport.send(local, ref, :string, msg), remote)

    assert local_events == []
    assert {:data, 0, @string_ppi, msg} in remote_events
    local
  end

  defp drain_remote(local, remote, {local_acc, remote_acc} \\ {[], []}) do
    case ExSCTP.poll(remote) do
      :none ->
        {local_acc, remote_acc, local}

      {:timeout, _val} ->
        drain_remote(local, remote, {local_acc, remote_acc})

      {:transmit, pkts} ->
        {local_acc, remote_acc, local} =
          Enum.reduce(pkts, {local_acc, remote_acc, local}, fn pkt, {l_acc, r_acc, local} ->
            pump(SCTPTransport.handle_data(local, pkt), remote, {l_acc, r_acc})
          end)

        drain_remote(local, remote, {local_acc, remote_acc})

      event ->
        drain_remote(local, remote, {local_acc, remote_acc ++ [event]})
    end
  end
end
