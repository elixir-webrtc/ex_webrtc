defmodule ExWebRTC.RTP.VP8Depayloader do
  @moduledoc """
  Reassembles VP8 frames from RTP packets.

  Based on [RFC 7741: RTP Payload Format for VP8 Video](https://datatracker.ietf.org/doc/html/rfc7741)
  """
  require Logger

  alias ExWebRTC.RTP.VP8Payload

  @opaque t() :: %__MODULE__{
            current_frame: nil,
            current_timestamp: nil
          }

  defstruct [:current_frame, :current_timestamp]

  @spec new() :: t()
  def new() do
    %__MODULE__{}
  end

  @spec write(t(), ExRTP.Packet.t()) :: {:ok, t()} | {:ok, binary(), t()}
  def write(depayloader, packet) do
    with {:ok, vp8_payload} <- VP8Payload.parse(packet.payload) do
      depayloader =
        case {depayloader.current_frame, vp8_payload} do
          {nil, %VP8Payload{s: 1, pid: 0}} ->
            %{
              depayloader
              | current_frame: vp8_payload.payload,
                current_timestamp: packet.timestamp
            }

          {nil, _vp8_payload} ->
            Logger.debug("Dropping vp8 payload as it doesn't start a new frame")
            depayloader

          {_current_frame, %VP8Payload{s: 1, pid: 0}} ->
            Logger.debug("""
            Received packet that starts a new frame without finishing the previous frame. \
            Droping previous frame.\
            """)

            %{
              depayloader
              | current_frame: vp8_payload.payload,
                current_timestamp: packet.timestamp
            }

          _ when packet.timestamp != depayloader.current_timestamp ->
            Logger.debug("""
            Received packet with timestamp from a new frame that is not a beginning of this frame \
            and without finishing the previous frame. Droping both.\
            """)

            %{depayloader | current_frame: nil, current_timestamp: nil}

          {current_frame, vp8_payload} ->
            %{depayloader | current_frame: current_frame <> vp8_payload.payload}
        end

      case {depayloader.current_frame, packet.marker} do
        {current_frame, true} when current_frame != nil ->
          {:ok, current_frame, %{depayloader | current_frame: nil, current_timestamp: nil}}

        _ ->
          {:ok, depayloader}
      end
    end
  end
end
