defmodule ExWebRTC.RTP.Depayloader.DTMF do
  @moduledoc false
  # Decapsulates DTMF tones out of RTP packet.
  #
  # Notes:
  # * this depayloader does only return notification about the start of the new DTMF event
  # * there is no support for detecting the end of the event.
  # In particular there is no support for the duration of the event.
  # * we assume there is always only one DTMF event in one RTP packet
  #
  # Based on [RFC 4733](https://datatracker.ietf.org/doc/html/rfc4733)

  alias ExRTP.Packet

  @behaviour ExWebRTC.RTP.Depayloader.Behaviour

  @type t :: %__MODULE__{}

  defstruct last_event_timestamp: nil

  @impl true
  def new() do
    %__MODULE__{last_event_timestamp: nil}
  end

  @impl true
  def depayload(%__MODULE__{} = depayloader, %Packet{payload: payload} = packet) do
    case payload do
      <<event::8, _e::1, _r::1, _volume::6, _duration::16>> ->
        # As described in RFC 4733, sec. 2.5.1.4:
        # The final packet for each event and for each segment SHOULD be sent a
        # total of three times at the interval used by the source for updates.
        # Hence, we need to check against timestamp, not to report the same event multiple times.
        if packet.marker == true and
             (depayloader.last_event_timestamp == nil or
                depayloader.last_event_timestamp < packet.timestamp) do
          depayloader = %{depayloader | last_event_timestamp: packet.timestamp}
          {%{code: event, event: event_to_string(event)}, depayloader}
        else
          {nil, depayloader}
        end

      _ ->
        {nil, depayloader}
    end
  end

  defp event_to_string(num) when num in 0..9, do: "#{num}"
  defp event_to_string(10), do: "*"
  defp event_to_string(11), do: "#"
  defp event_to_string(12), do: "A"
  defp event_to_string(13), do: "B"
  defp event_to_string(14), do: "C"
  defp event_to_string(15), do: "D"
end
