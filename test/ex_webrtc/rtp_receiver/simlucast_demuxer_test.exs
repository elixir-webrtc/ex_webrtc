defmodule ExWebRTC.RTPReceiver.SimulcastDemuxerTest do
  use ExUnit.Case, async: true

  alias ExRTP.Packet
  alias ExRTP.Packet.Extension
  alias ExWebRTC.RTPReceiver.SimulcastDemuxer
  alias ExSDP.Attribute.Extmap

  @rid "h"
  @rrid "l"

  @ssrc 333_333
  @packet %Packet{
    payload_type: 96,
    sequence_number: 5,
    timestamp: 0,
    ssrc: @ssrc,
    payload: <<>>
  }

  @packet_rid Packet.add_extension(@packet, %Extension{id: 10, data: @rid})
  @packet_rrid Packet.add_extension(@packet, %Extension{id: 11, data: @rrid})

  @extmaps [
    %Extmap{id: 10, uri: "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"},
    %Extmap{id: 11, uri: "urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id"}
  ]

  setup do
    assert %SimulcastDemuxer{} = demuxer = SimulcastDemuxer.new(@extmaps)
    %{demuxer: demuxer}
  end

  test "demux_packet/3", %{demuxer: demuxer} do
    assert {nil, demuxer} = SimulcastDemuxer.demux_packet(demuxer, @packet)
    assert {@rid, demuxer} = SimulcastDemuxer.demux_packet(demuxer, @packet_rid)
    assert {@rid, demuxer} = SimulcastDemuxer.demux_packet(demuxer, @packet)

    # different ssrc
    ssrc = 111_111
    assert {@rid, demuxer} = SimulcastDemuxer.demux_packet(demuxer, %{@packet_rid | ssrc: ssrc})
    assert {@rid, demuxer} = SimulcastDemuxer.demux_packet(demuxer, %{@packet | ssrc: ssrc})

    # rrid
    ssrc = 111_222
    assert {nil, demuxer} = SimulcastDemuxer.demux_packet(demuxer, %{@packet_rrid | ssrc: ssrc})

    assert {@rrid, _demuxer} =
             SimulcastDemuxer.demux_packet(demuxer, %{@packet_rrid | ssrc: ssrc}, rtx?: true)
  end

  test "demux_ssrc/2", %{demuxer: demuxer} do
    assert {@rid, demuxer} = SimulcastDemuxer.demux_packet(demuxer, @packet_rid)
    assert @rid == SimulcastDemuxer.demux_ssrc(demuxer, @ssrc)
  end
end
