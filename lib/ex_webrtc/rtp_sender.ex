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
          codecs: [RTPCodecParameters.t()],
          rtp_hdr_exts: %{Extmap.extension_id() => Extmap.t()},
          mid: String.t() | nil,
          pt: non_neg_integer() | nil,
          rtx_pt: non_neg_integer() | nil,
          # ssrc and rtx_ssrc are always present, even if there is no track,
          # or transceiver direction is recvonly.
          # We preallocate them so they can be included in SDP when needed.
          ssrc: non_neg_integer(),
          rtx_ssrc: non_neg_integer(),
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
          [RTPCodecParameters.t()],
          [Extmap.t()],
          String.t() | nil,
          non_neg_integer(),
          non_neg_integer(),
          [atom()]
        ) :: sender()
  def new(track, codecs, rtp_hdr_exts, mid, ssrc, rtx_ssrc, features) do
    # convert to a map to be able to find extension id using extension uri
    rtp_hdr_exts = Map.new(rtp_hdr_exts, fn extmap -> {extmap.uri, extmap} end)

    # We always only take one codec to avoid ambiguity when assigning payload type for RTP packets.
    # In other case, if PeerConnection negotiated multiple codecs,
    # user would have to pass RTP codec when sending RTP packets,
    # or assign payload type on their own.
    {codec, rtx_codec} = get_default_codec(codecs)

    # TODO: handle cases when codec == nil (no valid codecs after negotiation)
    pt = if codec != nil, do: codec.payload_type, else: nil
    rtx_pt = if rtx_codec != nil, do: rtx_codec.payload_type, else: nil

    %{
      id: Utils.generate_id(),
      track: track,
      codec: codec,
      codecs: codecs,
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
  @spec update(sender(), String.t(), [RTPCodecParameters.t()], [Extmap.t()]) :: sender()
  def update(sender, mid, codecs, rtp_hdr_exts) do
    if sender.mid != nil and mid != sender.mid, do: raise(ArgumentError)

    {codec, rtx_codec} = get_default_codec(codecs)

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
        codecs: codecs,
        rtp_hdr_exts: rtp_hdr_exts,
        pt: pt,
        rtx_pt: rtx_pt,
        report_recorder: report_recorder
    }
  end

  @spec get_mline_attrs(sender()) :: [ExSDP.Attribute.t()]
  def get_mline_attrs(sender) do
    # Don't include track id. See RFC 8829 sec. 5.2.1
    msid_attrs =
      case sender.track do
        %MediaStreamTrack{streams: streams} when streams != [] ->
          Enum.map(streams, &ExSDP.Attribute.MSID.new(&1, nil))

        _other ->
          # In theory, we should do this "for each MediaStream that was associated with the transceiver",
          # but web browsers (chrome, ff) include MSID even when there aren't any MediaStreams
          [ExSDP.Attribute.MSID.new("-", nil)]
      end

    ssrc_attrs =
      get_ssrc_attrs(sender.pt, sender.rtx_pt, sender.ssrc, sender.rtx_ssrc, sender.track)

    msid_attrs ++ ssrc_attrs
  end

  # we didn't manage to negotiate any codec
  defp get_ssrc_attrs(nil, _rtx_pt, _ssrc, _rtx_ssrc, _track) do
    []
  end

  # we have a codec but not rtx
  defp get_ssrc_attrs(_pt, nil, ssrc, _rtx_ssrc, track) do
    streams = (track && track.streams) || []

    case streams do
      [] ->
        [%ExSDP.Attribute.SSRC{id: ssrc, attribute: "msid", value: "-"}]

      streams ->
        Enum.map(streams, fn stream ->
          %ExSDP.Attribute.SSRC{id: ssrc, attribute: "msid", value: stream}
        end)
    end
  end

  # we have both codec and rtx
  defp get_ssrc_attrs(_pt, _rtx_pt, ssrc, rtx_ssrc, track) do
    streams = (track && track.streams) || []

    fid = %ExSDP.Attribute.SSRCGroup{semantics: "FID", ssrcs: [ssrc, rtx_ssrc]}

    ssrc_attrs =
      case streams do
        [] ->
          [
            %ExSDP.Attribute.SSRC{id: ssrc, attribute: "msid", value: "-"},
            %ExSDP.Attribute.SSRC{id: rtx_ssrc, attribute: "msid", value: "-"}
          ]

        streams ->
          {ssrc_attrs, rtx_ssrc_attrs} =
            Enum.reduce(streams, {[], []}, fn stream, {ssrc_attrs, rtx_ssrc_attrs} ->
              ssrc_attr = %ExSDP.Attribute.SSRC{id: ssrc, attribute: "msid", value: stream}
              ssrc_attrs = [ssrc_attr | ssrc_attrs]

              rtx_ssrc_attr = %ExSDP.Attribute.SSRC{
                id: rtx_ssrc,
                attribute: "msid",
                value: stream
              }

              rtx_ssrc_attrs = [rtx_ssrc_attr | rtx_ssrc_attrs]

              {ssrc_attrs, rtx_ssrc_attrs}
            end)

          Enum.reverse(ssrc_attrs) ++ Enum.reverse(rtx_ssrc_attrs)
      end

    [fid | ssrc_attrs]
  end

  @doc false
  @spec send_packet(sender(), ExRTP.Packet.t(), boolean()) :: {binary(), sender()}
  def send_packet(sender, packet, rtx?) do
    {pt, ssrc} =
      if rtx? do
        {sender.rtx_pt, sender.rtx_ssrc}
      else
        {sender.pt, sender.ssrc}
      end

    packet = %{packet | payload_type: pt, ssrc: ssrc}

    # Add mid header extension only if it was negotiated.
    # The receiver can still demux packets based
    # on ssrc (if it was included in sdp) or payload type.
    packet =
      case Map.get(sender.rtp_hdr_exts, @mid_uri) do
        %Extmap{} = mid_extmap ->
          mid_ext =
            %ExRTP.Packet.Extension.SourceDescription{text: sender.mid}
            |> ExRTP.Packet.Extension.SourceDescription.to_raw(mid_extmap.id)

          packet
          |> ExRTP.Packet.remove_extension(mid_extmap.id)
          |> ExRTP.Packet.add_extension(mid_ext)

        nil ->
          packet
      end

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
      track_identifier: if(sender.track, do: sender.track.id, else: nil),
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

  defp get_default_codec(codecs) do
    {rtx_codecs, media_codecs} = Utils.split_rtx_codecs(codecs)

    case List.first(media_codecs) do
      nil ->
        {nil, nil}

      codec ->
        {codec, find_associated_rtx_codec(rtx_codecs, codec)}
    end
  end

  defp find_associated_rtx_codec(codecs, codec) do
    Enum.find(codecs, &(&1.sdp_fmtp_line && &1.sdp_fmtp_line.apt == codec.payload_type))
  end
end
