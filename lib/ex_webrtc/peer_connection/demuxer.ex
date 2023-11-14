defmodule ExWebRTC.PeerConnection.Demuxer do
  @moduledoc false
  # RTP demuxing flow:
  # 1. if packet has sdes mid extension, add it to mapping ssrc => mid
  #   - if mapping already exista, raise (temporary)
  # 2. if ssrc => mid mapping exists, route the packet accordingly
  # 3. if not, check payload_type => mid mapping
  #   - if exists, route accordingly
  #   - otherwise, drop the packet

  alias ExRTP.Packet
  alias ExRTP.Packet.Extension
  alias ExRTP.Packet.Extension.SourceDescription

  @type t() :: %__MODULE__{
          ssrc_to_mid: %{non_neg_integer() => {non_neg_integer(), binary()}},
          extensions: %{non_neg_integer() => {module(), atom()}},
          pt_to_mid: %{non_neg_integer() => binary()}
        }

  defstruct ssrc_to_mid: %{}, extensions: %{}, pt_to_mid: %{}

  @spec demux(t(), binary()) :: {:ok, t(), binary(), ExRTP.Packet.t()} | {:error, atom()}
  def demux(demuxer, data) do
    with {:ok, %Packet{} = packet} <- decode(data),
         {:ok, demuxer, mid} <- match_to_mid(demuxer, packet) do
      {:ok, demuxer, mid, packet}
    end
  end

  # RFC 8843, 9.2
  defp match_to_mid(demuxer, %Packet{ssrc: ssrc} = packet) do
    demuxer = update_mapping(demuxer, packet)

    case Map.get(demuxer.ssrc_to_mid, ssrc) do
      {last_mid, _last_sn} -> {:ok, demuxer, last_mid}
      nil -> match_by_payload_type(demuxer, packet)
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

    case Map.get(demuxer.ssrc_to_mid, ssrc) do
      {last_mid, last_sn} when mid != nil and mid != last_mid and sn > last_sn ->
        # temporary, as we belive this case shouldn't occur
        raise "Received new MID for already mapped SSRC"

      nil when mid != nil ->
        put_in(demuxer.ssrc_to_mid[ssrc], {mid, sn})

      _other ->
        demuxer
    end
  end

  defp match_by_payload_type(demuxer, %Packet{ssrc: ssrc, payload_type: pt, sequence_number: sn}) do
    case Map.get(demuxer.pt_to_mid, pt) do
      nil -> {:error, :no_matching_mid}
      mid -> {:ok, put_in(demuxer.ssrc_to_mid[ssrc], {mid, sn}), mid}
    end
  end

  # RTP & RTCP demuxing, see RFC 6761
  # TODO: handle RTCP
  defp decode(<<_, s, _::binary>>) when s in 192..223, do: {:error, :rtcp}
  defp decode(data), do: Packet.decode(data)
end
