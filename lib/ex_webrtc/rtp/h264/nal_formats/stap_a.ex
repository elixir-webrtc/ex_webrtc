defmodule ExWebRTC.RTP.H264.StapA do
  @moduledoc false
  # Module responsible for parsing Single Time Agregation Packets type A.
  #
  # Documented in [RFC6184](https://tools.ietf.org/html/rfc6184#page-22)
  #
  #    0                   1                   2                   3
  #    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |                          RTP Header                           |
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |STAP-A NAL HDR |         NALU 1 Size           | NALU 1 HDR    |
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |                         NALU 1 Data                           |
  #   :                                                               :
  #   +               +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |               | NALU 2 Size                   | NALU 2 HDR    |
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |                         NALU 2 Data                           |
  #   :                                                               :
  #   |                               +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |                               :...OPTIONAL RTP padding        |
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

  @spec parse(binary()) :: {:ok, [binary()]} | {:error, :packet_malformed}
  def parse(data) do
    do_parse(data, [])
  end

  defp do_parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse(<<size::16, nalu::binary-size(size), rest::binary>>, acc),
    do: do_parse(rest, [nalu | acc])

  defp do_parse(_data, _acc), do: {:error, :packet_malformed}
end
