defmodule ExWebRTC.RTPSender do
  @moduledoc """
  Implementation of the [RTCRtpSender](https://www.w3.org/TR/webrtc/#rtcrtpsender-interface).
  """

  alias ExWebRTC.{MediaStreamTrack, RTPCodecParameters, Utils}
  alias ExSDP.Attribute.Extmap
  alias __MODULE__.{NackResponder, ReportRecorder}

  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"

  @type id() :: integer()

  @type t() :: %__MODULE__{
          id: id(),
          track: MediaStreamTrack.t() | nil,
          codec: RTPCodecParameters.t() | nil,
          rtp_hdr_exts: %{Extmap.extension_id() => Extmap.t()},
          mid: String.t() | nil,
          pt: non_neg_integer() | nil,
          rtx_pt: non_neg_integer() | nil,
          ssrc: non_neg_integer() | nil,
          rtx_ssrc: non_neg_integer() | nil,
          packets_sent: non_neg_integer(),
          bytes_sent: non_neg_integer(),
          markers_sent: non_neg_integer(),
          report_recorder: ReportRecorder.t(),
          nack_responder: NackResponder.t()
        }

  @enforce_keys [:id, :report_recorder, :nack_responder]
  defstruct @enforce_keys ++
              [
                :track,
                :codec,
                :mid,
                :pt,
                :rtx_pt,
                :ssrc,
                :rtx_ssrc,
                rtp_hdr_exts: %{},
                packets_sent: 0,
                bytes_sent: 0,
                markers_sent: 0
              ]

  @doc false
  @spec new(
          MediaStreamTrack.t() | nil,
          RTPCodecParameters.t() | nil,
          RTPCodecParameters.t() | nil,
          [Extmap.t()],
          String.t() | nil,
          non_neg_integer() | nil,
          non_neg_integer() | nil
        ) :: t()
  def new(track, codec, rtx_codec, rtp_hdr_exts, mid \\ nil, ssrc, rtx_ssrc) do
    # convert to a map to be able to find extension id using extension uri
    rtp_hdr_exts = Map.new(rtp_hdr_exts, fn extmap -> {extmap.uri, extmap} end)
    # TODO: handle cases when codec == nil (no valid codecs after negotiation)
    pt = if codec != nil, do: codec.payload_type, else: nil
    rtx_pt = if rtx_codec != nil, do: rtx_codec.payload_type, else: nil

    %__MODULE__{
      id: Utils.generate_id(),
      track: track,
      codec: codec,
      rtp_hdr_exts: rtp_hdr_exts,
      pt: pt,
      rtx_pt: rtx_pt,
      ssrc: ssrc,
      rtx_ssrc: rtx_ssrc,
      mid: mid,
      report_recorder: %ReportRecorder{clock_rate: codec && codec.clock_rate},
      nack_responder: %NackResponder{}
    }
  end

  @doc false
  @spec update(t(), String.t(), RTPCodecParameters.t() | nil, RTPCodecParameters.t() | nil, [
          Extmap.t()
        ]) :: t()
  def update(sender, mid, codec, rtx_codec, rtp_hdr_exts) do
    if sender.mid != nil and mid != sender.mid, do: raise(ArgumentError)
    # convert to a map to be able to find extension id using extension uri
    rtp_hdr_exts = Map.new(rtp_hdr_exts, fn extmap -> {extmap.uri, extmap} end)
    # TODO: handle cases when codec == nil (no valid codecs after negotiation)
    pt = if codec != nil, do: codec.payload_type, else: nil
    rtx_pt = if rtx_codec != nil, do: rtx_codec.payload_type, else: nil

    report_recorder = %ReportRecorder{
      sender.report_recorder
      | clock_rate: codec && codec.clock_rate
    }

    %__MODULE__{
      sender
      | mid: mid,
        codec: codec,
        rtp_hdr_exts: rtp_hdr_exts,
        pt: pt,
        rtx_pt: rtx_pt,
        report_recorder: report_recorder
    }
  end

  # Prepares packet for sending i.e.:
  # * assigns SSRC, pt, mid
  # * serializes to binary
  @doc false
  @spec send_packet(t(), ExRTP.Packet.t(), boolean()) :: {binary(), t()}
  def send_packet(sender, packet, rtx?) do
    %Extmap{} = mid_extmap = Map.fetch!(sender.rtp_hdr_exts, @mid_uri)

    mid_ext =
      %ExRTP.Packet.Extension.SourceDescription{text: sender.mid}
      |> ExRTP.Packet.Extension.SourceDescription.to_raw(mid_extmap.id)

    {pt, ssrc} =
      if rtx? do
        {sender.rtx_pt, sender.rtx_ssrc}
      else
        {sender.pt, sender.ssrc}
      end

    packet =
      %{packet | payload_type: pt, ssrc: ssrc}
      |> ExRTP.Packet.remove_extension(mid_extmap.id)
      |> ExRTP.Packet.add_extension(mid_ext)

    report_recorder = ReportRecorder.record_packet(sender.report_recorder, packet)
    nack_responder = NackResponder.record_packet(sender.nack_responder, packet)

    data = ExRTP.Packet.encode(packet)

    sender = %{
      sender
      | packets_sent: sender.packets_sent + 1,
        bytes_sent: sender.bytes_sent + byte_size(data),
        markers_sent: sender.markers_sent + Utils.to_int(packet.marker),
        report_recorder: report_recorder,
        nack_responder: nack_responder
    }

    {data, sender}
  end

  @doc false
  @spec receive_nack(t(), ExRTCP.Packet.TransportFeedback.NACK.t()) :: {[ExRTP.Packet.t()], t()}
  def receive_nack(sender, nack) do
    {packets, nack_responder} = NackResponder.get_rtx(sender.nack_responder, nack)
    sender = %{sender | nack_responder: nack_responder}

    {packets, sender}
  end

  @doc false
  @spec get_stats(t(), non_neg_integer()) :: map()
  def get_stats(sender, timestamp) do
    %{
      timestamp: timestamp,
      type: :outbound_rtp,
      id: sender.id,
      ssrc: sender.ssrc,
      packets_sent: sender.packets_sent,
      bytes_sent: sender.bytes_sent,
      markers_sent: sender.markers_sent
    }
  end
end
