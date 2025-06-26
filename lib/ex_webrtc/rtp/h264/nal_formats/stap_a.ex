defmodule ExWebRTC.RTP.H264.StapA do
  @moduledoc """
  Module responsible for parsing Single Time Agregation Packets type A.

  Documented in [RFC6184](https://tools.ietf.org/html/rfc6184#page-22)

  ```
     0                   1                   2                   3
     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                          RTP Header                           |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |STAP-A NAL HDR |         NALU 1 Size           | NALU 1 HDR    |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                         NALU 1 Data                           |
    :                                                               :
    +               +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |               | NALU 2 Size                   | NALU 2 HDR    |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                         NALU 2 Data                           |
    :                                                               :
    |                               +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                               :...OPTIONAL RTP padding        |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  ```
  """
  use Bunch

  alias ExWebRTC.RTP.H264.NAL

  @spec parse(binary()) :: {:ok, [binary()]} | {:error, :packet_malformed}
  def parse(data) do
    do_parse(data, [])
  end

  defp do_parse(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_parse(<<size::16, nalu::binary-size(size), rest::binary>>, acc),
    do: do_parse(rest, [nalu | acc])

  defp do_parse(_data, _acc), do: {:error, :packet_malformed}

  @spec aggregation_unit_size(binary()) :: pos_integer()
  def aggregation_unit_size(nalu), do: byte_size(nalu) + 2

  @spec serialize([binary], 0..1, 0..3) :: binary
  def serialize(payloads, f, nri) do
    payloads
    |> Enum.reverse()
    |> Enum.map(&<<byte_size(&1)::16, &1::binary>>)
    |> IO.iodata_to_binary()
    |> NAL.Header.add_header(f, nri, NAL.Header.encode_type(:stap_a))
  end
end
