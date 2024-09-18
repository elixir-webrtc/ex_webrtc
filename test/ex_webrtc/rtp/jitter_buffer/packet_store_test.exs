defmodule ExWebRTC.RTP.JitterBuffer.PacketStoreTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.PacketFactory
  alias ExWebRTC.RTP.JitterBuffer.PacketStore.Entry
  alias ExWebRTC.RTP.JitterBuffer.{Heap, PacketStore}

  @seq_number_limit 65_536
  @base_index 65_505
  @next_index @base_index + 1

  setup_all do
    [base_store: new_testing_store(@base_index)]
  end

  describe "When adding packet to the PacketStore it" do
    test "accepts the first packet" do
      packet = PacketFactory.sample_packet(@base_index)

      assert {:ok, updated_store} = PacketStore.insert(%PacketStore{}, packet)
      assert has_packet(updated_store, packet)
    end

    test "refuses packet with a seq_number smaller than last served", %{base_store: store} do
      packet = PacketFactory.sample_packet(@base_index - 1)

      assert {:error, :late_packet} = PacketStore.insert(store, packet)
    end

    test "accepts a packet that got in time", %{base_store: store} do
      packet = PacketFactory.sample_packet(@next_index)
      assert {:ok, updated_store} = PacketStore.insert(store, packet)
      assert has_packet(updated_store, packet)
    end

    test "puts it to the rollover if a sequence number has rolled over", %{base_store: store} do
      packet = PacketFactory.sample_packet(10)
      assert {:ok, store} = PacketStore.insert(store, packet)
      assert has_packet(store, packet)
    end

    test "handles first packets starting with sequence_number 0" do
      store = %PacketStore{}
      packet_a = PacketFactory.sample_packet(0)
      assert {:ok, store} = PacketStore.insert(store, packet_a)

      {record_a, store} = PacketStore.flush_one(store)

      assert record_a.index == @seq_number_limit
      assert record_a.packet.sequence_number == 0

      packet_b = PacketFactory.sample_packet(1)
      assert {:ok, store} = PacketStore.insert(store, packet_b)

      {record_b, _store} = PacketStore.flush_one(store)
      assert record_b.index == @seq_number_limit + 1
      assert record_b.packet.sequence_number == 1
    end

    test "handles packets with very big gaps" do
      store = %PacketStore{}
      first_packet = PacketFactory.sample_packet(20_072)
      assert {:ok, store} = PacketStore.insert(store, first_packet)

      second_packet = PacketFactory.sample_packet(52_840)
      assert {:ok, store} = PacketStore.insert(store, second_packet)

      third_packet = PacketFactory.sample_packet(52_841)
      assert {:ok, _store} = PacketStore.insert(store, third_packet)
    end

    test "handles late packets when starting with sequence_number 0" do
      store = %PacketStore{}
      packet = PacketFactory.sample_packet(0)
      assert {:ok, store} = PacketStore.insert(store, packet)

      packet = PacketFactory.sample_packet(1)
      assert {:ok, store} = PacketStore.insert(store, packet)

      packet = PacketFactory.sample_packet(@seq_number_limit - 1)
      assert {:error, :late_packet} = PacketStore.insert(store, packet)
    end

    test "handles rollover before any packet was sent" do
      store = %PacketStore{}
      packet = PacketFactory.sample_packet(@seq_number_limit - 1)
      assert {:ok, store} = PacketStore.insert(store, packet)

      packet = PacketFactory.sample_packet(0)
      assert {:ok, store} = PacketStore.insert(store, packet)

      packet = PacketFactory.sample_packet(1)
      assert {:ok, _store} = PacketStore.insert(store, packet)

      # seq_numbers =
      #   store
      #   |> PacketStore.dump()
      #   |> Enum.map(& &1.packet.sequence_number)

      # assert seq_numbers == [65_535, 0, 1]

      # indexes =
      #   store
      #   |> PacketStore.dump()
      #   |> Enum.map(& &1.index)

      # assert indexes == [@seq_number_limit - 1, @seq_number_limit, @seq_number_limit + 1]
    end

    test "handles late packet after rollover" do
      store = %PacketStore{}
      first_packet = PacketFactory.sample_packet(@seq_number_limit - 1)
      assert {:ok, store} = PacketStore.insert(store, first_packet)

      second_packet = PacketFactory.sample_packet(0)
      assert {:ok, store} = PacketStore.insert(store, second_packet)

      packet = PacketFactory.sample_packet(1)
      assert {:ok, store} = PacketStore.insert(store, packet)

      assert {%Entry{packet: ^first_packet}, store} = PacketStore.flush_one(store)
      assert {%Entry{packet: ^second_packet}, store} = PacketStore.flush_one(store)

      packet = PacketFactory.sample_packet(@seq_number_limit - 2)
      assert {:error, :late_packet} = PacketStore.insert(store, packet)

      # seq_numbers =
      #   store
      #   |> PacketStore.dump()
      #   |> Enum.map(& &1.packet.sequence_number)

      # assert seq_numbers == [1]
    end
  end

  describe "When getting a packet from PacketStore it" do
    setup %{base_store: base_store} do
      packet = PacketFactory.sample_packet(@next_index)
      {:ok, store} = PacketStore.insert(base_store, packet)

      [
        store: store,
        packet: packet
      ]
    end

    test "returns the root packet and initializes it", %{store: store, packet: packet} do
      assert {%Entry{} = record, empty_store} = PacketStore.flush_one(store)
      assert record.packet == packet
      assert Heap.size(empty_store.heap) == 0
      assert empty_store.flush_index == record.index
    end

    test "returns nil when store is empty and bumps flush_index", %{base_store: store} do
      assert {nil, new_store} = PacketStore.flush_one(store)
      assert new_store.flush_index == store.flush_index + 1
    end

    test "returns nil when heap is not empty, but the next packet is not present", %{
      store: store
    } do
      broken_store = %PacketStore{store | flush_index: @base_index - 1}
      assert {nil, new_store} = PacketStore.flush_one(broken_store)
      assert new_store.flush_index == @base_index
    end

    test "sorts packets by index number", %{base_store: store} do
      test_base = 1..100

      test_base
      |> Enum.into([])
      |> Enum.shuffle()
      |> enum_into_store(store)
      |> (fn store -> store.heap end).()
      |> Enum.zip(test_base)
      |> Enum.each(fn {record, base_element} ->
        assert %Entry{index: index} = record
        assert rem(index, 65_536) == base_element
      end)
    end

    test "handles rollover", %{base_store: base_store} do
      store = %PacketStore{base_store | flush_index: 65_533}
      before_rollover_seq_nums = 65_534..65_535
      after_rollover_seq_nums = 0..10

      combined = Enum.into(before_rollover_seq_nums, []) ++ Enum.into(after_rollover_seq_nums, [])
      combined_store = enum_into_store(combined, store)

      store =
        Enum.reduce(combined, combined_store, fn elem, store ->
          {record, store} = PacketStore.flush_one(store)
          assert %Entry{packet: packet} = record
          assert %ExRTP.Packet{sequence_number: seq_number} = packet
          assert seq_number == elem
          store
        end)

      assert store.rollover_count == 1
    end

    test "handles empty rollover", %{base_store: base_store} do
      store = %PacketStore{base_store | flush_index: 65_533}
      base_data = Enum.into(65_534..65_535, [])
      store = enum_into_store(base_data, store)

      Enum.reduce(base_data, store, fn elem, store ->
        {record, store} = PacketStore.flush_one(store)
        assert %Entry{index: ^elem} = record
        store
      end)
    end

    test "handles later rollovers" do
      m = @seq_number_limit

      flush_index = 3 * m - 6

      store = %PacketStore{
        flush_index: flush_index,
        highest_incoming_index: flush_index,
        rollover_count: 2
      }

      store =
        (Enum.into((m - 5)..(m - 1), []) ++ Enum.into(0..4, []))
        |> enum_into_store(store)

      store_content = PacketStore.dump(store)
      assert length(store_content) == 10
    end

    test "handles late packets after a rollover" do
      indexes = [65_535, 0, 65_534]

      store =
        enum_into_store(indexes, %PacketStore{flush_index: 65_533, highest_incoming_index: 65_533})

      Enum.each(indexes, fn _index ->
        assert {%Entry{}, _store} = PacketStore.flush_one(store)
      end)
    end
  end

  describe "When dumping it" do
    test "returns list that contains packets from heap" do
      store = enum_into_store(1..10)
      result = PacketStore.dump(store)
      assert is_list(result)
      assert Enum.count(result) == 10
    end

    test "returns empty list if no records are inside" do
      assert PacketStore.dump(%PacketStore{}) == []
    end
  end

  defp new_testing_store(index) do
    %PacketStore{
      flush_index: index,
      highest_incoming_index: index,
      heap: Heap.new(&Entry.comparator/2)
    }
  end

  defp enum_into_store(enumerable, store \\ %PacketStore{}) do
    Enum.reduce(enumerable, store, fn elem, acc ->
      packet = PacketFactory.sample_packet(elem)
      {:ok, store} = PacketStore.insert(acc, packet)
      store
    end)
  end

  defp has_packet(%PacketStore{heap: heap}, %ExRTP.Packet{sequence_number: seq_num}) do
    assert is_integer(seq_num)

    heap
    |> Enum.to_list()
    |> Enum.map(& &1.packet.sequence_number)
    |> Enum.member?(seq_num)
  end
end
