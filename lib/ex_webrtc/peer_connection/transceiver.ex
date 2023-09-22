defmodule ExWebRTC.PeerConnection.Transceiver do
  @moduledoc false

  @type kind() ::
          :audio
          | :video

  @type direction() ::
          :sendrecv
          | :sendonly
          | :recvonly
          | :inactive
          | :stopped

  @type options() :: [
          direction
        ]

  # @type t() :: %__MODULE__{
  #   mid: String.t() | nil,
  #   current_direction: direction() | nil,
  #   direction: direction(),
  #   receiver: term(),
  #   sender: term(),
  #   send_encodings: term(),
  #   streams: term()
  # }
  #
  # @enforce_keys [:direction]
  # defstruct @enforce_keys ++ [:mid, :current_direction]
end
