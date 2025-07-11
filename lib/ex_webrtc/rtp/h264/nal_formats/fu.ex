defmodule ExWebRTC.RTP.H264.FU do
  @moduledoc """
  Module responsible for parsing H264 Fragmentation Unit.
  """
  alias __MODULE__
  alias ExWebRTC.RTP.H264.NAL

  @doc """
  Parses H264 Fragmentation Unit

  If a packet that is being parsed is not considered last then a `{:incomplete, t()}`
  tuple  will be returned.
  In case of last packet `{:ok, {type, data}}` tuple will be returned, where data
  is `NAL Unit` created by concatenating subsequent Fragmentation Units.
  """
  @spec parse(binary(), [binary()]) ::
          {:ok, {binary(), NAL.Header.type()}}
          | {:error, :packet_malformed | :invalid_first_packet}
          | {:incomplete, [binary()]}
  def parse(packet, acc) do
    with {:ok, {header, value}} <- FU.Header.parse(packet) do
      do_parse(header, value, acc)
    end
  end

  defp do_parse(header, packet, acc)

  defp do_parse(%FU.Header{start_bit: true}, data, []),
    do: {:incomplete, [data]}

  defp do_parse(%FU.Header{start_bit: true}, _data, _acc),
    do: {:error, :last_fu_not_finished}

  defp do_parse(%FU.Header{start_bit: false}, _data, []),
    do: {:error, :invalid_first_packet}

  defp do_parse(%FU.Header{end_bit: true, type: type}, data, acc_data) do
    result =
      [data | acc_data]
      |> Enum.reverse()
      |> Enum.join()

    {:ok, {result, type}}
  end

  defp do_parse(_header, data, acc_data),
    do: {:incomplete, [data | acc_data]}
end
