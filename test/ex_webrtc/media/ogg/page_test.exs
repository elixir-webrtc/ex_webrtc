defmodule ExWEbRTC.Media.Ogg.PageTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.Ogg.Page

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
  @header_type 0b00000101
  @granule_pos 113_543
  @serial_no 553_111
  @sequence_no 5

  # without CRC and segment table
  @header <<
    @signature::binary,
    @version,
    @header_type,
    @granule_pos::little-64,
    @serial_no::little-32,
    @sequence_no::little-32
  >>

  @long_packet_seg <<255, 255, 678 - 255 - 255>>
  @long_packet for _ <- 1..678, do: <<42>>, into: <<>>
  @short_packet_seg <<202>>
  @short_packet for _ <- 1..202, do: <<58>>, into: <<>>
  @split_packet_seg <<255>>
  @split_packet for _ <- 1..255, do: <<37>>, into: <<>>

  @page %Page{
    type: %{fresh?: true, first?: false, last?: true},
    granule_pos: @granule_pos,
    serial_no: @serial_no,
    sequence_no: @sequence_no,
    packets: [],
    rest: <<>>
  }

  describe "read/1" do
    @tag :tmp_dir
    test "correct page with whole packets", %{tmp_dir: tmp_dir} do
      file_name = "#{tmp_dir}/audio.ogg"
      {:ok, file} = File.open(file_name, [:write])

      page = <<
        @header::binary,
        0::32,
        4,
        @long_packet_seg::binary,
        @short_packet_seg::binary,
        @long_packet::binary,
        @short_packet::binary
      >>

      page = add_checksum(page)
      :ok = IO.binwrite(file, page)

      {:ok, file} = File.open(file_name)
      assert {:ok, page} = Page.read(file)

      valid_page = %Page{@page | packets: [@long_packet, @short_packet]}
      assert valid_page == page
    end

    @tag :tmp_dir
    test "correct page with split packet", %{tmp_dir: tmp_dir} do
      file_name = "#{tmp_dir}/audio.ogg"
      {:ok, file} = File.open(file_name, [:write])

      page = <<
        @header::binary,
        0::32,
        4,
        @long_packet_seg::binary,
        @split_packet_seg::binary,
        @long_packet::binary,
        @split_packet::binary
      >>

      page = add_checksum(page)
      :ok = IO.binwrite(file, page)

      {:ok, file} = File.open(file_name)
      assert {:ok, page} = Page.read(file)

      valid_page = %Page{@page | packets: [@long_packet], rest: @split_packet}
      assert valid_page == page
    end

    @tag :tmp_dir
    test "packet with incorrect checksum", %{tmp_dir: tmp_dir} do
      file_name = "#{tmp_dir}/audio.ogg"
      {:ok, file} = File.open(file_name, [:write])
      # 2 whole packets
      page = <<
        @header::binary,
        5::32,
        4,
        @long_packet_seg::binary,
        @split_packet_seg::binary,
        @long_packet::binary,
        @split_packet
      >>

      # no checksum added
      :ok = IO.binwrite(file, page)

      {:ok, file} = File.open(file_name)
      assert {:error, :invalid_checksum} = Page.read(file)
    end
  end

  describe "write/2" do
    @tag :tmp_dir
    test "correct page with whole packets", %{tmp_dir: tmp_dir} do
      page = %Page{@page | packets: [@long_packet, @short_packet]}

      file_name = "#{tmp_dir}/audio.ogg"
      {:ok, file} = File.open(file_name, [:write])
      :ok = Page.write(file, page)

      {:ok, file} = File.open(file_name)
      page = IO.binread(file, :eof)

      checksum = calculate_checksum(page)

      assert <<
               @header::binary,
               ^checksum::little-32,
               4,
               @long_packet_seg::binary,
               @short_packet_seg::binary,
               @long_packet::binary,
               @short_packet::binary
             >> = page
    end

    @tag :tmp_dir
    test "correct file with split packet", %{tmp_dir: tmp_dir} do
      page = %Page{@page | packets: [@long_packet], rest: @split_packet}

      file_name = "#{tmp_dir}/audio.ogg"
      {:ok, file} = File.open(file_name, [:write])
      :ok = Page.write(file, page)

      {:ok, file} = File.open(file_name)
      page = IO.binread(file, :eof)

      checksum = calculate_checksum(page)

      assert <<
               @header,
               ^checksum::little-32,
               4,
               @long_packet_seg::binary,
               @split_packet_seg::binary,
               @long_packet::binary,
               @split_packet::binary
             >> = page
    end
  end

  defp add_checksum(<<before_crc::binary-22, _::32, after_crc::binary>> = page) do
    checksum = CRC.calculate(page, @crc_params)
    <<before_crc::binary, checksum::little-32, after_crc::binary>>
  end

  defp calculate_checksum(<<before_crc::binary-22, _::32, after_crc::binary>>) do
    CRC.calculate(<<before_crc::binary, 0::32, after_crc::binary>>, @crc_params)
  end
end
