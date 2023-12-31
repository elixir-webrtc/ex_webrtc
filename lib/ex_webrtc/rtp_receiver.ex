defmodule ExWebRTC.RTPReceiver do
  @moduledoc """
  RTPReceiver
  """

  alias ExWebRTC.MediaStreamTrack

  @type t() :: %__MODULE__{
          track: MediaStreamTrack.t() | nil
        }

  defstruct [:track]
end
