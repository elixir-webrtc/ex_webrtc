defmodule ExWebRTC.DataChannel do
  @moduledoc """
  Implementation of the [RTCDataChannel](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel).
  """

  @type order() :: :ordered | :unordered

  @type ref() :: reference()

  @type id() :: non_neg_integer()

  @type ready_state() :: :connecting | :open | :closing | :closed

  @typedoc """
  Options used when creating a new DataChannel.

  For more information refer to `ExWebRTC.PeerConnection.create_data_channel/3`.

  As of now, Elixir WebRTC does not support `negotiated: true` option, all DataChannels need to be
  negotiated in-band.
  """
  @type options() :: [
          ordered: order(),
          max_packet_life_time: non_neg_integer(),
          max_retransmits: non_neg_integer(),
          protocol: String.t()
        ]

  @typedoc """
  Struct representing the DataChannel.

  All of the fields have the same meaning as in [RTCDataChannel](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel)
  except for `ref` which is a local identifier used when refering to this DataChannel in
  received messages or when calling `ExWebRTC.PeerConnection.send_data/3` function.
  """
  @type t() :: %__MODULE__{
          ref: ref(),
          id: non_neg_integer() | nil,
          label: String.t(),
          max_packet_life_time: non_neg_integer() | nil,
          max_retransmits: non_neg_integer() | nil,
          ordered: order(),
          protocol: String.t(),
          ready_state: ready_state()
        }

  @enforce_keys [:ref, :id, :label, :ordered, :protocol, :ready_state]
  defstruct @enforce_keys ++ [:max_packet_life_time, :max_retransmits]
end
