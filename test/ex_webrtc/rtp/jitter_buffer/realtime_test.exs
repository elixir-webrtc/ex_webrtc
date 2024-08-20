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
      :ok = JitterBuffer.start_timer(state.buffer)
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
      :ok = JitterBuffer.place_packet(buffer, PacketFactory.sample_packet(n))
      {:noreply, state}
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
    {:ok, buffer} = JitterBuffer.start_link(latency: latency_ms)

    {:ok, _pid} =
      GenServer.start_link(PacketSource, %{
        buffer: buffer,
        packet_num: packets,
        packet_delay_ms: packet_delay_ms,
        max_latency: latency_ms
      })

    timeout = latency_ms + packet_delay_ms + 200

    Enum.each(1..packets, fn n ->
      seq_num = rem(n, @seq_number_limit)

      cond do
        rem(n, 50) >= 30 and rem(n, 50) <= 32 ->
          refute_receive {:jitter_buffer, _pid, {:packet, %Packet{sequence_number: ^seq_num}}},
                         timeout

        rem(n, 19) == 0 and rem(n, 15) != 0 ->
          refute_receive {:jitter_buffer, _pid, {:packet, %Packet{sequence_number: ^seq_num}}},
                         timeout

        true ->
          assert_receive {:jitter_buffer, _pid, {:packet, %Packet{sequence_number: ^seq_num}}},
                         timeout
      end
    end)
  end
end
