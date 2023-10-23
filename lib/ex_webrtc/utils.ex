defmodule ExWebRTC.Utils do
  @moduledoc false

  @spec hex_dump(binary()) :: String.t()
  def hex_dump(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &Base.encode16(<<&1>>))
  end

  def get_media_direction(media) do
    Enum.find(media.attributes, fn attr ->
      attr in [:sendrecv, :sendonly, :recvonly, :inactive]
    end)
  end
end
