defmodule ExWebRTC.RTP.AV1Payloader do
  @moduledoc """
  Encapsulates AV1 video frames into RTP packets.

  https://norkin.org/research/av1_decoder_model/index.html
  https://chromium.googlesource.com/external/webrtc/+/HEAD/modules/rtp_rtcp/source/video_rtp_depacketizer_av1.cc
   AV1 format:

   RTP payload syntax:
       0 1 2 3 4 5 6 7
      +-+-+-+-+-+-+-+-+
      |Z|Y| W |N|-|-|-| (REQUIRED)
      +=+=+=+=+=+=+=+=+ (REPEATED W-1 times, or any times if W = 0)
      |1|             |
      +-+ OBU fragment|
      |1|             | (REQUIRED, leb128 encoded)
      +-+    size     |
      |0|             |
      +-+-+-+-+-+-+-+-+
      |  OBU fragment |
      |     ...       |
      +=+=+=+=+=+=+=+=+
      |     ...       |
      +=+=+=+=+=+=+=+=+ if W > 0, last fragment MUST NOT have size field
      |  OBU fragment |
      |     ...       |
      +=+=+=+=+=+=+=+=+

   OBU syntax:
       0 1 2 3 4 5 6 7
      +-+-+-+-+-+-+-+-+
      |0| type  |X|S|-| (REQUIRED)
      +-+-+-+-+-+-+-+-+
   X: | TID |SID|-|-|-| (OPTIONAL)
      +-+-+-+-+-+-+-+-+
      |1|             |
      +-+ OBU payload |
   S: |1|             | (OPTIONAL, variable length leb128 encoded)
      +-+    size     |
      |0|             |
      +-+-+-+-+-+-+-+-+
      |  OBU payload  |
      |     ...       |
  """
  import Bitwise

  alias ExWebRTC.RTP.LEB128

  @obu_sequence_header 1
  @obu_temporal_delimiter 2

  @opaque t() :: %__MODULE__{
            max_payload_size: non_neg_integer()
          }

  defstruct [:max_payload_size]

  @spec new(non_neg_integer()) :: t()
  def new(max_payload_size \\ 1000) when max_payload_size > 100 do
    %__MODULE__{max_payload_size: max_payload_size}
  end

  @doc """
  Packs AV1 frame into one or more RTP packets.

  Fields from RTP header like ssrc, timestamp etc. are set to 0.
  """
  @spec payload(t(), frame :: binary()) :: {[ExRTP.Packet.t()], t()}
  def payload(payloader, frame) when frame != <<>> do
    # obus = parse_obus(frame)
    # for obu <- obus do
    #   <<_::1, type::4, _::3, _rest::binary>> = obu
    #   dbg(type)
    # end
    # dbg(:end)

    # remove temporal delimiter
    obus =
      frame
      |> parse_obus()
      |> Enum.reject(fn obu ->
        <<_::1, type::4, _::3, _rest::binary>> = obu
        type == @obu_temporal_delimiter
      end)

    rtp_packets =
      Enum.map(obus, fn obu ->
        <<_::1, type::4, _::3, _rest::binary>> = obu
        n_bit = if type == @obu_sequence_header, do: 1, else: 0

        # obu = LEB128.encode(byte_size(obu)) <> obu

        payload = <<0::1, 0::1, 1::2, n_bit::1, 0::3>> <> obu
        ExRTP.Packet.new(payload, 0, 0, 0, 0)
      end)

    last_rtp_packet = List.last(rtp_packets)
    last_rtp_packet = %{last_rtp_packet | marker: true}
    rtp_packets = List.insert_at(rtp_packets, -1, last_rtp_packet)
    {rtp_packets, payloader}
  end

  defp parse_obus(data, obus \\ [])
  defp parse_obus(<<>>, obus), do: Enum.reverse(obus)
  # X and S bits set
  defp parse_obus(<<_::5, 1::1, 1::1, _::1, _::8, rest::binary>> = data, obus) do
    {leb128_size, obu_payload_size} = LEB128.read(rest)
    <<obu::binary-size(2 + leb128_size + obu_payload_size), rest::binary>> = data
    parse_obus(rest, [obu | obus])
  end

  # X bit unset but S bit set
  defp parse_obus(<<_::5, 0::1, 1::1, _::1, rest::binary>> = data, obus) do
    {leb128_size, obu_payload_size} = LEB128.read(rest)
    <<obu::binary-size(1 + leb128_size + obu_payload_size), rest::binary>> = data
    parse_obus(rest, [obu | obus])
  end

  # S bit unset
  defp parse_obus(<<_::5, _::1, 0::1, _::1, _rest::binary>> = data, obus) do
    parse_obus(<<>>, [data | obus])
  end
end
