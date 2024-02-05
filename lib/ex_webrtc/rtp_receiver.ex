defmodule ExWebRTC.RTPReceiver do
  @moduledoc """
  Implementation of the [RTCRtpReceiver](https://www.w3.org/TR/webrtc/#rtcrtpreceiver-interface).
  """

  alias ExWebRTC.{MediaStreamTrack, Utils}

  @type t() :: %__MODULE__{
          track: MediaStreamTrack.t(),
          ssrc: non_neg_integer() | nil,
          bytes_received: non_neg_integer(),
          packets_received: non_neg_integer(),
          markers_received: non_neg_integer()
        }

  defstruct [:track, :ssrc, bytes_received: 0, packets_received: 0, markers_received: 0]

  @doc false
  @spec recv(t(), ExRTP.Packet.t(), binary()) :: t()
  def recv(receiver, packet, raw_packet) do
    # TODO assign ssrc when applying local/remote description.
    %__MODULE__{
      receiver
      | ssrc: packet.ssrc,
        bytes_received: receiver.bytes_received + byte_size(raw_packet),
        packets_received: receiver.packets_received + 1,
        markers_received: receiver.markers_received + Utils.to_int(packet.marker)
    }
  end

  @doc false
  @spec get_stats(t(), non_neg_integer()) :: map()
  def get_stats(receiver, timestamp) do
    %{
      id: receiver.track.id,
      type: :inbound_rtp,
      timestamp: timestamp,
      ssrc: receiver.ssrc,
      bytes_received: receiver.bytes_received,
      packets_received: receiver.packets_received,
      markers_received: receiver.markers_received
    }
  end
end
