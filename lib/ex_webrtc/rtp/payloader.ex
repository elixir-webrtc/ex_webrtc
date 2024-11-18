defmodule ExWebRTC.RTP.Payloader do
  @moduledoc """
  RTP payloader.

  It packs audio/video frames into one or more RTP packets.
  """

  alias ExWebRTC.RTPCodecParameters

  @opaque payloader :: struct()

  @doc """
  Creates a new payloader that matches the passed codec parameters.

  Opts:
    * max_payload_size - determines the maximum size of a single RTP packet outputted by the payloader.
    It must be greater than `100`, and is set to `1000` by default.
  """
  @spec new(RTPCodecParameters.t(), max_payload_size: integer()) ::
          {:ok, payloader()} | {:error, :no_payloader_for_codec}
  def new(codec_params, opts \\ []) do
    with {:ok, module} <- to_payloader_module(codec_params.mime_type) do
      max_payload_size = opts[:max_payload_size] || 1000
      payloader = module.new(max_payload_size)
      {:ok, payloader}
    end
  end

  @doc """
  Packs a frame into one or more RTP packets.

  Returns the packets together with the updated payloader.
  """
  @spec payload(payloader(), binary()) :: {[ExRTP.Packet.t()], payloader()}
  def payload(%module{} = payloader, frame) do
    module.payload(payloader, frame)
  end

  defp to_payloader_module(mime_type) do
    case String.downcase(mime_type) do
      "video/vp8" -> {:ok, ExWebRTC.RTP.Payloader.VP8}
      "audio/opus" -> {:ok, ExWebRTC.RTP.Payloader.Opus}
      "audio/pcma" -> {:ok, ExWebRTC.RTP.Payloader.G711}
      "audio/pcmu" -> {:ok, ExWebRTC.RTP.Payloader.G711}
      _other -> {:error, :no_payloader_for_codec}
    end
  end
end
