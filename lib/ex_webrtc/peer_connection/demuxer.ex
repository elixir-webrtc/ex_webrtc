defmodule ExWebRTC.PeerConnection.Demuxer do
  @moduledoc false
  # RTP demuxing flow:
  # 1. if packet has sdes mid extension, add it to mapping ssrc => mid
  #   - if mapping already exists but is different (e.g. ssrc is mapped
  #  to different mid) raise (temporary)
  # 2. if ssrc => mid mapping exists, route the packet accordingly
  # 3. if not, check payload_type => mid mapping
  #   - if exists, route accordingly
  #   - otherwise, drop the packet

  alias ExRTP.Packet
  alias ExRTP.Packet.Extension
  alias ExRTP.Packet.Extension.SourceDescription

  alias ExWebRTC.SDPUtils

  @type t() :: %__MODULE__{
          ssrc_to_mid: %{(ssrc :: non_neg_integer()) => mid :: binary()},
          mid_ext_id: non_neg_integer() | nil,
          pt_to_mid: %{(pt :: non_neg_integer()) => mid :: binary()}
        }

  defstruct ssrc_to_mid: %{}, mid_ext_id: nil, pt_to_mid: %{}

  @spec update(t(), ExSDP.t()) :: t()
  def update(demuxer, sdp) do
    ssrc_to_mid = Map.merge(demuxer.ssrc_to_mid, SDPUtils.get_ssrc_to_mid(sdp))
    pt_to_mid = SDPUtils.get_payload_to_mid(sdp)

    mid_ext_id =
      sdp
      |> SDPUtils.get_extensions()
      |> Enum.find_value(fn
        {id, {SourceDescription, :mid}} -> id
        _ -> nil
      end)

    %__MODULE__{
      ssrc_to_mid: ssrc_to_mid,
      mid_ext_id: mid_ext_id,
      pt_to_mid: pt_to_mid
    }
  end

  @spec demux(t(), binary()) :: {:ok, t(), binary(), ExRTP.Packet.t()} | {:error, atom()}
  def demux(demuxer, data) do
    with {:ok, %Packet{} = packet} <- decode(data),
         {:ok, demuxer, mid} <- match_to_mid(demuxer, packet) do
      {:ok, demuxer, mid, packet}
    end
  end

  # RFC 8843, 9.2
  defp match_to_mid(demuxer, %Packet{ssrc: ssrc} = packet) do
    demuxer = update_ssrc_mapping(demuxer, packet)

    case Map.fetch(demuxer.ssrc_to_mid, ssrc) do
      {:ok, last_mid} -> {:ok, demuxer, last_mid}
      :error -> match_by_payload_type(demuxer, packet)
    end
  end

  defp update_ssrc_mapping(%__MODULE__{mid_ext_id: id} = demuxer, %Packet{ssrc: ssrc} = packet) do
    mid =
      Enum.find_value(packet.extensions, fn
        %Extension{id: ^id} = ext ->
          {:ok, mid_ext} = SourceDescription.from_raw(ext)
          mid_ext.text

        _ ->
          nil
      end)

    case Map.fetch(demuxer.ssrc_to_mid, ssrc) do
      {:ok, last_mid} when mid != nil and mid != last_mid ->
        # temporary, as we belive this case shouldn't occur
        raise "Received new MID for already mapped SSRC. SSRC table: #{inspect(demuxer.ssrc_to_mid)}, packet ssrc: #{ssrc}, packet  mid: #{mid}"

      :error when mid != nil ->
        put_in(demuxer.ssrc_to_mid[ssrc], mid)

      _other ->
        demuxer
    end
  end

  defp match_by_payload_type(demuxer, %Packet{ssrc: ssrc, payload_type: pt}) do
    case Map.get(demuxer.pt_to_mid, pt) do
      nil -> {:error, :no_matching_mid}
      mid -> {:ok, put_in(demuxer.ssrc_to_mid[ssrc], mid), mid}
    end
  end

  # RTP & RTCP demuxing, see RFC 6761
  # TODO: handle RTCP
  defp decode(<<_, s, _::binary>>) when s in 192..223, do: {:error, :rtcp}
  defp decode(data), do: Packet.decode(data)
end
