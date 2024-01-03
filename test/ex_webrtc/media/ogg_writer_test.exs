defmodule ExWebRTC.Media.OggWriterTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.OggWriter

  # dummy 200 byte Opus packet with 20 ms TOC sequence
  @opus_packet <<12::5, 0::1, 1::2>> <> for(_ <- 1..199, do: <<13>>, into: <<>>)

  @tag :tmp_dir
  test "writes Opus header", %{tmp_dir: tmp_dir} do
    file_name = "#{tmp_dir}/test.ogg"
    assert {:ok, writer} = OggWriter.open(file_name)
    assert :ok = OggWriter.close(writer)

    {:ok, file} = File.open(file_name)

    # Page header = 27 bytes (assuming 1 segment), ID Header = 19 bytes
    id_header = IO.binread(file, 28 + 19)

    assert <<
             "OggS",
             # version
             0,
             # type (beginning of stream)
             2,
             # granule_pos (0 for ID header)
             0::64,
             serial_no::little-32,
             # sequence number
             0::32,
             _checksum::32,
             # number of segments
             1,
             # length of the segment
             19,
             "OpusHead",
             # Id header version
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
           >> = id_header

    # length of comment header == 26
    comment_header = IO.binread(file, 28 + 26)

    assert <<
             "OggS",
             0,
             # not type flag set
             0,
             # also 0 for comment header
             0::64,
             ^serial_no::little-32,
             # next sequence number
             1::little-32,
             _checksum::32,
             # number of segments
             1,
             # segments table
             26,
             "OpusTags",
             # vendor string length
             13::little-32,
             # vendor string
             "elixir-webrtc",
             # no more comments
             0
           >> = comment_header
  end

  @tag :tmp_dir
  test "writes packets to multiple pages", %{tmp_dir: tmp_dir} do
    file_name = "#{tmp_dir}/test.ogg"
    assert {:ok, writer} = OggWriter.open(file_name)
    # 260 packets = 1st page with 255 packets, 2nd page with 5 packets
    writer =
      Enum.reduce(1..260, writer, fn _, writer ->
        assert {:ok, writer} = OggWriter.write_packet(writer, @opus_packet)
        writer
      end)

    assert :ok = OggWriter.close(writer)

    {:ok, file} = File.open(file_name)

    # discard Opus headers
    _opus_headers = IO.binread(file, 28 + 19 + 28 + 26)

    header_1 = IO.binread(file, 27)
    granule_pos = 255 * 20 * 48
    # meaning of fields the same as in opus header test
    assert <<
             "OggS",
             0,
             # no flag set
             0,
             ^granule_pos::little-64,
             serial_no::little-32,
             # sequence number
             2::little-32,
             _checksum::32,
             # number of segments
             255
           >> = header_1

    segment_table_1 = IO.binread(file, 255)
    assert segment_table_1 == for(_ <- 1..255, do: <<200>>, into: <<>>)

    assert is_binary(IO.binread(file, 255 * 200))

    header_2 = IO.binread(file, 27)
    granule_pos = granule_pos + 5 * 20 * 48

    assert <<
             "OggS",
             0,
             # last page flag
             4,
             ^granule_pos::little-64,
             ^serial_no::little-32,
             # sequence number
             3::little-32,
             _checksum::32,
             # number of segments
             5
           >> = header_2

    segment_table_2 = IO.binread(file, 5)
    assert segment_table_2 == for(_ <- 1..5, do: <<200>>, into: <<>>)

    assert is_binary(IO.binread(file, 5 * 200))

    assert <<>> == IO.binread(file, :all)
  end
end
