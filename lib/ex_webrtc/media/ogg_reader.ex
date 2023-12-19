defmodule ExWebRTC.Media.OggReader do
  @moduledoc """
  Defines Ogg reader.

  Based on:
  * [Xiph's official Ogg documentation](https://xiph.org/ogg/)
  * [RFC 7845: Ogg Encapsulation for the Opus Audio Codec](https://www.rfc-editor.org/rfc/rfc7845.txt)
  """

  import Bitwise

  @signature "OggS"
  @version 0

  @typep header_type() :: %{
          fresh?: boolean(),
          first?: boolean(),
          last?: boolean()
        }

  @typep page_header() :: %{
    type: header_type(),
    granule_pos: non_neg_integer(),
    serial_no: non_neg_integer(),
    sequence_no: non_neg_integer()
  }

  @opaque t() :: %{
    file: File.io_device(),
    page_header: page_header() | nil,
    packets: [binary()],
    rest: binary(),
  }

  @spec open(Path.t()) :: {:ok, t()} | {:error, File.posix()}
  def open(path) do
    case File.open(path) do
      {:ok, file} -> {:ok, %{file: file, page_header: nil, packets: [], rest: <<>>}}
      {:error, _res} = err -> err
    end
  end

  def next_packet(%{packets: [first | packets]} = reader) do
    reader = %{reader | packets: packets}
    {:ok, reader, first}
  end

  def next_packet(%{packets: []} = reader) do
    with {:ok, header, packets, rest} <- read_page(reader.file) do
      prev_rest = reader.rest
      reader = %{reader | page_header: header}
      case packets do
        [] -> next_packet(%{reader | packets: [], rest: prev_rest <> rest})
        [first | packets] -> {:ok, %{reader | packets: packets, rest: rest}, first}
      end

    end
  end

  defp read_page(file) do
    with <<@signature, @version, type, granule_pos::little-64, serial_no::little-32, sequence_no::little-32,
           _checksum::little-32, segment_no>> <- IO.binread(file, 27),
         segment_table when is_binary(segment_table) <- IO.binread(file, segment_no),
         segment_table <- :binary.bin_to_list(segment_table),
         payload_length <- Enum.sum(segment_table),
         payload when is_binary(payload) <- IO.binread(file, payload_length) do
      # TODO: checksum
      {packets, rest} = split_packets(segment_table, payload)
      type = %{
        fresh?: (type &&& 0x01) != 0,
        first?: (type &&& 0x02) != 0,
        last?: (type &&& 0x04) != 0,
      }

      {:ok,
       %{
         type: type,
         granule_pos: granule_pos,
         serial_no: serial_no,
         sequence_no: sequence_no,
       }, packets, rest}
    else
      _ -> :error
    end
  end

  defp split_packets(segment_table, payload, packets \\ [], packet \\ <<>>)
  defp split_packets([], <<>>, packets, packet), do: {Enum.reverse(packets), packet}
  defp split_packets([segment_len | segment_table], payload, packets, packet) do
    <<segment::binary-size(segment_len), rest::binary>> = payload
    packet = packet <> segment
    case segment_len do
      255 -> split_packets(segment_table, rest, packets, packet)
      _len -> split_packets(segment_table, rest, [packet | packets], <<>>)
    end
  end
end
