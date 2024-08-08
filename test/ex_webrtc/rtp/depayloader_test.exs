defmodule ExWebRTC.RTP.DepayloaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTPCodecParameters
  alias ExWebRTC.RTP.Depayloader
  alias ExWebRTC.RTP.{Opus, VP8}

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
             VP8.Depayloader.depayload(depayloader, @packet)
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
             Opus.Depayloader.depayload(depayloader, @packet)
  end

  test "returns error if no depayloader exists for given codec" do
    assert {:error, :no_depayloader_for_codec} =
             %RTPCodecParameters{payload_type: 97, mime_type: "video/H264", clock_rate: 90_000}
             |> Depayloader.new()
  end
end
