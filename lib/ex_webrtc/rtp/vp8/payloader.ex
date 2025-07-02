defmodule ExWebRTC.RTP.Payloader.VP8 do
  @moduledoc false
  # Encapsulates VP8 video frames into RTP packets.
  #
  # Based on [RFC 7741: RTP Payload Format for VP8 Video](https://datatracker.ietf.org/doc/html/rfc7741).
  #
  # It does not support `X` bit right now, in particular it
  # does not pay attention to VP8 partition boundaries (see RFC 7741 sec. 4.4).

  @behaviour ExWebRTC.RTP.Payloader.Behaviour

  alias ExWebRTC.Utils

  @first_chunk_descriptor <<0::1, 0::1, 0::1, 1::1, 0::1, 0::3>>

  @next_chunk_descriptor <<0::1, 0::1, 0::1, 0::1, 0::1, 0::3>>

  @desc_size_bytes 1

  @type t() :: %__MODULE__{
          max_payload_size: non_neg_integer()
        }

  @enforce_keys [:max_payload_size]
  defstruct @enforce_keys

  @impl true
  def new(max_payload_size) when max_payload_size > 100 do
    %__MODULE__{max_payload_size: max_payload_size}
  end

  @impl true
  def payload(%__MODULE__{} = payloader, frame) when frame != <<>> do
    rtp_payloads = Utils.chunk(frame, payloader.max_payload_size - @desc_size_bytes)

    [first_rtp_payload | next_rtp_payloads] = rtp_payloads

    first_rtp_packet = ExRTP.Packet.new(@first_chunk_descriptor <> first_rtp_payload)

    next_rtp_packets =
      for rtp_payload <- next_rtp_payloads do
        ExRTP.Packet.new(@next_chunk_descriptor <> rtp_payload)
      end

    rtp_packets = [first_rtp_packet | next_rtp_packets]
    rtp_packets = List.update_at(rtp_packets, -1, &%ExRTP.Packet{&1 | marker: true})

    {rtp_packets, payloader}
  end
end
