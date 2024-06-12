defmodule ExWebRTC.PeerConnection.DemuxerTest do
  use ExUnit.Case, async: true

  alias ExRTP.Packet
  alias ExRTP.Packet.Extension
  alias ExWebRTC.PeerConnection.Demuxer

  @mid "1"

  @payload_type 111
  @ssrc 333_333
  @packet %Packet{
    payload_type: @payload_type,
    sequence_number: 5,
    timestamp: 0,
    ssrc: @ssrc,
    payload: <<>>
  }

  @packet_mid Packet.add_extension(@packet, %Extension{id: 15, data: @mid})

  @demuxer %Demuxer{mid_ext_id: 15}

  describe "demux_packet/2" do
    test "ssrc already mapped, without extension" do
      demuxer = %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => @mid}}

      assert {:ok, @mid, new_demuxer} = Demuxer.demux_packet(demuxer, @packet)
      assert new_demuxer == %Demuxer{demuxer | ssrc_to_mid: %{@ssrc => @mid}}
    end

    test "ssrc already mapped, with extension with the same mid" do
      demuxer = %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => @mid}}

      assert {:ok, @mid, new_demuxer} = Demuxer.demux_packet(demuxer, @packet_mid)
      assert new_demuxer == %Demuxer{demuxer | ssrc_to_mid: %{@ssrc => @mid}}
    end

    test "ssrc already mapped, with extension with different mid" do
      demuxer = %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => "other"}}

      assert_raise(RuntimeError, fn -> Demuxer.demux_packet(demuxer, @packet_mid) end)
    end

    test "ssrc not mapped, with extension" do
      assert {:ok, @mid, new_demuxer} = Demuxer.demux_packet(@demuxer, @packet_mid)
      assert new_demuxer == %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => @mid}}
    end

    test "ssrc not mapped, without extension, with unique payload type" do
      demuxer = %Demuxer{@demuxer | pt_to_mid: %{@payload_type => @mid}}

      assert {:ok, @mid, new_demuxer} = Demuxer.demux_packet(demuxer, @packet)
      assert new_demuxer == %Demuxer{demuxer | ssrc_to_mid: %{@ssrc => @mid}}
    end

    test "unmatchable ssrc" do
      assert :error = Demuxer.demux_packet(@demuxer, @packet)
    end
  end

  test "demux_ssrc/2" do
    assert :error = Demuxer.demux_ssrc(@demuxer, @ssrc)
    demuxer = %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => @mid}}
    assert {:ok, @mid} = Demuxer.demux_ssrc(demuxer, @ssrc)
  end
end
