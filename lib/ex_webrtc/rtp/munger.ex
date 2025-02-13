defmodule ExWebRTC.RTP.Munger do
  @moduledoc """
  RTP Munger allows for converting RTP packet timestamps and sequence numbers
  to a common domain.
  It also rewrites parts of the RTP payload that may require a similar behaviour.

  This is useful when e.g. changing between Simulcast layers - the sender sends
  three separate RTP streams (also called layers or encodings), but the receiver can receive only a
  single RTP stream.

  ```
  # assume you receive two layers: "h" (high) and "l" (low)
  # and this is a GenServer

  def init() do
    {:ok, %{munger: Munger.new(:h264, 90_000), layer: "h"}}
  end

  def handle_info({:ex_webrtc, _from, {:rtp, _id, rid, packet}}, state) do
    if rid == state.layer do
      {packet, munger} = Munger.munge(state.munger, packet)
      send_packet_somewhere(packet)
      {:noreply, %{state | munger: munger}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:change_layer, layer}, state) do
    # indicate to the munger that the next packet will be from a new layer
    munger = Munger.update(state.munger)
    {:noreply, %{munger: munger, layer: layer}
  end
  ```
  """

  alias ExRTP.Packet
  alias ExWebRTC.RTPCodecParameters
  alias ExWebRTC.RTP.VP8

  @max_rtp_ts 0xFFFFFFFF
  @max_rtp_sn 0xFFFF
  @breakpoint 0x7FFF

  # Fields:
  # * `clock_rate` - clock rate of the codec
  # * `rtp_sn` - highest sequence number of a previously munged packet
  # * `rtp_ts` - timestamp of the packet with `rtp_sn`
  # * `wc_ts` - "wallclock" (absolute) timestamp of the packet with `rtp_sn`
  # * `sn_offset` - offset for sequence numbers
  # * `ts_offset` - offset for timestamps
  # * `update?` - flag telling if the next munged packets belongs to a new encoding
  # * `vp8_munger` - VP8 munger, only used when RTP packets contain VP8 codec
  @opaque t() :: %__MODULE__{
            clock_rate: non_neg_integer(),
            rtp_sn: non_neg_integer() | nil,
            rtp_ts: non_neg_integer() | nil,
            wc_ts: integer() | nil,
            sn_offset: integer(),
            ts_offset: integer(),
            update?: boolean(),
            vp8_munger: VP8.Munger.t() | nil
          }

  @enforce_keys [:clock_rate]
  defstruct [
              :rtp_sn,
              :rtp_ts,
              :wc_ts,
              sn_offset: 0,
              ts_offset: 0,
              update?: false,
              vp8_munger: nil
            ] ++ @enforce_keys

  @doc """
  Creates a new `t:ExWebRTC.RTP.Munger.t/0`.

  `clock_rate` is the clock rate of the codec carried in munged RTP packets.
  """
  @spec new(:h264 | :vp8 | RTPCodecParameters.t(), non_neg_integer()) :: t()
  def new(:h264, clock_rate) do
    %__MODULE__{clock_rate: clock_rate}
  end

  def new(:vp8, clock_rate) do
    %__MODULE__{clock_rate: clock_rate, vp8_munger: VP8.Munger.new()}
  end

  def new(%RTPCodecParameters{} = codec_params) do
    case codec_params.mime_type do
      "video/H264" -> new(:h264, codec_params.clock_rate)
      "video/VP8" -> new(:vp8, codec_params.clock_rate)
    end
  end

  @doc """
  Informs the munger that the next packet passed to `munge/2` will come
  from a different RTP stream.
  """
  @spec update(t()) :: t()
  def update(munger), do: %__MODULE__{munger | update?: true}

  @doc """
  Updates the RTP packet to match the common timestamp/sequence number domain.
  """
  @spec munge(t(), Packet.t()) :: {Packet.t(), t()}
  def munge(%{rtp_sn: nil} = munger, packet) do
    # first packet ever munged
    vp8_munger = munger.vp8_munger && VP8.Munger.init(munger.vp8_munger, packet.payload)

    munger = %__MODULE__{
      munger
      | rtp_sn: packet.sequence_number,
        rtp_ts: packet.timestamp,
        wc_ts: get_wc_ts(packet),
        vp8_munger: vp8_munger
    }

    {packet, munger}
  end

  def munge(munger, packet) when munger.update? do
    {vp8_munger, rtp_payload} =
      if munger.vp8_munger do
        vp8_munger = VP8.Munger.update(munger.vp8_munger, packet.payload)
        VP8.Munger.munge(vp8_munger, packet.payload)
      else
        {munger.vp8_munger, packet.payload}
      end

    packet = %ExRTP.Packet{packet | payload: rtp_payload}

    wc_ts = get_wc_ts(packet)

    native_in_sec = System.convert_time_unit(1, :second, :native)

    # max(1, diff), in case the last packet from previous encoding and the first one
    # from the new encoding have (almost) the same arrival timestamp
    rtp_ts_diff =
      ((wc_ts - munger.wc_ts) * munger.clock_rate / native_in_sec)
      |> round()
      |> max(1)

    ts_offset = packet.timestamp - munger.rtp_ts - rtp_ts_diff
    sn_offset = packet.sequence_number - munger.rtp_sn - 1

    munger = %__MODULE__{munger | ts_offset: ts_offset, sn_offset: sn_offset}

    new_packet = adjust_packet(munger, packet)

    munger = %__MODULE__{
      munger
      | rtp_sn: new_packet.sequence_number,
        rtp_ts: new_packet.timestamp,
        wc_ts: wc_ts,
        update?: false,
        vp8_munger: vp8_munger
    }

    {new_packet, munger}
  end

  def munge(munger, packet) do
    # we should ignore packets with sequence number smaller than
    # the first packet after the encoding update
    # as these might conflict with packets from the previous layer
    # and we should change on a keyframe anyways
    {vp8_munger, rtp_payload} =
      if munger.vp8_munger do
        VP8.Munger.munge(munger.vp8_munger, packet.payload)
      else
        {munger.vp8_munger, packet.payload}
      end

    packet = %ExRTP.Packet{packet | payload: rtp_payload}

    wc_ts = get_wc_ts(packet)

    new_packet = adjust_packet(munger, packet)

    delta = new_packet.sequence_number - munger.rtp_sn
    in_order? = delta < -@breakpoint or (delta > 0 and delta < @breakpoint)

    munger =
      if in_order? do
        %__MODULE__{
          munger
          | rtp_sn: new_packet.sequence_number,
            rtp_ts: new_packet.timestamp,
            wc_ts: wc_ts,
            vp8_munger: vp8_munger
        }
      else
        %__MODULE__{munger | vp8_munger: vp8_munger}
      end

    {new_packet, munger}
  end

  defp get_wc_ts(_packet) do
    # TODO:
    # we should use NTP ts + RTP ts combination from RTCP sender reports
    # and corelate them to this packet's timestamp
    # for the sake of simplicity, for now we just do that
    System.monotonic_time()
  end

  defp adjust_packet(munger, packet) do
    rtp_ts = apply_offset(packet.timestamp, munger.ts_offset, @max_rtp_ts)
    rtp_sn = apply_offset(packet.sequence_number, munger.sn_offset, @max_rtp_sn)

    %Packet{packet | sequence_number: rtp_sn, timestamp: rtp_ts}
  end

  defp apply_offset(value, offset, max) do
    rem(value + max - offset + 1, max + 1)
  end
end
