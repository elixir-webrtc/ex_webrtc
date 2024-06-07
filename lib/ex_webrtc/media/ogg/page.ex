defmodule ExWebRTC.Media.Ogg.Page do
  @moduledoc false
  # see RFC 3553, sec. 6 for description of the Ogg Page

  import Bitwise

  @crc_params %{
    extend: :crc_32,
    poly: 0x04C11DB7,
    init: 0x0,
    xorout: 0x0,
    refin: false,
    refout: false
  }

  @signature "OggS"
  @version 0

  @type t() :: %__MODULE__{
          continued?: boolean(),
          first?: boolean(),
          last?: boolean(),
          granule_pos: non_neg_integer(),
          serial_no: non_neg_integer(),
          sequence_no: non_neg_integer(),
          packets: [binary()],
          rest: binary()
        }

  @enforce_keys [:granule_pos, :serial_no, :sequence_no]
  defstruct @enforce_keys ++
              [
                continued?: false,
                first?: false,
                last?: false,
                packets: [],
                rest: <<>>
              ]

  @spec read(File.io_device()) :: {:ok, t()} | {:error, term()}
  def read(file) do
    with <<@signature, @version, type, granule_pos::little-64, serial_no::little-32,
           sequence_no::little-32, _checksum::little-32,
           segment_no>> = header <- IO.binread(file, 27),
         raw_segment_table when is_binary(raw_segment_table) <- IO.binread(file, segment_no),
         segment_table <- :binary.bin_to_list(raw_segment_table),
         payload_length <- Enum.sum(segment_table),
         payload when is_binary(payload) <- IO.binread(file, payload_length),
         :ok <- verify_checksum(header <> raw_segment_table <> payload) do
      {packets, rest} = split_packets(segment_table, payload)

      page = %__MODULE__{
        continued?: (type &&& 0x01) != 0,
        first?: (type &&& 0x02) != 0,
        last?: (type &&& 0x04) != 0,
        granule_pos: granule_pos,
        serial_no: serial_no,
        sequence_no: sequence_no,
        packets: packets,
        rest: rest
      }

      {:ok, page}
    else
      data when is_binary(data) -> {:error, :invalid_page_header}
      :eof -> :eof
      {:error, _res} = err -> err
    end
  end

  @spec write(File.io_device(), t()) :: :ok | {:error, term()}
  def write(file, %__MODULE__{} = page) do
    with {:ok, segment_table} <- create_segment_table(page.packets, page.rest) do
      continued = if page.continued?, do: 0x01, else: 0
      first = if page.first?, do: 0x02, else: 0
      last = if page.last?, do: 0x04, else: 0
      type = first ||| continued ||| last

      before_crc = <<
        @signature,
        @version,
        type,
        page.granule_pos::little-64,
        page.serial_no::little-32,
        page.sequence_no::little-32
      >>

      after_crc =
        <<length(segment_table)>> <>
          :binary.list_to_bin(segment_table) <>
          :binary.list_to_bin(page.packets) <>
          page.rest

      checksum = CRC.calculate(<<before_crc::binary, 0::32, after_crc::binary>>, @crc_params)
      packet = <<before_crc::binary, checksum::little-32, after_crc::binary>>

      IO.binwrite(file, packet)
    end
  end

  defp verify_checksum(<<start::binary-22, checksum::little-32, rest::binary>>) do
    actual_checksum =
      <<start::binary, 0::32, rest::binary>>
      |> CRC.calculate(@crc_params)

    if checksum == actual_checksum do
      :ok
    else
      {:error, :invalid_checksum}
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

  defp create_segment_table(packets, rest) when rem(byte_size(rest), 255) == 0 do
    # normally packet of length that is a multiple of 255 would end with 0-length segment
    # for the rest (split packet) we don't want that
    rest_segments =
      case segment_packet(rest) do
        [0 | segments] -> segments
        [] -> []
      end

    segment_table =
      packets
      |> Enum.reduce([], fn packet, segments ->
        segment_packet(packet) ++ segments
      end)
      |> then(&Enum.concat(rest_segments, &1))
      |> Enum.reverse()

    if length(segment_table) > 255 do
      {:error, :too_many_segments}
    else
      {:ok, segment_table}
    end
  end

  defp create_segment_table(_packets, _rest), do: {:error, :rest_too_short}

  # returned segment table for the packet is reversed
  # thus the Enum.reverse/1 call in create_segment_table/2
  defp segment_packet(packet, acc \\ [])
  defp segment_packet(<<>>, [255 | _rest] = acc), do: [0 | acc]
  defp segment_packet(<<>>, acc), do: acc

  defp segment_packet(<<_seg::binary-255, rest::binary>>, acc),
    do: segment_packet(rest, [255 | acc])

  defp segment_packet(packet, acc) when is_binary(packet), do: [byte_size(packet) | acc]
end
