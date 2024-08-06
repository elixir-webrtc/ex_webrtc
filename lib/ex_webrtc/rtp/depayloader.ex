defmodule ExWebRTC.RTP.Depayloader do
  @moduledoc """
  Behaviour for ExWebRTC Depayloaders.
  """

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
end
