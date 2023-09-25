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

  @spec from_json(%{String.t() => String.t()}) :: {:ok, t()} | :error
  def from_init(%{"type" => type})
      when type not in ["answer", "offer", "pranswer", "rollback"],
      do: :error

  def from_json(%{"type" => type, "sdp" => sdp}) do
    type = String.to_atom(type)
    {:ok, %__MODULE__{type: type, sdp: sdp}}
  end
end
