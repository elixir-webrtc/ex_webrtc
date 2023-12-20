defmodule ExWebRTC.Media.OggReader do
  @moduledoc """
  Defines Ogg reader.

  For now, works only with single Opus stream in the container.

  Based on:
  * [Xiph's official Ogg documentation](https://xiph.org/ogg/)
  * [RFC 7845: Ogg Encapsulation for the Opus Audio Codec](https://www.rfc-editor.org/rfc/rfc7845.txt)
  * [RFC 6716: Definition of the Opus Audio Codec](https://www.rfc-editor.org/rfc/rfc6716.txt)
  """

  import Bitwise

  @signature "OggS"
  @id_signature "OpusHead"
  @comment_signature "OpusTags"
  @version 0

  @opaque t() :: %{
            file: File.io_device(),
            packets: [binary()],
            rest: binary()
          }

  @doc """
  Opens Ogg file.

  For now, works only with single Opus stream in the container.
  This function reads the ID and Comment Headers (and, for now, ignores them).
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, File.posix() | :invalid_header}
  def open(path) do
    with {:ok, file} <- File.open(path),
         reader <- %{file: file, packets: [], rest: <<>>},
         # for now, we ignore ID Header and Comment Header
         {:ok, reader, <<@id_signature, _rest::binary>>} <- do_next_packet(reader),
         {:ok, reader, <<@comment_signature, _rest::binary>>} <- do_next_packet(reader) do
      {:ok, reader}
    else
      {:error, _res} = err -> err
      _other -> {:error, :invalid_header}
    end
  end

  @doc """
  Reads next Ogg packet.

  One Ogg packet is equivalent to one Opus packet.
  This function also returns the duration of the audio in milliseconds, based on Opus packet TOC sequence.
  It assumes that all of the Ogg packets belong to the same stream.
  """
  @spec next_packet(t()) ::
          {:ok, t(), {binary(), non_neg_integer()}}
          | {:error, :invalid_page_header | :not_enough_data}
          | :eof
  def next_packet(reader) do
    with {:ok, reader, packet} <- do_next_packet(reader),
         {:ok, duration} <- get_packet_duration(packet) do
      {:ok, reader, {packet, duration}}
    end
  end

  defp do_next_packet(%{packets: [first | packets]} = reader) do
    {:ok, %{reader | packets: packets}, first}
  end

  defp do_next_packet(%{packets: []} = reader) do
    with {:ok, _header, packets, rest} <- read_page(reader.file) do
      case packets do
        [] ->
          do_next_packet(%{reader | packets: [], rest: reader.rest <> rest})

        [first | packets] ->
          packet = rest <> first
          reader = %{reader | packets: packets, rest: rest}
          {:ok, reader, packet}
      end
    end
  end

  defp read_page(file) do
    with <<@signature, @version, type, granule_pos::little-64, serial_no::little-32,
           sequence_no::little-32, _checksum::little-32, segment_no>> <- IO.binread(file, 27),
         segment_table when is_binary(segment_table) <- IO.binread(file, segment_no),
         segment_table <- :binary.bin_to_list(segment_table),
         payload_length <- Enum.sum(segment_table),
         payload when is_binary(payload) <- IO.binread(file, payload_length) do
      # TODO: checksum
      {packets, rest} = split_packets(segment_table, payload)

      type = %{
        fresh?: (type &&& 0x01) != 0,
        first?: (type &&& 0x02) != 0,
        last?: (type &&& 0x04) != 0
      }

      {:ok,
       %{
         type: type,
         granule_pos: granule_pos,
         serial_no: serial_no,
         sequence_no: sequence_no
       }, packets, rest}
    else
      data when is_binary(data) -> {:error, :invalid_page_header}
      :eof -> :eof
      {:error, _res} = err -> err
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

  # computes how much audio Opus packet contains (in ms), based on the TOC sequence
  # RFC 6716, sec. 3
  defp get_packet_duration(<<config::5, rest::bitstring>>) do
    with {:ok, frame_count} <- get_frame_count(rest) do
      {:ok, trunc(frame_count * get_frame_duration(config))}
    end
  end

  defp get_packet_duration(_other), do: {:error, :not_enough_data}

  defp get_frame_count(<<_s::1, 0::2, _rest::binary>>), do: {:ok, 1}
  defp get_frame_count(<<_s::1, c::2, _rest::binary>>) when c in 1..2, do: {:ok, 2}
  defp get_frame_count(<<_s::1, 3::2, _vp::2, frame_no::5, _rest::binary>>), do: {:ok, frame_no}
  defp get_frame_count(_other), do: {:error, :not_enough_data}

  defp get_frame_duration(config) when config in [16, 20, 24, 28], do: 2.5
  defp get_frame_duration(config) when config in [17, 21, 25, 29], do: 5
  defp get_frame_duration(config) when config in [0, 4, 8, 12, 14, 18, 22, 26, 30], do: 10
  defp get_frame_duration(config) when config in [1, 5, 9, 13, 15, 19, 23, 27, 31], do: 20
  defp get_frame_duration(config) when config in [2, 6, 10], do: 40
  defp get_frame_duration(config) when config in [3, 7, 11], do: 60
end
