defmodule ExWebRTC.RTPSender do
  @moduledoc """
  RTPSender
  """

  alias ExWebRTC.MediaStreamTrack

  @type t() :: %__MODULE__{
          track: MediaStreamTrack.t() | nil
        }

  defstruct [:track]
end
