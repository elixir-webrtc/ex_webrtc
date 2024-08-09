defmodule ExWebRTC.RTP.Depayloader do
  @moduledoc """
  RTP depayloader.

  It unpacks RTP packets into audio/video frames.
  """

  alias ExWebRTC.RTPCodecParameters

  @opaque depayloader :: struct()

  @doc """
  Creates a new depayloader that matches the passed codec parameters.
  """
  @spec new(RTPCodecParameters.t()) ::
          {:ok, depayloader()} | {:error, :no_depayloader_for_codec}
  def new(codec_params) do
    with {:ok, module} <- to_depayloader_module(codec_params.mime_type) do
      depayloader = module.new()
      {:ok, depayloader}
    end
  end

  @doc """
  Processes binary data from a single RTP packet, and outputs a frame if assembled.

  Returns the frame (or `nil` if a frame could not be depayloaded yet)
  together with the updated depayloader.
  """
  @spec depayload(depayloader(), ExRTP.Packet.t()) :: {binary() | nil, depayloader()}
  def depayload(%module{} = depayloader, packet) do
    module.depayload(depayloader, packet)
  end

  defp to_depayloader_module(mime_type) do
    case String.downcase(mime_type) do
      "video/vp8" -> {:ok, ExWebRTC.RTP.Depayloader.VP8}
      "audio/opus" -> {:ok, ExWebRTC.RTP.Depayloader.Opus}
      _other -> {:error, :no_depayloader_for_codec}
    end
  end
end
