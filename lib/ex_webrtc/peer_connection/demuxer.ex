defmodule ExWebRTC.PeerConnection.Demuxer do
  @moduledoc false

  alias ExRTP.Packet
  alias ExRTP.Packet.Extension
  alias ExRTP.Packet.Extension.SourceDescription

  defstruct ssrcs: %{}, extensions: %{}, payload_types: %{}

  def process_data(demuxer, data) do
    with {:ok, %Packet{} = packet} <- decode(data),
         {:ok, demuxer, mid} <- match_to_mid(demuxer, packet) do
      {:ok, demuxer, mid, packet}
    end
  end

  # RFC 8843, 9.2
  defp match_to_mid(demuxer, packet) do
    with demuxer <- update_mapping(demuxer, packet),
         :error <- match_by_extension(demuxer, packet),
         :error <- match_by_payload_type(demuxer, packet) do
      {:error, :unmatched_stream}
    else
      {:ok, mid} -> {:ok, demuxer, mid}
      {:ok, _demuxer, _mid} = res -> res
    end
  end

  defp update_mapping(demuxer, %Packet{ssrc: ssrc, sequence_number: sn} = packet) do
    mid =
      packet.extensions
      |> Enum.find_value(fn %Extension{id: id} = ext ->
        case demuxer.extensions[id] do
          {SourceDescription, :mid} ->
            {:ok, decoded_ext} = SourceDescription.from_raw(ext)
            decoded_ext.text

          _other ->
            nil
        end
      end)

    case Map.get(demuxer.ssrcs, ssrc) do
      {_last_mid, last_sn} when mid != nil and sn > last_sn ->
        put_in(demuxer.ssrcs[ssrc], {mid, sn})

      nil when mid != nil ->
        put_in(demuxer.ssrcs[ssrc], {mid, sn})

      _other ->
        demuxer
    end
  end

  defp match_by_extension(demuxer, %Packet{ssrc: ssrc}) do
    case Map.get(demuxer.ssrcs, ssrc) do
      {last_mid, _last_sn} -> {:ok, last_mid}
      nil -> :error
    end
  end

  defp match_by_payload_type(demuxer, %Packet{ssrc: ssrc, payload_type: pt}) do
    case Map.get(demuxer.payload_types, pt) do
      nil -> :error
      mid -> {:ok, put_in(demuxer.ssrcs[ssrc], mid), mid}
    end
  end

  # RTP & RTCP demuxing, see RFC 6761
  # TODO: handle RTCP
  defp decode(<<_, s, _::binary>>) when s in 192..223, do: {:error, :rtcp}
  defp decode(data), do: Packet.decode(data)
end
