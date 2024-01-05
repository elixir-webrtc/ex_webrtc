defmodule ExWebRTC.Media.IVF.Reader do
  @moduledoc """
  Reads video frames from an IVF file.

  Based on:
  * https://formats.kaitai.io/vp8_ivf/
  * https://chromium.googlesource.com/chromium/src/media/+/refs/heads/main/filters/ivf_parser.cc
  """

  alias ExWebRTC.Media.IVF.{Frame, Header}

  @opaque t() :: File.io_device()

  @doc """
  Opens an IVF file and reads its header.
  """
  @spec open(Path.t()) :: {:ok, Header.t(), t()} | {:error, term()}
  def open(path) do
    with {:ok, file} <- File.open(path),
         <<"DKIF", 0::little-16, 32::little-16, fourcc::little-32, width::little-16,
           height::little-16, timebase_denum::little-32, timebase_num::little-32,
           num_frames::little-32, unused::little-32>> <- IO.binread(file, 32) do
      header = %Header{
        signature: "DKIF",
        version: 0,
        header_size: 32,
        fourcc: fourcc,
        width: width,
        height: height,
        timebase_denum: timebase_denum,
        timebase_num: timebase_num,
        num_frames: num_frames,
        unused: unused
      }

      {:ok, header, file}
    else
      {:error, _reason} = error -> error
      # eof or invalid pattern matching
      _other -> {:error, :invalid_file}
    end
  end

  @doc """
  Reads the next video frame from an IVF file.
  """
  @spec next_frame(t()) :: {:ok, Frame.t()} | {:error, term()} | :eof
  def next_frame(reader) do
    with <<len_frame::little-integer-size(32), timestamp::little-integer-size(64)>> <-
           IO.binread(reader, 12),
         data when is_binary(data) and byte_size(data) == len_frame <-
           IO.binread(reader, len_frame) do
      {:ok, %Frame{timestamp: timestamp, data: data}}
    else
      :eof -> :eof
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_file}
    end
  end

  @doc """
  Closes an IVF reader.

  When a process owning the IVF reader exits, IVF reader is closed automatically. 
  """
  @spec close(t()) :: :ok | {:error, File.posix() | term()}
  def close(reader) do
    File.close(reader)
  end
end
