defmodule ExWebRTC.Media.IVF.WritertTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.IVF.{Frame, Header, Reader, Writer}

  @tag :tmp_dir
  test "IVF writer", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "output.ivf"])
    <<fourcc::little-32>> = "VP80"
    num_frames = 5

    {:ok, writer} =
      Writer.open(path,
        fourcc: fourcc,
        height: 640,
        width: 480,
        num_frames: num_frames,
        timebase_denum: 30,
        timebase_num: 1
      )

    writer =
      for i <- 0..(num_frames - 1), reduce: writer do
        writer ->
          frame = %Frame{timestamp: i, data: <<0, 1, 2, 3, 4>>}
          assert {:ok, writer} = Writer.write_frame(writer, frame)
          writer
      end

    assert {:ok,
            %Header{
              fourcc: ^fourcc,
              height: 640,
              width: 480,
              num_frames: ^num_frames,
              timebase_denum: 30,
              timebase_num: 1,
              unused: 0
            }, _reader} = Reader.open(path)

    # check if we update IVF header after writing
    # `num_frames + 1` frame
    expected_num_frames = 2 * num_frames
    frame = %Frame{timestamp: num_frames, data: <<0, 1, 2, 3, 4>>}
    assert {:ok, writer} = Writer.write_frame(writer, frame)

    assert {:ok,
            %Header{
              fourcc: ^fourcc,
              height: 640,
              width: 480,
              num_frames: ^expected_num_frames,
              timebase_denum: 30,
              timebase_num: 1,
              unused: 0
            }, reader} = Reader.open(path)

    # check if we raise when trying to write an empty frame
    empty_frame = %Frame{timestamp: num_frames + 1, data: <<>>}
    assert_raise FunctionClauseError, fn -> Writer.write_frame(writer, empty_frame) end

    # assert written frames are correct
    for i <- 0..num_frames do
      assert {:ok, %Frame{} = frame} = Reader.next_frame(reader)
      assert frame.timestamp == i
      assert frame.data == <<0, 1, 2, 3, 4>>
    end

    # assert that after calling close/1, number of frames
    # in the header is equal to the
    # exact number of frames that were written
    assert :ok = Writer.close(writer)
    exact_num_frames = num_frames + 1

    assert {:ok,
            %Header{
              fourcc: ^fourcc,
              height: 640,
              width: 480,
              num_frames: ^exact_num_frames,
              timebase_denum: 30,
              timebase_num: 1,
              unused: 0
            }, _reader} = Reader.open(path)
  end
end
