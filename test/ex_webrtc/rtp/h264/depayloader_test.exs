defmodule ExWebRTC.RTP.H264.DepayloaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.Depayloader

  test "valid Single NAL Unit" do
    payload_single = <<53, 131>>
    payload_single_out = <<0, 0, 0, 1, 131>>

    depayloader = Depayloader.H264.new()
    packet = ExRTP.Packet.new(payload_single, timestamp: 123)

    assert {^payload_single_out, %{current_timestamp: 123}} =
             Depayloader.H264.depayload(depayloader, packet)
  end

  test "valid STAP-A NAL" do
    payload_stapa = <<56, 0, 1, 128, 0, 1, 129>>
    payload_stapa_out = <<0, 0, 0, 1, 128, 0, 0, 0, 1, 129>>

    depayloader = Depayloader.H264.new()
    packet = ExRTP.Packet.new(payload_stapa, timestamp: 123)

    assert {^payload_stapa_out, %{current_timestamp: 123}} =
             Depayloader.H264.depayload(depayloader, packet)
  end

  test "valid FU-A NAL" do
    payload_fuas = <<60, 133, 128>>
    payload_fua = <<60, 5, 129>>
    payload_fuae = <<60, 69, 130>>
    payload_fua_out = <<0, 0, 0, 1, 37, 128, 129, 130>>

    depayloader = Depayloader.H264.new()

    packet1 = ExRTP.Packet.new(payload_fuas, timestamp: 10)
    packet2 = ExRTP.Packet.new(payload_fua, timestamp: 10)
    packet3 = ExRTP.Packet.new(payload_fuae, timestamp: 10)

    {bin, depayloader} = Depayloader.H264.depayload(depayloader, packet1)

    assert {nil, %{current_timestamp: 10, fu_parser_acc: [<<128>>]}} =
             {bin, depayloader}

    {bin, depayloader} = Depayloader.H264.depayload(depayloader, packet2)

    assert {nil, %{current_timestamp: 10, fu_parser_acc: [<<129>>, <<128>>]}} =
             {bin, depayloader}

    assert {^payload_fua_out, %{current_timestamp: 10, fu_parser_acc: []}} =
             Depayloader.H264.depayload(depayloader, packet3)
  end

  test "colliding timestamps in one FU-A" do
    payload_fuas = <<60, 133, 128>>
    payload_fua = <<60, 5, 129>>

    depayloader = Depayloader.H264.new()

    packet1 = ExRTP.Packet.new(payload_fuas, timestamp: 10)
    packet2 = ExRTP.Packet.new(payload_fua, timestamp: 11)

    {bin, depayloader} = Depayloader.H264.depayload(depayloader, packet1)

    assert {nil, %{current_timestamp: 10, fu_parser_acc: [<<128>>]}} =
             {bin, depayloader}

    {bin, depayloader} = Depayloader.H264.depayload(depayloader, packet2)

    assert {nil, %{current_timestamp: nil, fu_parser_acc: []}} =
             {bin, depayloader}
  end

  test "starting new without ending previous FU-A" do
    payload_fuas1 = <<60, 133, 128>>
    payload_fuas2 = <<60, 133, 129>>

    depayloader = Depayloader.H264.new()

    packet1 = ExRTP.Packet.new(payload_fuas1, timestamp: 10)
    packet2 = ExRTP.Packet.new(payload_fuas2, timestamp: 10)

    {bin, depayloader} = Depayloader.H264.depayload(depayloader, packet1)

    assert {nil, %{current_timestamp: 10, fu_parser_acc: [<<128>>]}} =
             {bin, depayloader}

    {bin, depayloader} = Depayloader.H264.depayload(depayloader, packet2)

    assert {nil, %{current_timestamp: nil, fu_parser_acc: []}} =
             {bin, depayloader}
  end

  test "non-start packet without starting FU-A beforehand" do
    payload_fua = <<60, 5, 128>>

    depayloader = Depayloader.H264.new()

    packet = ExRTP.Packet.new(payload_fua, timestamp: 10)

    assert {nil, %{current_timestamp: nil, fu_parser_acc: []}} =
             Depayloader.H264.depayload(depayloader, packet)
  end

  test "non-fragmented FU-A (start and end bits set to 1)" do
    payload_fua = <<60, 197, 129>>

    depayloader = Depayloader.H264.new()

    packet = ExRTP.Packet.new(payload_fua, timestamp: 10)

    assert {nil, %{current_timestamp: nil, fu_parser_acc: []}} =
             Depayloader.H264.depayload(depayloader, packet)
  end

  test "all unsupported NAL types" do
    # reserved (22, 23, 30, 31) and unsupported NALu types (STAP-B: 25, MTAP-16: 26, MTAP-24: 27, FU-B: 29)
    payloads_nalu_unsupported = [
      <<54, 131>>,
      <<55, 131>>,
      <<62, 131>>,
      <<63, 131>>,
      <<57, 131>>,
      <<58, 131>>,
      <<59, 131>>,
      <<61, 131>>
    ]

    depayloader = Depayloader.H264.new()

    Enum.map(payloads_nalu_unsupported, fn payload ->
      packet = ExRTP.Packet.new(payload, timestamp: 123)

      assert {nil, %{current_timestamp: nil, fu_parser_acc: []}} =
               Depayloader.H264.depayload(depayloader, packet)
    end)
  end

  test "empty RTP payload" do
    payload_empty = <<>>

    depayloader = Depayloader.H264.new()
    packet = ExRTP.Packet.new(payload_empty, timestamp: 123)

    assert {nil, %{current_timestamp: nil, fu_parser_acc: []}} =
             Depayloader.H264.depayload(depayloader, packet)
  end

  test "malformed NAL" do
    # forbidden zero bit set to 1
    payload_invalid = <<181, 0>>

    depayloader = Depayloader.H264.new()
    packet = ExRTP.Packet.new(payload_invalid, timestamp: 123)

    assert {nil, %{current_timestamp: nil, fu_parser_acc: []}} =
             Depayloader.H264.depayload(depayloader, packet)
  end

  test "malformed STAP-A" do
    # malformed STAP-A payload. First NAL should be 1-byte long, but is 2-bytes long
    payload_invalid = <<56, 0, 1, 128, 12, 0, 1, 129>>

    depayloader = Depayloader.H264.new()
    packet = ExRTP.Packet.new(payload_invalid, timestamp: 123)

    assert {nil, %{current_timestamp: nil, fu_parser_acc: []}} =
             Depayloader.H264.depayload(depayloader, packet)
  end
end
