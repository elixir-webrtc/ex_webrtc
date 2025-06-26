defmodule ExWebRTC.RTP.H264.FU do
  @moduledoc """
  Module responsible for parsing H264 Fragmentation Unit.
  """
  use Bunch
  alias __MODULE__
  alias Membrane.RTP.H264.NAL

  defstruct data: []

  @type t :: %__MODULE__{data: [binary()]}

  @doc """
  Parses H264 Fragmentation Unit

  If a packet that is being parsed is not considered last then a `{:incomplete, t()}`
  tuple  will be returned.
  In case of last packet `{:ok, {type, data}}` tuple will be returned, where data
  is `NAL Unit` created by concatenating subsequent Fragmentation Units.
  """
  @spec parse(binary(), t) ::
          {:ok, {binary(), NAL.Header.type()}}
          | {:error, :packet_malformed | :invalid_first_packet}
          | {:incomplete, t()}
  def parse(packet, acc) do
    with {:ok, {header, value}} <- FU.Header.parse(packet) do
      do_parse(header, value, acc)
    end
  end

  @doc """
  Serialize H264 unit into list of FU-A payloads
  """
  @spec serialize(binary(), pos_integer()) :: list(binary()) | {:error, :unit_too_small}
  def serialize(data, preferred_size) do
    case data do
      <<header::1-binary, head::binary-size(preferred_size - 1), rest::binary>> ->
        <<r::1, nri::2, type::5>> = header

        payload =
          head
          |> FU.Header.add_header(1, 0, type)
          |> NAL.Header.add_header(r, nri, NAL.Header.encode_type(:fu_a))

        [payload | do_serialize(rest, r, nri, type, preferred_size)]

      _data ->
        {:error, :unit_too_small}
    end
  end

  defp do_serialize(data, r, nri, type, preferred_size) do
    case data do
      <<head::binary-size(preferred_size - 2), rest::binary>> when byte_size(rest) > 0 ->
        payload =
          head
          |> FU.Header.add_header(0, 0, type)
          |> NAL.Header.add_header(r, nri, NAL.Header.encode_type(:fu_a))

        [payload] ++ do_serialize(rest, r, nri, type, preferred_size)

      rest ->
        [
          rest
          |> FU.Header.add_header(0, 1, type)
          |> NAL.Header.add_header(r, nri, NAL.Header.encode_type(:fu_a))
        ]
    end
  end

  defp do_parse(header, packet, acc)

  defp do_parse(%FU.Header{start_bit: true}, packet, acc),
    do: {:incomplete, %__MODULE__{acc | data: [packet]}}

  defp do_parse(%FU.Header{start_bit: false}, _data, %__MODULE__{data: []}),
    do: {:error, :invalid_first_packet}

  defp do_parse(%FU.Header{end_bit: true, type: type}, packet, %__MODULE__{data: acc_data}) do
    result =
      [packet | acc_data]
      |> Enum.reverse()
      |> Enum.join()

    {:ok, {result, type}}
  end

  defp do_parse(_header, packet, %__MODULE__{data: acc_data} = fu),
    do: {:incomplete, %__MODULE__{fu | data: [packet | acc_data]}}
end
