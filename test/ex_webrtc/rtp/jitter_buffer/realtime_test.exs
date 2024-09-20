defmodule ExWebRTC.RTP.JitterBuffer.RealtimeTest do
  use ExUnit.Case

  alias ExWebRTC.RTP.{JitterBuffer, PacketFactory}
  alias ExRTP.Packet

  @seq_number_limit 65_536

  defmodule PacketSource do
    @moduledoc false
    use GenServer

    @seq_number_limit 65_536

    @impl true
    def init(state) do
      {:ok, state, {:continue, :after_init}}
    end

    @impl true
    def handle_continue(
          :after_init,
          %{
            packet_delay_ms: delay_ms,
            packet_num: packet_num,
            max_latency: max_latency
          } = state
        ) do
      now = System.monotonic_time(:millisecond)

      1..packet_num
      |> Enum.each(fn n ->
        time =
          cond do
            # Delay less than max latency
            rem(n, 15) == 0 -> n * delay_ms + div(max_latency, 2)
            # Delay more than max latency
            rem(n, 19) == 0 -> n * delay_ms + max_latency * 2
            true -> n * delay_ms
          end

        if rem(n, 50) < 30 or rem(n, 50) > 32 do
          seq_number = rem(n, @seq_number_limit)
          Process.send_after(self(), {:push_packet, seq_number}, now + time, abs: true)
        end
      end)

      {:noreply, state}
    end

    @impl true
    def handle_info({:push_packet, n}, %{buffer: buffer} = state) do
      buffer
      |> JitterBuffer.insert(PacketFactory.sample_packet(n))
      |> handle_jitter_buffer_result(state)
    end

    @impl true
    def handle_info(:jitter_buffer_timer, %{buffer: buffer} = state) do
      buffer
      |> JitterBuffer.handle_timeout()
      |> handle_jitter_buffer_result(state)
    end

    defp handle_jitter_buffer_result({packets, timer, buffer}, state) do
      for packet <- packets do
        send(state.owner, packet)
      end

      unless is_nil(timer), do: Process.send_after(self(), :jitter_buffer_timer, timer)

      {:noreply, %{state | buffer: buffer}}
    end
  end

  test "Jitter Buffer works in a pipeline with small latency" do
    test_pipeline(300, 10, 200)
  end

  test "Jitter Buffer works in a pipeline with large latency" do
    test_pipeline(100, 30, 1000)
  end

  @tag :long_running
  @tag timeout: 70_000 * 10 + 20_000
  test "Jitter Buffer works in a long-running pipeline with small latency" do
    test_pipeline(70_000, 10, 100)
  end

  defp test_pipeline(packets, packet_delay_ms, latency_ms) do
    {:ok, _pid} =
      GenServer.start_link(PacketSource, %{
        owner: self(),
        buffer: JitterBuffer.new(latency: latency_ms),
        packet_num: packets,
        packet_delay_ms: packet_delay_ms,
        max_latency: latency_ms
      })

    timeout = latency_ms + packet_delay_ms + 200

    Enum.each(1..packets, fn n ->
      seq_num = rem(n, @seq_number_limit)

      cond do
        rem(n, 50) >= 30 and rem(n, 50) <= 32 ->
          refute_receive %Packet{sequence_number: ^seq_num}, timeout

        rem(n, 19) == 0 and rem(n, 15) != 0 ->
          refute_receive %Packet{sequence_number: ^seq_num}, timeout

        true ->
          assert_receive %Packet{sequence_number: ^seq_num}, timeout
      end
    end)
  end
end
