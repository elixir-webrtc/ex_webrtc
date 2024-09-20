defmodule ExWebRTC.RTP.JitterBuffer.Heap do
  @moduledoc false
  # Implementation of a heap (min-heap by default)
  #
  # At the moment, this module uses a regular `Map` (with O(log n) access) to store the data.
  #
  # TODO: Run performance tests and determine if it would be better to use:
  #   - ETS
  #   - :array
  #   - some other data structure?

  @type comparator :: (term(), term() -> boolean())

  @opaque t :: %__MODULE__{
            comparator: comparator(),
            tree: %{non_neg_integer() => term()}
          }

  defstruct [:comparator, :tree]

  defimpl Enumerable do
    alias ExWebRTC.RTP.JitterBuffer.Heap

    def count(heap), do: {:ok, map_size(heap.tree)}
    def member?(heap, elem), do: {:ok, heap.tree |> Map.values() |> Enum.member?(elem)}

    def reduce(_heap, {:halt, acc}, _fun), do: {:halted, acc}
    def reduce(heap, {:suspend, acc}, fun), do: {:suspended, acc, &reduce(heap, &1, fun)}
    def reduce(heap, {:cont, acc}, _fun) when map_size(heap.tree) == 0, do: {:done, acc}

    def reduce(heap, {:cont, acc}, fun) do
      elem = Heap.root(heap)

      heap |> Heap.pop() |> reduce(fun.(elem, acc), fun)
    end

    def slice(_heap), do: {:error, __MODULE__}
  end

  @spec new(comparator()) :: t()
  def new(comparator \\ &</2) do
    %__MODULE__{
      comparator: comparator,
      tree: %{}
    }
  end

  @spec root(t()) :: term()
  def root(heap) do
    heap.tree[0]
  end

  @spec size(t()) :: non_neg_integer()
  def size(heap) do
    map_size(heap.tree)
  end

  @spec push(t(), term()) :: t()
  def push(heap, elem) do
    idx = map_size(heap.tree)
    tree = Map.put(heap.tree, idx, elem)

    restore_heap(%{heap | tree: tree}, idx)
  end

  @spec pop(t()) :: t()
  def pop(heap)

  def pop(heap) when map_size(heap.tree) < 2, do: %{heap | tree: %{}}

  def pop(heap) do
    last_idx = map_size(heap.tree) - 1
    %{0 => _first, ^last_idx => last} = heap.tree

    tree =
      heap.tree
      |> Map.delete(last_idx)
      |> Map.put(0, last)

    heapify(%{heap | tree: tree}, 0)
  end

  defp restore_heap(heap, 0), do: heap

  defp restore_heap(heap, idx) do
    p = parent(idx)

    heap
    |> heapify(p)
    |> restore_heap(p)
  end

  defp heapify(heap, i) do
    n = map_size(heap.tree)

    max_idx =
      [i, left(i), right(i)]
      |> Stream.filter(&(&1 < n))
      |> Enum.max_by(&heap.tree[&1], heap.comparator, fn -> nil end)

    if max_idx != i do
      %{^i => t1, ^max_idx => t2} = heap.tree

      tree =
        heap.tree
        |> Map.put(i, t2)
        |> Map.put(max_idx, t1)

      heapify(%{heap | tree: tree}, max_idx)
    else
      heap
    end
  end

  defp left(i), do: 2 * i + 1
  defp right(i), do: 2 * i + 2
  defp parent(i), do: div(i - 1, 2)
end
