defmodule ExWebRTC.RTP.PayloaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTPCodecParameters
  alias ExWebRTC.RTP.Payloader

  @frame <<0, 1, 2, 3>>
  @av1_temporal_unit <<0::1, 2::4, 0::3>>

  test "creates a VP8 payloader and dispatches calls to its module" do
    assert {:ok, _payloader} =
             %RTPCodecParameters{payload_type: 96, mime_type: "video/VP8", clock_rate: 90_000}
             |> Payloader.new()

    # with options
    assert {:ok, payloader} =
             %RTPCodecParameters{payload_type: 96, mime_type: "video/VP8", clock_rate: 90_000}
             |> Payloader.new(max_payload_size: 800)

    assert Payloader.payload(payloader, @frame) == Payloader.VP8.payload(payloader, @frame)
  end

  test "creates an AV1 payloader and dispatches calls to its module" do
    assert {:ok, payloader} =
             %RTPCodecParameters{payload_type: 45, mime_type: "video/AV1", clock_rate: 90_000}
             |> Payloader.new()

    assert Payloader.payload(payloader, @av1_temporal_unit) ==
             Payloader.AV1.payload(payloader, @av1_temporal_unit)

    # The sample frame is not a valid AV1 temporal unit
    assert_raise RuntimeError, fn -> Payloader.payload(payloader, @frame) end
  end

  test "creates an Opus payloader and dispatches calls to its module" do
    assert {:ok, payloader} =
             %RTPCodecParameters{
               payload_type: 111,
               mime_type: "audio/opus",
               clock_rate: 48_000,
               channels: 2
             }
             |> Payloader.new()

    assert Payloader.payload(payloader, @frame) == Payloader.Opus.payload(payloader, @frame)
  end

  test "creates a G711 payloader and dispatches calls to its module" do
    assert {:ok, payloader} =
             %RTPCodecParameters{
               payload_type: 0,
               mime_type: "audio/PCMU",
               clock_rate: 8000,
               channels: 1
             }
             |> Payloader.new()

    assert Payloader.payload(payloader, @frame) == Payloader.G711.payload(payloader, @frame)

    assert {:ok, payloader} =
             %RTPCodecParameters{
               payload_type: 8,
               mime_type: "audio/PCMA",
               clock_rate: 8000,
               channels: 1
             }
             |> Payloader.new()

    assert Payloader.payload(payloader, @frame) == Payloader.G711.payload(payloader, @frame)
  end

  test "returns error if no payloader exists for given codec" do
    assert {:error, :no_payloader_for_codec} =
             %RTPCodecParameters{payload_type: 97, mime_type: "video/H264", clock_rate: 90_000}
             |> Payloader.new()
  end
end
