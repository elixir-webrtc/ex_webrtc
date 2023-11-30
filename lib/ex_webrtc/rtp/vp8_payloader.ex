defmodule ExWebRTC.RTP.VP8Payloader do
  @moduledoc """
  Encapsulates VP8 video frames into RTP packets.

  It does not support `X` bit right now, in particular it
  does not pay attention to VP8 partion boundaries (see RFC 7741 sec. 4.4).
  """

  @first_chunk_descriptor <<0::1, 0::1, 0::1, 1::1, 0::1, 0::3>>

  @next_chunk_descriptor <<0::1, 0::1, 0::1, 0::1, 0::1, 0::3>>

  @desc_size_bytes 1

  @opaque t() :: %__MODULE__{
            max_payload_size: non_neg_integer()
          }

  defstruct [:max_payload_size]

  @spec new(non_neg_integer()) :: t()
  def new(max_payload_size \\ 1000) when max_payload_size > 100 do
    %__MODULE__{max_payload_size: max_payload_size}
  end

  @doc """
  Packs VP8 frame into one or more RTP packets.

  Fields from RTP header like ssrc, timestamp etc. are set to 0.
  """
  @spec payload(t(), frame :: binary()) :: {[ExRTP.Packet.t()], t()}
  def payload(payloader, frame) when frame != <<>> do
    rtp_payloads = chunk(frame, payloader.max_payload_size - @desc_size_bytes)

    [first_rtp_payload | next_rtp_payloads] = rtp_payloads

    first_rtp_packet = ExRTP.Packet.new(@first_chunk_descriptor <> first_rtp_payload, 0, 0, 0, 0)

    next_rtp_packets =
      for rtp_payload <- next_rtp_payloads do
        ExRTP.Packet.new(@next_chunk_descriptor <> rtp_payload, 0, 0, 0, 0)
      end

    rtp_packets = [first_rtp_packet | next_rtp_packets]
    rtp_packets = List.update_at(rtp_packets, -1, &%ExRTP.Packet{&1 | marker: true})

    {rtp_packets, payloader}
  end

  defp chunk(data, size, acc \\ [])
  defp chunk(<<>>, _size, acc), do: Enum.reverse(acc)

  defp chunk(data, size, acc) do
    case data do
      <<data::binary-size(size), rest::binary>> ->
        chunk(rest, size, [data | acc])

      _other ->
        chunk(<<>>, size, [data | acc])
    end
  end
end
