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
        case update(tr, mline) do
          {:ok, tr} -> List.replace_at(transceivers, idx, tr)
          {:error, :remove} -> List.delete_at(transceivers, idx)
        end

      nil ->
        transceivers ++ [%__MODULE__{mid: mid, direction: :recvonly, kind: mline.type}]
    end
  end

  defp update(transceiver, mline) do
    # if there is no direction, the default is sendrecv
    # see RFC 3264, sec. 6.1  
    case ExWebRTC.Utils.get_media_direction(mline) || :sendrecv do
      :inactive -> {:error, :remove}
      other_direction -> {:ok, %__MODULE__{transceiver | direction: other_direction}}
    end
  end
end
