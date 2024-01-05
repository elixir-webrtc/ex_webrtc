defmodule ExWebRTC.Media.OggWriterTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.OggWriter

  # dummy 200 byte Opus packet with 20 ms TOC sequence
  @packet_size 200
  @opus_packet <<12::5, 0::1, 1::2>> <> for(_ <- 1..199, do: <<13>>, into: <<>>)

  @id_len 19
  @comment_len 26
  @header_len 28

  @no_flag 0x0
  @first_flag 0x02
  @last_flag 0x04

  @tag :tmp_dir
  test "writes Opus header", %{tmp_dir: tmp_dir} do
    file_name = "#{tmp_dir}/test.ogg"

    assert {:ok, writer} = OggWriter.open(file_name)
    assert :ok = OggWriter.close(writer)

    {:ok, file} = File.open(file_name)

    assert <<
             "OggS",
             0,
             @first_flag,
             # granule_pos (0 for ID header)
             0::64,
             serial_no::little-32,
             # sequence number
             0::32,
             _checksum::32,
             # number of segments
             1,
             @id_len
           >> = IO.binread(file, @header_len)

    assert <<
             "OpusHead",
             1,
             # default channel count
             1,
             # default preskip
             3840::little-16,
             # default sample rate
             48_000::little-32,
             # default gain
             0::little-16,
             # channel mapping family
             0
           >> = IO.binread(file, @id_len)

    assert <<
             "OggS",
             0,
             @no_flag,
             # granule_pos (0 for comment header)
             0::64,
             ^serial_no::little-32,
             # next sequence number
             1::little-32,
             _checksum::32,
             # number of segments
             1,
             @comment_len
           >> = IO.binread(file, @header_len)

    assert <<
             "OpusTags",
             # vendor string length
             13::little-32,
             # vendor string
             "elixir-webrtc",
             # no more comments
             0
           >> = IO.binread(file, @comment_len)
  end

  @tag :tmp_dir
  test "writes packets to multiple pages", %{tmp_dir: tmp_dir} do
    file_name = "#{tmp_dir}/test.ogg"

    packets_1 = 255
    packets_2 = 5

    assert {:ok, writer} = OggWriter.open(file_name)

    writer =
      Enum.reduce(1..(packets_1 + packets_2), writer, fn _, writer ->
        assert {:ok, writer} = OggWriter.write_packet(writer, @opus_packet)
        writer
      end)

    assert :ok = OggWriter.close(writer)

    {:ok, file} = File.open(file_name)

    # discard Opus headers
    _opus_headers = IO.binread(file, 2 * @header_len + @id_len + @comment_len)

    header_1 = IO.binread(file, @header_len - 1)
    granule_pos = packets_1 * 20 * 48

    assert <<
             "OggS",
             0,
             @no_flag,
             ^granule_pos::little-64,
             serial_no::little-32,
             # sequence number
             2::little-32,
             _checksum::32,
             ^packets_1
           >> = header_1

    segment_table_1 = IO.binread(file, packets_1)
    assert segment_table_1 == for(_ <- 1..packets_1, do: <<@packet_size>>, into: <<>>)

    payload_1 = IO.binread(file, packets_1 * @packet_size)
    assert is_binary(payload_1)

    header_2 = IO.binread(file, @header_len - 1)
    granule_pos = granule_pos + packets_2 * 20 * 48

    assert <<
             "OggS",
             0,
             @last_flag,
             ^granule_pos::little-64,
             ^serial_no::little-32,
             # sequence number
             3::little-32,
             _checksum::32,
             ^packets_2
           >> = header_2

    segment_table_2 = IO.binread(file, packets_2)
    assert segment_table_2 == for(_ <- 1..packets_2, do: <<@packet_size>>, into: <<>>)

    payload_2 = IO.binread(file, packets_2 * @packet_size)
    assert is_binary(payload_2)

    assert <<>> == IO.binread(file, :all)
  end
end
