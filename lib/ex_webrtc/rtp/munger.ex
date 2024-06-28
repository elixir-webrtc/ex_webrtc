defmodule ExWebRTC.RTP.Munger do
  @moduledoc """
  RTP Munger.
  """

  alias ExRTP.Packet

  @max_rtp_ts 0xFFFFFFFF
  @max_rtp_sn 0xFFFF
  @breakpoint 0x7FFF

  @typedoc """
  Fields:
  * `clock_rate` - clock rate of the codec
  * `rtp_sn` - highest sequence number of a previously munged packet
  * `rtp_ts` - timestamp of the packet with `rtp_sn`
  * `wc_ts` - "wallclock" (absolute) timestamp of the packet with `rtp_sn`
  * `sn_offset` - offset for sequence numbers
  * `ts_offset` - offset for timestamps
  * `update?` - flag telling if the next munged packets belongs to a new encoding
  """
  @type t() :: %__MODULE__{
          clock_rate: non_neg_integer(),
          rtp_sn: non_neg_integer() | nil,
          rtp_ts: non_neg_integer() | nil,
          wc_ts: integer() | nil,
          sn_offset: integer(),
          ts_offset: integer(),
          update?: boolean()
        }

  @enforce_keys [:clock_rate]
  defstruct [
              :rtp_sn,
              :rtp_ts,
              :wc_ts,
              sn_offset: 0,
              ts_offset: 0,
              update?: false
            ] ++ @enforce_keys

  @spec new(non_neg_integer()) :: t()
  def new(clock_rate) do
    %__MODULE__{clock_rate: clock_rate}
  end

  @spec update(t()) :: t()
  def update(munger), do: %__MODULE__{munger | update?: true}

  @spec munge(t(), Packet.t()) :: {Packet.t(), t()}
  def munge(%{rtp_sn: nil} = munger, packet) do
    # first packet ever munged
    munger = %__MODULE__{
      munger
      | rtp_sn: packet.sequence_number,
        rtp_ts: packet.timestamp,
        wc_ts: get_wc_ts(packet)
    }

    {packet, munger}
  end

  def munge(munger, packet) when munger.update? do
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
        update?: false
    }

    {new_packet, munger}
  end

  def munge(munger, packet) do
    # we should ignore packets with sequence number smaller than
    # the first packet after the encoding update
    # as these might conflict with packets from the previous layer
    # and we should change on a keyframe anyways
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
            wc_ts: wc_ts
        }
      else
        munger
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
