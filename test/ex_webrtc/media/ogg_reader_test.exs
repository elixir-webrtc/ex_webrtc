defmodule ExWebRTC.Media.OggReaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.OggReader

  test "correct file" do
    assert {:ok, _reader} = OggReader.open("test/fixtures/ogg/sine.ogg")
  end
end
