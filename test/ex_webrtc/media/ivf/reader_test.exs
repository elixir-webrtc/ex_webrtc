defmodule ExWebRTC.Media.IVF.ReaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.IVF.{Frame, Header, Reader}

  test "correct file" do
    assert {:ok,
            %Header{
              signature: "DKIF",
              version: 0,
              header_size: 32,
              fourcc: 808_996_950,
              width: 176,
              height: 144,
              timebase_denum: 30_000,
              timebase_num: 1000,
              num_frames: 29,
              unused: 0
            }, reader} = Reader.open("test/fixtures/ivf/vp8_correct.ivf")

    for i <- 0..28 do
      assert {:ok, %Frame{} = frame} = Reader.next_frame(reader)
      assert frame.timestamp == i
      assert is_binary(frame.data)
      assert frame.data != <<>>
    end

    assert :eof == Reader.next_frame(reader)
    assert :ok == Reader.close(reader)
  end

  test "empty file" do
    assert {:error, :invalid_file} = Reader.open("test/fixtures/ivf/empty.ivf")
  end

  test "invalid last frame" do
    assert {:ok,
            %Header{
              signature: "DKIF",
              version: 0,
              header_size: 32,
              fourcc: 808_996_950,
              width: 176,
              height: 144,
              timebase_denum: 30_000,
              timebase_num: 1000,
              num_frames: 29,
              unused: 0
            }, reader} = Reader.open("test/fixtures/ivf/vp8_invalid_last_frame.ivf")

    for i <- 0..27 do
      assert {:ok, %Frame{} = frame} = Reader.next_frame(reader)
      assert frame.timestamp == i
      assert is_binary(frame.data)
      assert frame.data != <<>>
    end

    assert {:error, :invalid_file} == Reader.next_frame(reader)
  end
end
