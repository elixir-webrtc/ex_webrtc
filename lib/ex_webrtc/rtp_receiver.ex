defmodule ExWebRTC.RTPReceiver do
  @moduledoc """
  Implementation of the [RTCRtpReceiver](https://www.w3.org/TR/webrtc/#rtcrtpreceiver-interface).
  """

  require Logger

  alias ExRTCP.Packet.{TransportFeedback.NACK, PayloadFeedback.PLI}
  alias ExSDP.Attribute.Extmap
  alias ExWebRTC.{MediaStreamTrack, Utils, RTPCodecParameters}
  alias __MODULE__.{NACKGenerator, ReportRecorder, SimulcastDemuxer}

  @type id() :: integer()

  @typedoc false
  @type receiver() :: %{
          id: id(),
          track: MediaStreamTrack.t(),
          # codec is the codec (to be precise its clock rate) used for initializing RTCP report generators
          codec: RTPCodecParameters.t() | nil,
          codecs: %{(payload_type :: non_neg_integer()) => RTPCodecParameters.t()},
          simulcast_demuxer: SimulcastDemuxer.t(),
          reports?: boolean(),
          inbound_rtx?: boolean(),
          layers: %{(String.t() | nil) => layer()}
        }

  @typedoc false
  @type layer() :: %{
          ssrc: non_neg_integer() | nil,
          bytes_received: non_neg_integer(),
          packets_received: non_neg_integer(),
          markers_received: non_neg_integer(),
          nack_count: non_neg_integer(),
          pli_count: non_neg_integer(),
          report_recorder: ReportRecorder.t(),
          nack_generator: NACKGenerator.t()
        }

  @typedoc """
  Struct representing a receiver.

  The fields mostly match these of [RTCRtpReceiver](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpReceiver),
  except for:
  * `id` - to uniquely identify the receiver.
  * `codec` - codec whose clock rate was used to initialize RTCP report generators. Can change after renegotiation.
  To see all codecs this receiver is able to receive, see transceiver's codecs.
  """
  @type t() :: %__MODULE__{
          id: id(),
          track: MediaStreamTrack.t(),
          codec: RTPCodecParameters.t() | nil
        }

  @enforce_keys [:id, :track, :codec]
  defstruct @enforce_keys

  @doc false
  @spec to_struct(receiver()) :: t()
  def to_struct(receiver) do
    receiver
    |> Map.take([:id, :track, :codec])
    |> then(&struct!(__MODULE__, &1))
  end

  @doc false
  @spec new(MediaStreamTrack.t(), [RTPCodecParameters.t()], [Extmap.t()], [atom()]) :: receiver()
  def new(track, codecs, rtp_hdr_exts, features) do
    {_rtx_codecs, media_codecs} = Utils.split_rtx_codecs(codecs)
    codec = List.first(media_codecs)
    codecs = Map.new(media_codecs, fn codec -> {codec.payload_type, codec} end)

    # layer `nil` is for the packets without RID/ no simulcast
    %{
      id: Utils.generate_id(),
      track: track,
      codec: codec,
      codecs: codecs,
      simulcast_demuxer: SimulcastDemuxer.new(rtp_hdr_exts),
      reports?: :rtcp_reports in features,
      inbound_rtx?: :inbound_rtx in features,
      layers: %{}
    }
  end

  @doc false
  @spec update(receiver(), [RTPCodecParameters.t()], [Extmap.t()], [String.t()]) :: receiver()
  def update(receiver, codecs, rtp_hdr_exts, stream_ids) do
    {_rtx_codecs, media_codecs} = Utils.split_rtx_codecs(codecs)
    codec = List.first(media_codecs)
    codecs = Map.new(media_codecs, fn codec -> {codec.payload_type, codec} end)
    simulcast_demuxer = SimulcastDemuxer.update(receiver.simulcast_demuxer, rtp_hdr_exts)
    track = %MediaStreamTrack{receiver.track | streams: stream_ids}

    layers =
      Map.new(receiver.layers, fn {rid, layer} ->
        report_recorder = %ReportRecorder{
          layer.report_recorder
          | clock_rate: codec && codec.clock_rate
        }

        {rid, %{layer | report_recorder: report_recorder}}
      end)

    %{
      receiver
      | codec: codec,
        codecs: codecs,
        simulcast_demuxer: simulcast_demuxer,
        layers: layers,
        track: track
    }
  end

  @doc false
  @spec receive_packet(receiver(), ExRTP.Packet.t(), non_neg_integer()) ::
          {:ok, String.t() | nil, receiver()} | {:error, receiver()}
  def receive_packet(receiver, packet, size) do
    packet_codec = Map.get(receiver.codecs, packet.payload_type)

    if packet_codec == nil do
      Logger.warning("""
      Received packet with unexpected payload_type \
      (received #{packet.payload_type}, expected #{inspect(Map.keys(receiver.codecs), charlists: :as_lists)})\
      """)
    end

    if packet_codec != nil and receiver.codec.clock_rate != packet_codec.clock_rate do
      Logger.warning("""
      Received packet with non-matching clock-rate. This can result \
      in incorrect jitter in RTCP reports. Expected: #{receiver.codec.clock_rate}, \
      received: #{packet_codec.clock_rate}\
      """)
    end

    {rid, simulcast_demuxer} = SimulcastDemuxer.demux_packet(receiver.simulcast_demuxer, packet)
    layer = receiver.layers[rid] || init_layer(receiver.codec)

    # we only turn off the actual recording when features are not on,
    # other stuff (like updating some metadata in the recorders etc)
    # does not meaningfully impact performance
    report_recorder =
      if receiver.reports? do
        ReportRecorder.record_packet(layer.report_recorder, packet)
      else
        layer.report_recorder
      end

    nack_generator =
      if receiver.inbound_rtx? do
        NACKGenerator.record_packet(layer.nack_generator, packet)
      else
        layer.nack_generator
      end

    layer = %{
      layer
      | ssrc: packet.ssrc,
        bytes_received: layer.bytes_received + size,
        packets_received: layer.packets_received + 1,
        markers_received: layer.markers_received + Utils.to_int(packet.marker),
        report_recorder: report_recorder,
        nack_generator: nack_generator
    }

    # TODO assign ssrc when applying local/remote description.
    receiver = %{
      receiver
      | layers: Map.put(receiver.layers, rid, layer),
        simulcast_demuxer: simulcast_demuxer
    }

    if packet_codec == nil do
      {:error, receiver}
    else
      {:ok, rid, receiver}
    end
  end

  @doc false
  @spec receive_rtx(receiver(), ExRTP.Packet.t(), non_neg_integer()) ::
          {:ok, ExRTP.Packet.t()} | :error
  def receive_rtx(receiver, packet, apt) do
    {rid, demuxer} = SimulcastDemuxer.demux_packet(receiver.simulcast_demuxer, packet, rtx?: true)

    with {:ok, layer} <- Map.fetch(receiver.layers, rid),
         ssrc when ssrc != nil <- layer.ssrc,
         <<seq_no::16, rest::binary>> <- packet.payload do
      # TODO remove rrid extension
      packet = %ExRTP.Packet{
        packet
        | ssrc: ssrc,
          sequence_number: seq_no,
          payload_type: apt,
          payload: rest
      }

      {:ok, packet, %{receiver | simulcast_demuxer: demuxer}}
    else
      _other -> :error
    end
  end

  @doc false
  @spec receive_report(receiver(), ExRTCP.Packet.SenderReport.t()) :: receiver()
  def receive_report(receiver, report) do
    rid = SimulcastDemuxer.demux_ssrc(receiver.simulcast_demuxer, report.ssrc)
    layer = receiver.layers[rid] || init_layer(receiver.codec)

    report_recorder = ReportRecorder.record_report(layer.report_recorder, report)
    layers = Map.put(receiver.layers, rid, %{layer | report_recorder: report_recorder})
    %{receiver | layers: layers}
  end

  @doc false
  @spec update_sender_ssrc(receiver(), non_neg_integer()) :: receiver()
  def update_sender_ssrc(receiver, ssrc) do
    layers =
      Map.new(receiver.layers, fn {rid, layer} ->
        report_recorder = %ReportRecorder{layer.report_recorder | sender_ssrc: ssrc}
        nack_generator = %NACKGenerator{layer.nack_generator | sender_ssrc: ssrc}
        %{layer | report_recorder: report_recorder, nack_generator: nack_generator}
        {rid, layer}
      end)

    %{receiver | layers: layers}
  end

  @doc false
  @spec get_reports(receiver()) :: {[ExRTCP.Packet.ReceiverReport.t()], receiver()}
  def get_reports(receiver) do
    {layers, reports} =
      Enum.map_reduce(receiver.layers, [], fn {rid, layer}, reports ->
        case ReportRecorder.get_report(layer.report_recorder) do
          {:ok, report, recorder} ->
            layer = %{layer | report_recorder: recorder}
            {{rid, layer}, [report | reports]}

          {:error, _res} ->
            {{rid, layer}, reports}
        end
      end)

    receiver = %{receiver | layers: Map.new(layers)}
    {reports, receiver}
  end

  @doc false
  @spec get_nacks(receiver()) :: {[NACK.t()], receiver()}
  def get_nacks(receiver) do
    {layers, nacks} =
      Enum.map_reduce(receiver.layers, [], fn {rid, layer}, nacks ->
        {nack, nack_generator} = NACKGenerator.get_feedback(layer.nack_generator)
        nacks = if(nack != nil, do: [nack | nacks], else: nacks)

        layer = %{
          layer
          | nack_generator: nack_generator,
            nack_count: layer.nack_count + if(nack != nil, do: 1, else: 0)
        }

        {{rid, layer}, nacks}
      end)

    receiver = %{receiver | layers: Map.new(layers)}
    {nacks, receiver}
  end

  @doc false
  @spec get_pli(receiver(), String.t() | nil) :: {PLI.t(), receiver()} | :error
  def get_pli(receiver, rid) do
    case receiver do
      %{layers: %{^rid => %{ssrc: ssrc} = layer}} when ssrc != nil ->
        layer = %{layer | pli_count: layer.pli_count + 1}
        pli = %PLI{sender_ssrc: 1, media_ssrc: ssrc}
        {pli, %{receiver | layers: Map.put(receiver.layers, rid, layer)}}

      _other ->
        :error
    end
  end

  @doc false
  @spec get_stats(receiver(), non_neg_integer()) :: [map()]
  def get_stats(receiver, timestamp) do
    Enum.map(receiver.layers, fn {rid, layer} ->
      id = if(rid == nil, do: receiver.track.id, else: "#{receiver.track.id}:#{rid}")
      codec = receiver.codec && String.split(receiver.codec.mime_type, "/") |> List.last()

      %{
        id: id,
        track_identifier: id,
        rid: rid,
        codec: codec,
        type: :inbound_rtp,
        timestamp: timestamp,
        ssrc: layer.ssrc,
        bytes_received: layer.bytes_received,
        packets_received: layer.packets_received,
        markers_received: layer.markers_received,
        nack_count: layer.nack_count,
        pli_count: layer.pli_count
      }
    end)
  end

  defp init_layer(codec) do
    report_recorder = %ReportRecorder{
      clock_rate: codec && codec.clock_rate
    }

    %{
      ssrc: nil,
      bytes_received: 0,
      packets_received: 0,
      markers_received: 0,
      report_recorder: report_recorder,
      nack_generator: %NACKGenerator{},
      nack_count: 0,
      pli_count: 0
    }
  end
end
