defmodule ExWebRTC.DataChannel do
  @moduledoc """
  TODO
  """

  @type order() :: :ordered | :unordered

  @type id() :: non_neg_integer()

  @type ready_state() :: :connecting | :open | :closing | :closed

  @type options() :: [
          ordered: order(),
          max_packet_life_time: non_neg_integer(),
          max_retransmits: non_neg_integer(),
          protocol: String.t()
        ]

  @type t() :: %__MODULE__{
          id: non_neg_integer() | nil,
          label: String.t(),
          max_packet_life_time: non_neg_integer() | nil,
          max_retransmits: non_neg_integer() | nil,
          ordered: order(),
          protocol: String.t(),
          ready_state: ready_state()
        }

  @enforce_keys [:id, :label, :ordered, :protocol, :ready_state]
  defstruct @enforce_keys ++ [:max_packet_life_time, :max_retransmits]
end
