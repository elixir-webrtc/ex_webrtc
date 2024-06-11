defmodule ExWebRTC.RTPReceiver do
  @moduledoc """
  Implementation of the [RTCRtpReceiver](https://www.w3.org/TR/webrtc/#rtcrtpreceiver-interface).
  """

  require Logger

  alias ExWebRTC.{MediaStreamTrack, Utils, RTPCodecParameters}
  alias __MODULE__.{NACKGenerator, ReportRecorder}

  @type id() :: integer()

  @typedoc false
  @type receiver() :: %{
          id: id(),
          track: MediaStreamTrack.t(),
          codec: RTPCodecParameters.t() | nil,
          ssrc: non_neg_integer() | nil,
          bytes_received: non_neg_integer(),
          packets_received: non_neg_integer(),
          markers_received: non_neg_integer(),
          report_recorder: ReportRecorder.t(),
          nack_generator: NACKGenerator.t()
        }

  @typedoc """
  Struct representing a receiver.

  The fields mostly match these of [RTCRtpReceiver](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpReceiver),
  except for:
  * `id` - to uniquely identify the receiver.
  * `codec` - codec this receiver is expected to receive.
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
  @spec new(MediaStreamTrack.t(), RTPCodecParameters.t() | nil) :: receiver()
  def new(track, codec) do
    report_recorder = %ReportRecorder{
      clock_rate: codec && codec.clock_rate
    }

    %{
      id: Utils.generate_id(),
      track: track,
      codec: codec,
      ssrc: nil,
      bytes_received: 0,
      packets_received: 0,
      markers_received: 0,
      report_recorder: report_recorder,
      nack_generator: %NACKGenerator{}
    }
  end

  @doc false
  @spec update(receiver(), RTPCodecParameters.t() | nil, [String.t()]) :: receiver()
  def update(receiver, codec, stream_ids) do
    report_recorder = %ReportRecorder{
      receiver.report_recorder
      | clock_rate: codec && codec.clock_rate
    }

    track = %MediaStreamTrack{receiver.track | streams: stream_ids}

    %{receiver | codec: codec, track: track, report_recorder: report_recorder}
  end

  @doc false
  @spec receive_packet(receiver(), ExRTP.Packet.t(), non_neg_integer()) :: receiver()
  def receive_packet(receiver, packet, size) do
    if packet.payload_type != receiver.codec.payload_type do
      Logger.warning("Received packet with unexpected payload_type \
(received #{packet.payload_type}, expected #{receiver.codec.payload_type})")
    end

    report_recorder = ReportRecorder.record_packet(receiver.report_recorder, packet)
    nack_generator = NACKGenerator.record_packet(receiver.nack_generator, packet)

    # TODO assign ssrc when applying local/remote description.
    %{
      receiver
      | ssrc: packet.ssrc,
        bytes_received: receiver.bytes_received + size,
        packets_received: receiver.packets_received + 1,
        markers_received: receiver.markers_received + Utils.to_int(packet.marker),
        report_recorder: report_recorder,
        nack_generator: nack_generator
    }
  end

  @spec receive_rtx(receiver(), ExRTP.Packet.t(), non_neg_integer()) ::
          {:ok, ExRTP.Packet.t()} | :error
  def receive_rtx(receiver, rtx_packet, apt) do
    with <<seq_no::16, rest::binary>> <- rtx_packet.payload,
         ssrc when ssrc != nil <- receiver.ssrc do
      packet = %ExRTP.Packet{
        rtx_packet
        | ssrc: ssrc,
          sequence_number: seq_no,
          payload_type: apt,
          payload: rest
      }

      {:ok, packet}
    else
      _other -> :error
    end
  end

  @spec receive_report(receiver(), ExRTCP.Packet.SenderReport.t()) :: receiver()
  def receive_report(receiver, report) do
    report_recorder = ReportRecorder.record_report(receiver.report_recorder, report)

    %{receiver | report_recorder: report_recorder}
  end

  @doc false
  @spec update_sender_ssrc(receiver(), non_neg_integer()) :: receiver()
  def update_sender_ssrc(receiver, ssrc) do
    report_recorder = %ReportRecorder{receiver.report_recorder | sender_ssrc: ssrc}
    nack_generator = %NACKGenerator{receiver.nack_generator | sender_ssrc: ssrc}

    %{receiver | report_recorder: report_recorder, nack_generator: nack_generator}
  end

  @doc false
  @spec get_stats(receiver(), non_neg_integer()) :: map()
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
