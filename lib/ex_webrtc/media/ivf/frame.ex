defmodule ExWebRTC.Media.IVF.Frame do
  @moduledoc """
  Defines IVF Frame type.
  """

  @typedoc """
  IVF Frame.

  `timestamp` is in `timebase_num`/`timebase_denum` seconds.
  For more information see `ExWebRTC.Media.IVF.Header`.
  """
  @type t() :: %__MODULE__{
          timestamp: integer(),
          data: binary()
        }

  @enforce_keys [:timestamp, :data]
  defstruct @enforce_keys
end
