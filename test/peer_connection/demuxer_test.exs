defmodule ExWebRTC.PeerConnection.DemuxerTest do
  use ExUnit.Case, async: true

  alias ExRTP.Packet
  alias ExRTP.Packet.Extension
  alias ExWebRTC.PeerConnection.Demuxer

  @mid "1"

  @sequence_number 500
  @payload_type 111
  @ssrc 333_333
  @raw_packet %Packet{
    payload_type: @payload_type,
    sequence_number: @sequence_number,
    timestamp: 0,
    ssrc: @ssrc,
    payload: <<>>
  }

  @packet Packet.encode(@raw_packet)
  @packet_mid Packet.encode(
                Packet.set_extension(@raw_packet, :two_byte, [%Extension{id: 15, data: @mid}])
              )
  @demuxer %Demuxer{extensions: %{15 => {Extension.SourceDescription, :mid}}}

  test "ssrc already mapped and, without extension" do
    seq_num = 1
    demuxer = %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => {@mid, seq_num}}}

    assert {:ok, new_demuxer, @mid, _packet} = Demuxer.process_data(demuxer, @packet)
    assert new_demuxer == %Demuxer{demuxer | ssrc_to_mid: %{@ssrc => {@mid, seq_num}}}
  end

  test "ssrc already mapped, with extension with the same mid and bigger sequence number" do
    demuxer = %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => {@mid, 1}}}

    assert {:ok, new_demuxer, @mid, _packet} = Demuxer.process_data(demuxer, @packet_mid)
    assert new_demuxer == %Demuxer{demuxer | ssrc_to_mid: %{@ssrc => {@mid, @sequence_number}}}
  end

  test "ssrc already mapped, with extension with new mid and smaller sequence number" do
    seq_num = 600
    mid = "2"
    demuxer = %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => {mid, seq_num}}}

    assert {:ok, new_demuxer, ^mid, _packet} = Demuxer.process_data(demuxer, @packet_mid)
    assert new_demuxer == %Demuxer{demuxer | ssrc_to_mid: %{@ssrc => {mid, seq_num}}}
  end

  test "ssrc already mapped, with extension with new mid and bigger sequence number" do
    seq_num = 1
    mid = "2"
    demuxer = %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => {mid, seq_num}}}

    assert {:ok, new_demuxer, @mid, _packet} = Demuxer.process_data(demuxer, @packet_mid)
    assert new_demuxer == %Demuxer{demuxer | ssrc_to_mid: %{@ssrc => {@mid, @sequence_number}}}
  end

  test "ssrc not mapped, with extension" do
    assert {:ok, new_demuxer, @mid, _packet} = Demuxer.process_data(@demuxer, @packet_mid)
    assert new_demuxer == %Demuxer{@demuxer | ssrc_to_mid: %{@ssrc => {@mid, @sequence_number}}}
  end

  test "ssrc not mapped, without extension, with unique payload type" do
    mid = "2"
    demuxer = %Demuxer{@demuxer | pt_to_mid: %{@payload_type => mid}}

    assert {:ok, new_demuxer, ^mid, _packet} = Demuxer.process_data(demuxer, @packet)
    assert new_demuxer == %Demuxer{demuxer | ssrc_to_mid: %{@ssrc => {mid, @sequence_number}}}
  end

  test "unmatchable ssrc" do
    assert :error = Demuxer.process_data(@demuxer, @packet)
  end
end
