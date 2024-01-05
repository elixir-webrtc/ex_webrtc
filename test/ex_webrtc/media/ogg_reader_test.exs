defmodule ExWebRTC.Media.OggReaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.OggReader

  test "correct file" do
    assert {:ok, reader} = OggReader.open("test/fixtures/ogg/opus_correct.ogg")

    reader =
      Enum.reduce(0..50, reader, fn _, reader ->
        assert {:ok, {packet, duration}, reader} = OggReader.next_packet(reader)
        assert duration == 20
        assert is_binary(packet)
        assert packet != <<>>

        reader
      end)

    assert :eof = OggReader.next_packet(reader)
  end

  test "empty file" do
    assert {:error, :invalid_file} = OggReader.open("test/fixtures/ogg/empty.ogg")
  end

  test "invalid last page" do
    assert {:ok, reader} = OggReader.open("test/fixtures/ogg/opus_incorrect.ogg")

    reader =
      Enum.reduce(0..49, reader, fn _, reader ->
        {:ok, _, reader} = OggReader.next_packet(reader)
        reader
      end)

    # this is gonna be the first packet from the fourth page
    assert {:error, :invalid_checksum} = OggReader.next_packet(reader)
  end
end
