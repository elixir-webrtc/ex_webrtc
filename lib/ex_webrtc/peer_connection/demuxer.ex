defmodule ExWebRTC.PeerConnection.Demuxer do
  @moduledoc false

  alias ExRTP.Packet
  alias ExRTP.Packet.Extension
  alias ExRTP.Packet.Extension.SourceDescription

  alias ExSDP.Attribute.Extmap

  alias ExWebRTC.SDPUtils

  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"

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
        %Extmap{uri: @mid_uri, id: id} -> id
        _other -> nil
      end)

    %__MODULE__{
      ssrc_to_mid: ssrc_to_mid,
      mid_ext_id: mid_ext_id,
      pt_to_mid: pt_to_mid
    }
  end

  @doc """
  RTP demuxing flow:
    1. if packet has SDES MID extension, add it to mapping ssrc => mid (RFC 8843, 9.2)
      - if mapping already exists but is different (e.g. ssrc is mapped
      to different mid) raise (temporary)
    2. if ssrc => mid mapping exists, route the packet accordingly
    3. if not, check payload_type => mid mapping
      - if exists, route accordingly
      - otherwise, drop the packet
  """
  @spec demux_packet(t(), ExRTP.Packet.t()) :: {:ok, binary(), t()} | :error
  def demux_packet(demuxer, %Packet{} = packet) do
    demuxer = update_ssrc_mapping(demuxer, packet)

    case Map.fetch(demuxer.ssrc_to_mid, packet.ssrc) do
      {:ok, last_mid} -> {:ok, last_mid, demuxer}
      :error -> match_by_payload_type(demuxer, packet)
    end
  end

  @spec demux_ssrc(t(), binary()) :: {:ok, binary()} | :error
  def demux_ssrc(demuxer, ssrc), do: Map.fetch(demuxer.ssrc_to_mid, ssrc)

  defp update_ssrc_mapping(%__MODULE__{mid_ext_id: id} = demuxer, %Packet{ssrc: ssrc} = packet) do
    mid =
      case Packet.fetch_extension(packet, id) do
        {:ok, %Extension{id: ^id} = ext} ->
          {:ok, mid_ext} = SourceDescription.from_raw(ext)
          mid_ext.text

        :error ->
          nil
      end

    case Map.fetch(demuxer.ssrc_to_mid, ssrc) do
      {:ok, last_mid} when mid != nil and mid != last_mid ->
        # temporary, as we believe this case shouldn't occur
        raise "Received new MID for already mapped SSRC. SSRC table: #{inspect(demuxer.ssrc_to_mid)}, packet ssrc: #{ssrc}, packet  mid: #{mid}"

      :error when mid != nil ->
        put_in(demuxer.ssrc_to_mid[ssrc], mid)

      _other ->
        demuxer
    end
  end

  defp match_by_payload_type(demuxer, %Packet{ssrc: ssrc, payload_type: pt}) do
    case Map.fetch(demuxer.pt_to_mid, pt) do
      {:ok, mid} -> {:ok, mid, put_in(demuxer.ssrc_to_mid[ssrc], mid)}
      :error -> :error
    end
  end
end
