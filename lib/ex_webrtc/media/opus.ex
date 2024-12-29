defmodule ExWebRTC.Media.Opus do
  @moduledoc false
  # based on RFC 6716, sec. 3

  @doc """
  Computes how much audio is contained in the Opus packet, based on the TOC sequence.

  Returns the duration in milliseconds.
  """
  @spec duration(binary()) :: {:ok, number()} | {:error, term()}
  def duration(<<config::5, rest::bitstring>>) do
    with {:ok, frame_count} <- get_frame_count(rest) do
      {:ok, frame_count * get_frame_duration(config)}
    end
  end

  def duration(_other), do: {:error, :invalid_packet}

  defp get_frame_count(<<_s::1, 0::2, _rest::binary>>), do: {:ok, 1}
  defp get_frame_count(<<_s::1, c::2, _rest::binary>>) when c in 1..2, do: {:ok, 2}
  defp get_frame_count(<<_s::1, 3::2, _vp::2, frame_no::5, _rest::binary>>), do: {:ok, frame_no}
  defp get_frame_count(_other), do: {:error, :invalid_packet}

  defp get_frame_duration(config) when config in [16, 20, 24, 28], do: 2.5
  defp get_frame_duration(config) when config in [17, 21, 25, 29], do: 5
  defp get_frame_duration(config) when config in [0, 4, 8, 12, 14, 18, 22, 26, 30], do: 10
  defp get_frame_duration(config) when config in [1, 5, 9, 13, 15, 19, 23, 27, 31], do: 20
  defp get_frame_duration(config) when config in [2, 6, 10], do: 40
  defp get_frame_duration(config) when config in [3, 7, 11], do: 60
end
