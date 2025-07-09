defmodule ExWebRTC.RTP.DepayloaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTPCodecParameters
  alias ExWebRTC.RTP.Depayloader

  @packet %ExRTP.Packet{
    payload_type: 96,
    sequence_number: 0,
    timestamp: 0,
    ssrc: 0,
    payload: <<0, 1, 2, 3>>
  }

  test "creates a VP8 depayloader and dispatches calls to its module" do
    assert {:ok, depayloader} =
             %RTPCodecParameters{payload_type: 96, mime_type: "video/VP8", clock_rate: 90_000}
             |> Depayloader.new()

    assert Depayloader.depayload(depayloader, @packet) ==
             Depayloader.VP8.depayload(depayloader, @packet)
  end

  test "creates an Opus depayloader and dispatches calls to its module" do
    assert {:ok, depayloader} =
             %RTPCodecParameters{
               payload_type: 96,
               mime_type: "audio/opus",
               clock_rate: 48_000,
               channels: 2
             }
             |> Depayloader.new()

    assert Depayloader.depayload(depayloader, @packet) ==
             Depayloader.Opus.depayload(depayloader, @packet)
  end

  test "creates a G711 depayloader and dispatches calls to its module" do
    assert {:ok, depayloader} =
             %RTPCodecParameters{
               payload_type: 0,
               mime_type: "audio/PCMU",
               clock_rate: 8000,
               channels: 1
             }
             |> Depayloader.new()

    assert Depayloader.depayload(depayloader, @packet) ==
             Depayloader.G711.depayload(depayloader, @packet)

    assert {:ok, depayloader} =
             %RTPCodecParameters{
               payload_type: 8,
               mime_type: "audio/PCMA",
               clock_rate: 8000,
               channels: 1
             }
             |> Depayloader.new()

    assert Depayloader.depayload(depayloader, @packet) ==
             Depayloader.G711.depayload(depayloader, @packet)
  end

  test "creates an DTMF depayloader and dispatches calls to its module" do
    assert {:ok, depayloader} =
             %RTPCodecParameters{
               payload_type: 110,
               mime_type: "audio/telephone-event",
               clock_rate: 8_000,
               channels: 1
             }
             |> Depayloader.new()

    assert Depayloader.depayload(depayloader, @packet) ==
             Depayloader.DTMF.depayload(depayloader, @packet)
  end

  test "creates a H264 depayloader and dispatches calls to its module" do
    assert {:ok, depayloader} =
             %RTPCodecParameters{payload_type: 97, mime_type: "video/H264", clock_rate: 90_000}
             |> Depayloader.new()

    assert Depayloader.depayload(depayloader, @packet) ==
             Depayloader.H264.depayload(depayloader, @packet)
  end
end
