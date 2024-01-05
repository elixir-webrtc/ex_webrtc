defmodule ExWebRTC.RTPSender do
  @moduledoc """
  Prepares RTP packets for sending.
  """
  import Bitwise

  alias ExWebRTC.{MediaStreamTrack, RTPCodecParameters, Utils}
  alias ExSDP.Attribute.Extmap

  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"

  @type id() :: integer()

  @type t() :: %__MODULE__{
          id: id(),
          track: MediaStreamTrack.t() | nil,
          codec: RTPCodecParameters.t() | nil,
          rtp_hdr_exts: %{Extmap.extension_id() => Extmap.t()},
          mid: String.t() | nil,
          pt: non_neg_integer() | nil,
          ssrc: non_neg_integer() | nil,
          last_seq_num: non_neg_integer()
        }

  @enforce_keys [:id, :last_seq_num]
  defstruct @enforce_keys ++ [:track, :codec, :mid, :pt, :ssrc, rtp_hdr_exts: %{}]

  @doc false
  @spec new(
          MediaStreamTrack.t() | nil,
          RTPCodecParameters.t() | nil,
          [Extmap.t()],
          String.t() | nil,
          non_neg_integer | nil
        ) :: t()
  def new(track, codec, rtp_hdr_exts, mid \\ nil, ssrc) do
    # convert to a map to be able to find extension id using extension uri
    rtp_hdr_exts = Map.new(rtp_hdr_exts, fn extmap -> {extmap.uri, extmap} end)
    # TODO: handle cases when codec == nil (no valid codecs after negotiation)
    pt = if codec != nil, do: codec.payload_type, else: nil

    %__MODULE__{
      id: Utils.generate_id(),
      track: track,
      codec: codec,
      rtp_hdr_exts: rtp_hdr_exts,
      pt: pt,
      ssrc: ssrc,
      last_seq_num: random_seq_num(),
      mid: mid
    }
  end

  @spec update(t(), RTPCodecParameters.t(), [Extmap.t()]) :: t()
  def update(sender, codec, rtp_hdr_exts) do
    # convert to a map to be able to find extension id using extension uri
    rtp_hdr_exts = Map.new(rtp_hdr_exts, fn extmap -> {extmap.uri, extmap} end)
    # TODO: handle cases when codec == nil (no valid codecs after negotiation)
    pt = if codec != nil, do: codec.payload_type, else: nil

    %__MODULE__{sender | codec: codec, rtp_hdr_exts: rtp_hdr_exts, pt: pt}
  end

  # Prepares packet for sending i.e.:
  # * assigns SSRC, pt, seq_num, mid
  # * serializes to binary
  @doc false
  @spec send(t(), ExRTP.Packet.t()) :: {binary(), t()}
  def send(sender, packet) do
    %Extmap{} = mid_extmap = Map.fetch!(sender.rtp_hdr_exts, @mid_uri)

    mid_ext =
      %ExRTP.Packet.Extension.SourceDescription{text: sender.mid}
      |> ExRTP.Packet.Extension.SourceDescription.to_raw(mid_extmap.id)

    next_seq_num = sender.last_seq_num + 1 &&& 0xFFFF
    packet = %{packet | payload_type: sender.pt, ssrc: sender.ssrc, sequence_number: next_seq_num}

    packet =
      packet
      |> ExRTP.Packet.set_extension(:two_byte, [mid_ext])
      |> ExRTP.Packet.encode()

    sender = %{sender | last_seq_num: next_seq_num}
    {packet, sender}
  end

  defp random_seq_num(), do: Enum.random(0..65_535)
end
