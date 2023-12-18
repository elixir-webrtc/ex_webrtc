defmodule ExWebRTC.Media.IVFWriter do
  @moduledoc """
  Writes video frames as an IVF file.
  """

  alias ExWebRTC.Media.IVFFrame

  @opaque t() :: %__MODULE__{
            file: File.io_device(),
            frames_cnt: non_neg_integer()
          }

  @enforce_keys [:file]
  defstruct @enforce_keys ++ [update_header_after: 0, frames_cnt: 0]

  @doc """
  Creates a new IVF writer.

  Initially, IVF header is written with `num_frames` and 
  is updated every `num_frames` by `num_frames`.
  """
  @spec open(Path.t(),
          fourcc: non_neg_integer(),
          height: non_neg_integer(),
          width: non_neg_integer(),
          num_frames: pos_integer(),
          timebase_denum: non_neg_integer(),
          timebase_num: pos_integer()
        ) :: {:ok, t()} | {:error, File.posix() | term()}
  def open(path,
        fourcc: fourcc,
        height: height,
        width: width,
        num_frames: num_frames,
        timebase_denum: timebase_denum,
        timebase_num: timebase_num
      )
      when num_frames > 0 do
    header =
      <<"DKIF", 0::little-16, 32::little-16, fourcc::little-32, width::little-16,
        height::little-16, timebase_denum::little-32, timebase_num::little-32,
        num_frames::little-32, 0::little-32>>

    with {:ok, file} <- File.open(path, [:write]),
         :ok <- IO.binwrite(file, header) do
      writer = %__MODULE__{file: file, update_header_after: num_frames}
      {:ok, writer}
    end
  end

  @doc """
  Writes IVF frame into a file.
  """
  @spec write_frame(t(), IVFFrame.t()) :: {:ok, t()} | {:error, term()}
  def write_frame(writer, frame) do
    len_frame = byte_size(frame.data)
    serialized_frame = <<len_frame::little-32, frame.timestamp::little-64, frame.data::binary>>

    case IO.binwrite(writer.file, serialized_frame) do
      :ok ->
        writer = %{writer | frames_cnt: writer.frames_cnt + 1}

        if rem(writer.frames_cnt, writer.update_header_after) == 0 do
          num_frames = <<writer.frames_cnt + writer.update_header_after::little-32>>

          case :file.pwrite(writer.file, 24, num_frames) do
            :ok -> {:ok, writer}
            {:error, _reason} = error -> error
          end
        else
          {:ok, writer}
        end

      {:error, _reason} = error ->
        error
    end
  end
end
