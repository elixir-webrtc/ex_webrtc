defmodule ExWebRTC.SessionDescription do
  @moduledoc false

  @type description_type() ::
    :answer
    | :offer
    | :pranswer
    | :rollback

  @type t() :: %__MODULE__{
    type: description_type(),
    sdp: String.t()
  }

  @enforce_keys [:type, :sdp]
  defstruct @enforce_keys
end
