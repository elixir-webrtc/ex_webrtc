defmodule ExWebRTC.Media.IVFReaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.{IVFFrame, IVFHeader, IVFReader}

  test "correct file" do
    assert {:ok,
            %IVFHeader{
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
            }, reader} = IVFReader.open("test/fixtures/ivf/vp8_correct.ivf")

    for i <- 0..28 do
      assert {:ok, %IVFFrame{} = frame} = IVFReader.next_frame(reader)
      assert frame.timestamp == i
      assert is_binary(frame.data)
      assert frame.data != <<>>
    end

    assert :eof == IVFReader.next_frame(reader)
    assert :ok == IVFReader.close(reader)
  end

  test "empty file" do
    assert {:error, :invalid_file} = IVFReader.open("test/fixtures/ivf/empty.ivf")
  end

  test "invalid last frame" do
    assert {:ok,
            %IVFHeader{
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
            }, reader} = IVFReader.open("test/fixtures/ivf/vp8_invalid_last_frame.ivf")

    for i <- 0..27 do
      assert {:ok, %IVFFrame{} = frame} = IVFReader.next_frame(reader)
      assert frame.timestamp == i
      assert is_binary(frame.data)
      assert frame.data != <<>>
    end

    assert {:error, :invalid_file} == IVFReader.next_frame(reader)
  end
end
