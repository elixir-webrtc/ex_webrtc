defmodule ExWebRTC.RTP.JitterBuffer.HeapTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.JitterBuffer.Heap

  test "stores things and reports size" do
    heap = Heap.new()
    assert Heap.size(heap) == 0
    assert Heap.root(heap) == nil

    heap = Heap.push(heap, 123)
    assert Heap.size(heap) == 1
    assert Heap.root(heap) == 123

    heap = Heap.push(heap, 0)
    assert Heap.size(heap) == 2
    assert Heap.root(heap) == 0

    heap = Heap.pop(heap)
    heap = Heap.pop(heap)
    assert Heap.size(heap) == 0
    assert Heap.root(heap) == nil

    # popping on empty heap shouldn't raise
    _heap = Heap.pop(heap)
  end

  test "sorts integers" do
    test_base = 1..100
    heap = shuffle_into_heap(test_base, Heap.new())

    Enum.reduce(test_base, heap, fn num, heap ->
      assert Heap.root(heap) == num
      Heap.pop(heap)
    end)
  end

  test "sorts using comparator" do
    test_base = 1..100//-1
    heap = shuffle_into_heap(test_base, Heap.new(&>/2))

    Enum.reduce(test_base, heap, fn num, heap ->
      assert Heap.root(heap) == num
      Heap.pop(heap)
    end)
  end

  test "implements Enumerable" do
    heap = Heap.new()

    assert Enum.member?(heap, 123) == false
    heap = Heap.push(heap, 123)
    assert Enum.member?(heap, 123) == true

    assert Enum.count(heap) == 1

    test_base = 1..100

    heap = shuffle_into_heap(test_base, Heap.new())

    test_base
    |> Enum.zip(heap)
    |> Enum.each(fn {num, elem} ->
      assert num == elem
    end)
  end

  defp shuffle_into_heap(range, heap) do
    range
    |> Enum.into([])
    |> Enum.shuffle()
    |> Enum.reduce(heap, fn elem, heap -> Heap.push(heap, elem) end)
  end
end
