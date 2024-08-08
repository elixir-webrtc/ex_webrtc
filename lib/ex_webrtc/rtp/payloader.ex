defmodule ExWebRTC.RTP.Payloader do
  @moduledoc """
  Behaviour for ExWebRTC Payloaders.
  """

  alias ExWebRTC.RTPCodecParameters

  @type payloader :: struct()

  @doc """
  Creates a new payloader struct.

  Refer to the modules implementing the behaviour for available options.
  """
  @callback new(options :: any()) :: payloader()

  @doc """
  Packs a frame into one or more RTP packets.

  Returns the packets together with the updated payloader struct.
  """
  @callback payload(payloader(), frame :: binary()) :: {[ExRTP.Packet.t()], payloader()}

  @doc """
  TODO WRITEME
  """
  @spec new(RTPCodecParameters.t(), any()) ::
          {:ok, payloader()} | {:error, :no_payloader_for_codec}
  def new(codec_params, options \\ nil) do
    with {:ok, module} <- match_payloader_module(codec_params.mime_type) do
      payloader = if is_nil(options), do: module.new(), else: module.new(options)

      {:ok, payloader}
    end
  end

  @doc """
  TODO WRITEME
  """
  @spec payload(payloader(), binary()) :: {[ExRTP.Packet.t()], payloader()}
  def payload(%module{} = payloader, frame) do
    module.payload(payloader, frame)
  end

  defp match_payloader_module(mime_type) do
    case String.downcase(mime_type) do
      "video/vp8" -> {:ok, ExWebRTC.RTP.VP8.Payloader}
      "audio/opus" -> {:ok, ExWebRTC.RTP.Opus.Payloader}
      _other -> {:error, :no_payloader_for_codec}
    end
  end
end
