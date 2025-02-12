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

  @spec split_rtx_codecs([RTPCodecParameters.t()]) ::
          {[RTPCodecParameters.t()], [RTPCodecParameters.t()]}
  def split_rtx_codecs(codecs) do
    Enum.split_with(codecs, &String.ends_with?(&1.mime_type, "/rtx"))
  end
end
