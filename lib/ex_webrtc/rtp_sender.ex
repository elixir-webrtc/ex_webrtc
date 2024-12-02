defmodule ExWebRTC.RTPSender do
  @moduledoc """
  Implementation of the [RTCRtpSender](https://www.w3.org/TR/webrtc/#rtcrtpsender-interface).
  """

  alias ExRTCP.Packet.{TransportFeedback.NACK, PayloadFeedback.PLI}
  alias ExWebRTC.{MediaStreamTrack, RTPCodecParameters, Utils}
  alias ExSDP.Attribute.Extmap
  alias __MODULE__.{NACKResponder, ReportRecorder}

  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"

  @type id() :: integer()

  @typedoc false
  @type sender() :: %{
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
          retransmitted_packets_sent: non_neg_integer(),
          retransmitted_bytes_sent: non_neg_integer(),
          markers_sent: non_neg_integer(),
          nack_count: non_neg_integer(),
          pli_count: non_neg_integer(),
          reports?: boolean(),
          outbound_rtx?: boolean(),
          report_recorder: ReportRecorder.t(),
          nack_responder: NACKResponder.t()
        }

  @typedoc """
  Struct representing a sender.

  The fields mostly match these of [RTCRtpSender](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpSender),
  except for:
  * `id` - to uniquely identify the sender.
  * `codec` - codec this sender is going to send.
  """
  @type t() :: %__MODULE__{
          id: id(),
          track: MediaStreamTrack.t() | nil,
          codec: RTPCodecParameters.t() | nil
        }

  @enforce_keys [:id, :track, :codec]
  defstruct @enforce_keys

  @doc false
  @spec to_struct(sender()) :: t()
  def to_struct(sender) do
    sender
    |> Map.take([:id, :track, :codec])
    |> then(&struct!(__MODULE__, &1))
  end

  @doc false
  @spec new(
          MediaStreamTrack.t() | nil,
          RTPCodecParameters.t() | nil,
          RTPCodecParameters.t() | nil,
          [Extmap.t()],
          String.t() | nil,
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          [atom()]
        ) :: sender()
  def new(track, codec, rtx_codec, rtp_hdr_exts, mid, ssrc, rtx_ssrc, features) do
    # convert to a map to be able to find extension id using extension uri
    rtp_hdr_exts = Map.new(rtp_hdr_exts, fn extmap -> {extmap.uri, extmap} end)
    # TODO: handle cases when codec == nil (no valid codecs after negotiation)
    pt = if codec != nil, do: codec.payload_type, else: nil
    rtx_pt = if rtx_codec != nil, do: rtx_codec.payload_type, else: nil

    %{
      id: Utils.generate_id(),
      track: track,
      codec: codec,
      rtp_hdr_exts: rtp_hdr_exts,
      pt: pt,
      rtx_pt: rtx_pt,
      ssrc: ssrc,
      rtx_ssrc: rtx_ssrc,
      mid: mid,
      packets_sent: 0,
      bytes_sent: 0,
      retransmitted_packets_sent: 0,
      retransmitted_bytes_sent: 0,
      markers_sent: 0,
      nack_count: 0,
      pli_count: 0,
      reports?: :rtcp_reports in features,
      outbound_rtx?: :outbound_rtx in features,
      report_recorder: %ReportRecorder{clock_rate: codec && codec.clock_rate},
      nack_responder: %NACKResponder{}
    }
  end

  @doc false
  @spec update(sender(), String.t(), RTPCodecParameters.t() | nil, RTPCodecParameters.t() | nil, [
          Extmap.t()
        ]) :: sender()
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

    %{
      sender
      | mid: mid,
        codec: codec,
        rtp_hdr_exts: rtp_hdr_exts,
        pt: pt,
        rtx_pt: rtx_pt,
        report_recorder: report_recorder
    }
  end

  @doc false
  @spec send_packet(sender(), ExRTP.Packet.t(), boolean()) :: {binary(), sender()}
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

    report_recorder =
      if sender.reports? do
        ReportRecorder.record_packet(sender.report_recorder, packet)
      else
        sender.report_recorder
      end

    nack_responder =
      if sender.outbound_rtx? do
        NACKResponder.record_packet(sender.nack_responder, packet)
      else
        sender.nack_responder
      end

    data = ExRTP.Packet.encode(packet)

    sender =
      if rtx? do
        %{
          sender
          | retransmitted_packets_sent: sender.retransmitted_packets_sent + 1,
            retransmitted_bytes_sent: sender.retransmitted_bytes_sent + byte_size(data)
        }
      else
        sender
      end

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
  @spec receive_nack(sender(), NACK.t()) :: {[ExRTP.Packet.t()], sender()}
  def receive_nack(sender, nack) do
    {packets, nack_responder} = NACKResponder.get_rtx(sender.nack_responder, nack)
    sender = %{sender | nack_responder: nack_responder, nack_count: sender.nack_count + 1}

    {packets, sender}
  end

  @doc false
  @spec receive_pli(sender(), PLI.t()) :: sender()
  def receive_pli(sender, _pli) do
    %{sender | pli_count: sender.pli_count + 1}
  end

  @doc false
  @spec get_reports(sender()) :: {[ExRTCP.Packet.SenderReport.t()], sender()}
  def get_reports(sender) do
    case ReportRecorder.get_report(sender.report_recorder) do
      {:ok, report, recorder} ->
        sender = %{sender | report_recorder: recorder}
        {[report], sender}

      {:error, _res} ->
        {[], sender}
    end
  end

  @doc false
  @spec get_stats(sender(), non_neg_integer()) :: map()
  def get_stats(sender, timestamp) do
    %{
      timestamp: timestamp,
      type: :outbound_rtp,
      id: sender.id,
      track_identifier: get_in(sender.track.id),
      ssrc: sender.ssrc,
      packets_sent: sender.packets_sent,
      bytes_sent: sender.bytes_sent,
      markers_sent: sender.markers_sent,
      retransmitted_packets_sent: sender.retransmitted_packets_sent,
      retransmitted_bytes_sent: sender.retransmitted_bytes_sent,
      nack_count: sender.nack_count,
      pli_count: sender.pli_count
    }
  end
end
