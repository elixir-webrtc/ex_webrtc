defmodule ExWebRTC.RTP.Depayloader.VP8 do
  @moduledoc false
  # Reassembles VP8 frames from RTP packets.
  #
  # Based on [RFC 7741: RTP Payload Format for VP8 Video](https://datatracker.ietf.org/doc/html/rfc7741).

  @behaviour ExWebRTC.RTP.Depayloader.Behaviour

  require Logger

  alias ExWebRTC.RTP.VP8.Payload

  @type t() :: %__MODULE__{
          current_frame: nil,
          current_timestamp: nil
        }

  defstruct [:current_frame, :current_timestamp]

  @impl true
  def new() do
    %__MODULE__{}
  end

  @impl true
  def depayload(depayloader, packet)

  def depayload(depayloader, %ExRTP.Packet{payload: <<>>, padding: true}), do: {nil, depayloader}

  def depayload(depayloader, packet) do
    case Payload.parse(packet.payload) do
      {:ok, vp8_payload} ->
        do_depayload(depayloader, packet, vp8_payload)

      {:error, reason} ->
        Logger.warning("""
        Couldn't parse payload, reason: #{reason}. \
        Resetting depayloader state. Payload: #{inspect(packet.payload)}.\
        """)

        {:ok, %{depayloader | current_frame: nil, current_timestamp: nil}}
    end
  end

  defp do_depayload(depayloader, packet, vp8_payload) do
    depayloader =
      case {depayloader.current_frame, vp8_payload} do
        {nil, %Payload{s: 1, pid: 0}} ->
          %{
            depayloader
            | current_frame: vp8_payload.payload,
              current_timestamp: packet.timestamp
          }

        {nil, _vp8_payload} ->
          Logger.debug("Dropping vp8 payload as it doesn't start a new frame")
          depayloader

        {_current_frame, %Payload{s: 1, pid: 0}} ->
          Logger.debug("""
          Received packet that starts a new frame without finishing the previous frame. \
          Dropping previous frame.\
          """)

          %{
            depayloader
            | current_frame: vp8_payload.payload,
              current_timestamp: packet.timestamp
          }

        _ when packet.timestamp != depayloader.current_timestamp ->
          Logger.debug("""
          Received packet with timestamp from a new frame that is not a beginning of this frame \
          and without finishing the previous frame. Dropping both.\
          """)

          %{depayloader | current_frame: nil, current_timestamp: nil}

        {current_frame, vp8_payload} ->
          %{depayloader | current_frame: current_frame <> vp8_payload.payload}
      end

    case {depayloader.current_frame, packet.marker} do
      {current_frame, true} when current_frame != nil ->
        {current_frame, %{depayloader | current_frame: nil, current_timestamp: nil}}

      _ ->
        {nil, depayloader}
    end
  end
end
