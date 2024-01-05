defmodule ExWebRTC.Media.IVF.Header do
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
          timebase_num: pos_integer(),
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
