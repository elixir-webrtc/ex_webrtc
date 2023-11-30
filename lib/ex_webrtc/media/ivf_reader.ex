defmodule ExWebRTC.Media.IVFHeader do
  @moduledoc """
  Defines IVF Frame Header type.
  """

  @typedoc """
  IVF Frame Header.

  Description of these fields is taken from:
  https://chromium.googlesource.com/chromium/src/media/+/master/filters/ivf_parser.h

  * `signature` - always "DKIF"
  * `version` - should be 0
  * `header_size` - size of header in bytes
  * `fourcc` - codec FourCC (e.g, 'VP80'). 
  For more information, see https://fourcc.org/codecs.php 
  * `width` - width in pixels
  * `height` - height in pixels
  * `timebase_denum` - timebase denumerator
  * `timebase_num` - timebase numerator. For example, if
  `timebase_denum` is 30 and `timebase_num` is 2, the unit
  of `ExWebRTC.Media.IVFFrame`'s timestamp is 2/30 seconds.
  * `num_frames` - number of frames in a file
  * `unused` - unused
  """
  @type t() :: %__MODULE__{
          signature: binary(),
          version: non_neg_integer(),
          header_size: non_neg_integer(),
          fourcc: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          timebase_denum: non_neg_integer(),
          timebase_num: non_neg_integer(),
          num_frames: non_neg_integer(),
          unused: non_neg_integer()
        }

  @enforce_keys [
    :signature,
    :version,
    :header_size,
    :fourcc,
    :width,
    :height,
    :timebase_denum,
    :timebase_num,
    :num_frames,
    :unused
  ]
  defstruct @enforce_keys
end

defmodule ExWebRTC.Media.IVFFrame do
  @moduledoc """
  Defines IVF Frame type.
  """

  @typedoc """
  IVF Frame.

  `timestamp` is in `timebase_num`/`timebase_denum` seconds.
  For more information see `ExWebRTC.Media.IVFHeader`.
  """
  @type t() :: %__MODULE__{
          timestamp: integer(),
          data: binary()
        }

  @enforce_keys [:timestamp, :data]
  defstruct @enforce_keys
end

defmodule ExWebRTC.Media.IVFReader do
  @moduledoc """
  Defines IVF reader.

  Based on:
  * https://formats.kaitai.io/vp8_ivf/
  * https://chromium.googlesource.com/chromium/src/media/+/refs/heads/main/filters/ivf_parser.cc
  """

  alias ExWebRTC.Media.{IVFHeader, IVFFrame}

  @opaque t() :: File.io_device()

  @spec open(Path.t()) :: {:ok, t()} | {:error, File.posix()}
  def open(path), do: File.open(path)

  @spec read_header(t()) :: {:ok, IVFHeader.t()} | {:error, :invalid_file} | :eof
  def read_header(reader) do
    case IO.binread(reader, 32) do
      <<"DKIF", 0::little-integer-size(16), 32::little-integer-size(16),
        fourcc::little-integer-size(32), width::little-integer-size(16),
        height::little-integer-size(16), timebase_denum::little-integer-size(32),
        timebase_num::little-integer-size(32), num_frames::little-integer-size(32),
        unused::little-integer-size(32)>> ->
        {:ok,
         %IVFHeader{
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
         }}

      _other ->
        {:error, :invalid_file}
    end
  end

  @spec next_frame(t()) :: {:ok, IVFFrame.t()} | {:error, :invalid_file} | :eof
  def next_frame(reader) do
    with <<len_frame::little-integer-size(32), timestamp::little-integer-size(64)>> <-
           IO.binread(reader, 12),
         data when is_binary(data) and byte_size(data) == len_frame <-
           IO.binread(reader, len_frame) do
      {:ok, %IVFFrame{timestamp: timestamp, data: data}}
    else
      :eof -> :eof
      _other -> {:error, :invalid_file}
    end
  end
end
