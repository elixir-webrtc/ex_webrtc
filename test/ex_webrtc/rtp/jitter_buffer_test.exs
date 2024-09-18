defmodule ExWebRTC.RTP.JitterBufferTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.JitterBuffer.PacketStore
  alias ExWebRTC.RTP.{JitterBuffer, PacketFactory}

  @base_seq_number PacketFactory.base_seq_number()
  @buffer_latency_ms 10

  setup do
    packet = PacketFactory.sample_packet(@base_seq_number)

    buffer = JitterBuffer.new(latency: @buffer_latency_ms)
    buffer = %{buffer | state: :timer_not_set}

    [buffer: buffer, packet: packet]
  end

  describe "When JitterBuffer is in initial_wait state" do
    setup do
      [buffer: JitterBuffer.new(latency: @buffer_latency_ms)]
    end

    test "first packet starts timer that changes state", %{buffer: buffer, packet: packet} do
      assert buffer.state == :initial_wait
      {[], timer, buffer} = JitterBuffer.insert(buffer, packet)
      assert timer == buffer.latency
      {_packets, _timer, buffer} = JitterBuffer.handle_timeout(buffer)
      assert buffer.state != :initial_wait
    end

    test "any new packet is kept", %{buffer: buffer, packet: packet} do
      {[], _timer, buffer} = JitterBuffer.flush(buffer)
      {[], _timer, buffer} = JitterBuffer.insert(buffer, packet)

      {[^packet], _timer, buffer} = JitterBuffer.flush(buffer)
      {[], _timer, _buffer} = JitterBuffer.flush(buffer)
    end
  end

  describe "When new packet arrives when not waiting and already pushed some packet" do
    setup %{buffer: buffer} do
      flush_index = @base_seq_number - 1
      store = %{buffer.store | flush_index: flush_index, highest_incoming_index: flush_index}
      [buffer: %{buffer | state: :timer_not_set, store: store}]
    end

    test "outputs it immediately if it is in order", %{buffer: buffer, packet: packet} do
      {[^packet], _timer, buffer} = JitterBuffer.insert(buffer, packet)
      {[], _timer, _buffer} = JitterBuffer.flush(buffer)
    end

    test "refuses to add that packet when it comes too late", %{buffer: buffer} do
      late_packet = PacketFactory.sample_packet(@base_seq_number - 2)
      {[], nil, new_buffer} = JitterBuffer.insert(buffer, late_packet)
      assert new_buffer == buffer
    end

    test "adds it and when it fills the gap, returns all packets in order", %{buffer: buffer} do
      first_packet = PacketFactory.sample_packet(@base_seq_number)
      second_packet = PacketFactory.sample_packet(@base_seq_number + 1)
      third_packet = PacketFactory.sample_packet(@base_seq_number + 2)

      flush_index = @base_seq_number - 1

      store = %PacketStore{
        buffer.store
        | flush_index: flush_index,
          highest_incoming_index: flush_index
      }

      buffer = %{buffer | store: store}

      {[], _timer, buffer} = JitterBuffer.insert(buffer, second_packet)
      {[], _timer, buffer} = JitterBuffer.insert(buffer, third_packet)

      {packets, _timer, buffer} = JitterBuffer.insert(buffer, first_packet)

      assert packets == [first_packet, second_packet, third_packet]

      {[], _timer, _buffer} = JitterBuffer.flush(buffer)
    end
  end

  describe "When latency passes without filling the gap, JitterBuffer" do
    test "outputs the late packet", %{buffer: buffer, packet: packet} do
      flush_index = @base_seq_number - 2

      store = %PacketStore{
        buffer.store
        | flush_index: flush_index,
          highest_incoming_index: flush_index
      }

      buffer = %{buffer | store: store, state: :timer_not_set}

      {[], timer, buffer} = JitterBuffer.insert(buffer, packet)
      assert timer != nil
      assert buffer.state == :timer_set

      Process.sleep(buffer.latency + 5)
      {[^packet], _timer, _buffer} = JitterBuffer.handle_timeout(buffer)
    end
  end

  describe "When asked to flush, JitterBuffer" do
    test "dumps store and resets itself", %{buffer: buffer, packet: packet} do
      flush_index = @base_seq_number - 2

      store = %PacketStore{
        buffer.store
        | flush_index: flush_index,
          highest_incoming_index: flush_index
      }

      buffer = %{buffer | store: store}
      {[], _timer, buffer} = JitterBuffer.insert(buffer, packet)

      {[^packet], nil, buffer} = JitterBuffer.flush(buffer)

      assert buffer.store == %PacketStore{}

      {[], nil, _buffer} = JitterBuffer.flush(buffer)
    end
  end
end
