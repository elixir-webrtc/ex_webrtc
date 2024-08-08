defmodule ExWebRTC.RTP.Depayloader do
  @moduledoc """
  Behaviour for ExWebRTC Depayloaders.
  """

  alias ExWebRTC.RTPCodecParameters

  @type depayloader :: struct()

  @doc """
  Creates a new depayloader struct.

  Refer to the modules implementing the behaviour for available options.
  """
  @callback new(options :: any()) :: depayloader()

  @doc """
  Processes binary data from a single RTP packet, and outputs a frame if assembled.

  Returns the frame (or `nil` if a frame could not be depayloaded yet)
  together with the updated depayloader struct.
  """
  @callback depayload(depayloader(), packet :: ExRTP.Packet.t()) ::
              {binary() | nil, depayloader()}

  @doc """
  TODO WRITEME
  """
  @spec new(RTPCodecParameters.t(), any()) ::
          {:ok, depayloader()} | {:error, :no_depayloader_for_codec}
  def new(codec_params, options \\ nil) do
    with {:ok, module} <- match_depayloader_module(codec_params.mime_type) do
      depayloader = if is_nil(options), do: module.new(), else: module.new(options)

      {:ok, depayloader}
    end
  end

  @doc """
  TODO WRITEME
  """
  @spec depayload(depayloader(), ExRTP.Packet.t()) :: {binary() | nil, depayloader()}
  def depayload(%module{} = depayloader, packet) do
    module.depayload(depayloader, packet)
  end

  defp match_depayloader_module(mime_type) do
    case String.downcase(mime_type) do
      "video/vp8" -> {:ok, ExWebRTC.RTP.VP8.Depayloader}
      "audio/opus" -> {:ok, ExWebRTC.RTP.Opus.Depayloader}
      _other -> {:error, :no_depayloader_for_codec}
    end
  end
end
