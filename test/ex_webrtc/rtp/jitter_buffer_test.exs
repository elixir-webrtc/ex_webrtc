defmodule ExWebRTC.RTP.JitterBufferTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.JitterBuffer.PacketStore.Record
  alias ExWebRTC.RTP.JitterBuffer.PacketStore
  alias ExWebRTC.RTP.{JitterBuffer, PacketFactory}

  @base_seq_number PacketFactory.base_seq_number()

  setup do
    packet = PacketFactory.sample_packet(@base_seq_number)

    {:ok, state} = JitterBuffer.init(controlling_process: self(), latency: 10)
    state = %{state | waiting?: false}

    [state: state, packet: packet]
  end

  describe "When JitterBuffer is in waiting state" do
    setup %{state: state} do
      [state: %{state | waiting?: true}]
    end

    test "start of stream starts timer that changes state", %{state: state} do
      {:noreply, state} = JitterBuffer.handle_cast(:start_timer, state)
      assert_receive message, state.latency + 5
      {:noreply, final_state} = JitterBuffer.handle_info(message, state)
      assert final_state.waiting? == false
    end

    test "any new packet is kept", %{state: state, packet: packet} do
      assert PacketStore.dump(state.store) == []
      {:noreply, state} = JitterBuffer.handle_cast({:packet, packet}, state)

      %{store: store} = state
      {%Record{packet: ^packet}, new_store} = PacketStore.flush_one(store)
      assert PacketStore.dump(new_store) == []

      refute_receive {:jitter_buffer, _pid, {:packet, ^packet}}
    end
  end

  describe "When new packet arrives when not waiting and already pushed some packet" do
    setup %{state: state} do
      flush_index = @base_seq_number - 1
      store = %{state.store | flush_index: flush_index, highest_incoming_index: flush_index}
      [state: %{state | waiting?: false, store: store}]
    end

    test "outputs it immediately if it is in order", %{state: state, packet: packet} do
      {:noreply, state} = JitterBuffer.handle_cast({:packet, packet}, state)

      assert_receive {:jitter_buffer, _pid, {:packet, ^packet}}

      %{store: store} = state
      assert PacketStore.dump(store) == []
    end

    test "refuses to add that packet when it comes too late", %{state: state} do
      late_packet = PacketFactory.sample_packet(@base_seq_number - 2)
      {:noreply, new_state} = JitterBuffer.handle_cast({:packet, late_packet}, state)
      assert new_state == state
      refute_receive {:jitter_buffer, _pid, {:packet, ^late_packet}}
    end

    test "adds it and when it fills the gap, returns all packets in order", %{state: state} do
      first_packet = PacketFactory.sample_packet(@base_seq_number)
      second_packet = PacketFactory.sample_packet(@base_seq_number + 1)
      third_packet = PacketFactory.sample_packet(@base_seq_number + 2)

      flush_index = @base_seq_number - 1

      store = %PacketStore{
        state.store
        | flush_index: flush_index,
          highest_incoming_index: flush_index
      }

      {:ok, store} = PacketStore.insert_packet(store, second_packet)
      {:ok, store} = PacketStore.insert_packet(store, third_packet)

      state = %{state | store: store}

      {:noreply, %{store: result_store}} =
        JitterBuffer.handle_cast({:packet, first_packet}, state)

      for packet <- [first_packet, second_packet, third_packet] do
        receive do
          msg ->
            assert {:jitter_buffer, _pid, {:packet, ^packet}} = msg
        end
      end

      assert PacketStore.dump(result_store) == []
      refute_receive {:jitter_buffer, _pid, {:packet, _packet}}
    end
  end

  describe "When latency passes without filling the gap, JitterBuffer" do
    test "outputs discontinuity and late packet", %{state: state, packet: packet} do
      flush_index = @base_seq_number - 2

      store = %PacketStore{
        state.store
        | flush_index: flush_index,
          highest_incoming_index: flush_index
      }

      state = %{state | store: store, waiting?: false}

      {:noreply, state} = JitterBuffer.handle_cast({:packet, packet}, state)
      refute_received {:jitter_buffer, _pid, {:packet, ^packet}}

      assert is_reference(state.max_latency_timer)

      receive do
        msg ->
          {:noreply, _state} = JitterBuffer.handle_info(msg, state)
      end

      assert_receive {:jitter_buffer, _pid, {:packet, ^packet}}
    end
  end

  describe "When asked to flush, JitterBuffer" do
    test "dumps store and resets itself", %{state: state, packet: packet} do
      flush_index = @base_seq_number - 2

      store = %PacketStore{
        state.store
        | flush_index: flush_index,
          highest_incoming_index: flush_index
      }

      {:ok, store} = PacketStore.insert_packet(store, packet)
      state = %{state | store: store}
      {:noreply, state} = JitterBuffer.handle_cast(:flush, state)

      assert_receive {:jitter_buffer, _pid, {:packet, ^packet}}
      assert state.store == %PacketStore{}
    end
  end
end
