defmodule ExWebRTC.RTPTransceiver do
  @moduledoc """
  RTPTransceiver
  """

  @type t() :: %__MODULE__{
          mid: String.t(),
          direction: :sendonly | :recvonly | :sendrecv | :inactive | :stopped,
          kind: :audio | :video
        }

  @enforce_keys [:mid, :direction, :kind]
  defstruct @enforce_keys

  @doc false
  def find_by_mid(transceivers, mid) do
    transceivers
    |> Enum.with_index(fn tr, idx -> {idx, tr} end)
    |> Enum.find(fn {_idx, tr} -> tr.mid == mid end)
  end

  # searches for transceiver for a given mline
  # if it exists, updates its configuration
  # if it doesn't exist, creats a new one
  # returns list of updated transceivers
  @doc false
  def update_or_create(transceivers, mid, mline) do
    case find_by_mid(transceivers, mid) do
      {idx, %__MODULE__{} = tr} ->
        List.replace_at(transceivers, idx, update(tr, mline))

      nil ->
        transceivers ++ [%__MODULE__{mid: mid, direction: :recvonly, kind: mline.type}]
    end
  end

  defp update(transceiver, _mline), do: transceiver
end
