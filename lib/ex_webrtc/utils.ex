defmodule ExWebRTC.Utils do
  @moduledoc false
  alias ExWebRTC.RTPCodecParameters

  @spec hex_dump(binary()) :: String.t()
  def hex_dump(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &Base.encode16(<<&1>>))
  end

  @spec generate_id() :: integer()
  def generate_id() do
    <<id::12*8>> = :crypto.strong_rand_bytes(12)
    id
  end

  @spec to_int(boolean()) :: 0 | 1
  def to_int(false), do: 0
  def to_int(true), do: 1

  @doc false
  @spec compact_ntp(non_neg_integer()) :: non_neg_integer()
  def compact_ntp(ntp_timestamp) do
    # the middle 32 bits of a 64-bit NTP timestamp: the low 16 bits of the
    # integer part and the high 16 bits of the fractional part (RFC 3550, sec. 4)
    import Bitwise
    ntp_timestamp >>> 16 &&& 0xFFFFFFFF
  end

  @spec split_rtx_codecs([RTPCodecParameters.t()]) ::
          {[RTPCodecParameters.t()], [RTPCodecParameters.t()]}
  def split_rtx_codecs(codecs) do
    Enum.split_with(codecs, &String.ends_with?(&1.mime_type, "/rtx"))
  end

  @spec chunk(binary(), pos_integer(), [binary()]) :: [binary()]
  def chunk(data, size, acc \\ [])
  def chunk(<<>>, _size, acc), do: Enum.reverse(acc)

  def chunk(data, size, acc) when size > 0 do
    case data do
      <<data::binary-size(^size), rest::binary>> ->
        chunk(rest, size, [data | acc])

      _other ->
        chunk(<<>>, size, [data | acc])
    end
  end
end
