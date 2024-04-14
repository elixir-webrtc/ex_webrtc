defmodule ExWebRTC.RTPSender do
  @moduledoc """
  Implementation of the [RTCRtpSender](https://www.w3.org/TR/webrtc/#rtcrtpsender-interface).
  """

  alias ExWebRTC.{MediaStreamTrack, RTPCodecParameters, Utils}
  alias ExSDP.Attribute.Extmap
  alias __MODULE__.ReportRecorder

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
          packets_sent: non_neg_integer(),
          bytes_sent: non_neg_integer(),
          markers_sent: non_neg_integer(),
          report_recorder: ReportRecorder.t()
        }

  @enforce_keys [:id, :report_recorder]
  defstruct @enforce_keys ++
              [
                :track,
                :codec,
                :mid,
                :pt,
                :ssrc,
                rtp_hdr_exts: %{},
                packets_sent: 0,
                bytes_sent: 0,
                markers_sent: 0
              ]

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
      mid: mid,
      report_recorder: %ReportRecorder{clock_rate: codec && codec.clock_rate}
    }
  end

  @doc false
  @spec update(t(), String.t(), RTPCodecParameters.t() | nil, [Extmap.t()]) :: t()
  def update(sender, mid, codec, rtp_hdr_exts) do
    if sender.mid != nil and mid != sender.mid, do: raise(ArgumentError)
    # convert to a map to be able to find extension id using extension uri
    rtp_hdr_exts = Map.new(rtp_hdr_exts, fn extmap -> {extmap.uri, extmap} end)
    # TODO: handle cases when codec == nil (no valid codecs after negotiation)
    pt = if codec != nil, do: codec.payload_type, else: nil

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
        report_recorder: report_recorder
    }
  end

  # Prepares packet for sending i.e.:
  # * assigns SSRC, pt, mid
  # * serializes to binary
  @doc false
  @spec send_packet(t(), ExRTP.Packet.t()) :: {binary(), t()}
  def send_packet(sender, packet) do
    %Extmap{} = mid_extmap = Map.fetch!(sender.rtp_hdr_exts, @mid_uri)

    mid_ext =
      %ExRTP.Packet.Extension.SourceDescription{text: sender.mid}
      |> ExRTP.Packet.Extension.SourceDescription.to_raw(mid_extmap.id)

    packet = %{packet | payload_type: sender.pt, ssrc: sender.ssrc}

    report_recorder = ReportRecorder.record_packet(sender.report_recorder, packet)

    data =
      packet
      |> ExRTP.Packet.remove_extension(mid_extmap.id)
      |> ExRTP.Packet.add_extension(mid_ext)
      |> ExRTP.Packet.encode()

    sender = %{
      sender
      | packets_sent: sender.packets_sent + 1,
        bytes_sent: sender.bytes_sent + byte_size(data),
        markers_sent: sender.markers_sent + Utils.to_int(packet.marker),
        report_recorder: report_recorder
    }

    {data, sender}
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
