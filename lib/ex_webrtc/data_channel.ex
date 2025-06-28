defmodule ExWebRTC.DataChannel do
  @moduledoc """
  Implementation of the [RTCDataChannel](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel).
  """

  @typedoc """
  Possible data channel order configurations.

  For the exact meaning, refer to the [RTCDataChannel: order property](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel/readyState).
  """
  @type order() :: boolean()

  @type ref() :: reference()

  @typedoc """
  Possible data channel states.

  Right now, Elixir WebRTC does not support `:closing` state.
  When you close the data channel, it goes from `:open` directly to `:closed`.

  For the exact meaning, refer to the [RTCDataChannel: readyState property](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel/readyState).
  """
  @type ready_state() :: :connecting | :open | :closed

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

  It's worth to mention that `id` and `label` can be used by the other peer to identify the data
  channel, althought be careful as:
  * `label` does not have to be unique, channels can share a single label,
  * `id` is only assigned after the SCTP connection has been established (which means
  that DataChannels created before first negotiation will have `id` set to `nil`)
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
