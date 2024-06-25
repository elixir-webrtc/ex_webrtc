defmodule ExWebRTC.RTPReceiver.SimulcastDemuxer do
  @moduledoc false

  alias ExSDP.Attribute.Extmap

  alias ExRTP.Packet
  alias ExRTP.Packet.Extension
  alias ExRTP.Packet.Extension.SourceDescription

  @rid_uri "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"
  @rrid_uri "urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id"

  @type t() :: %__MODULE__{
          rid_ext_id: non_neg_integer() | nil,
          rrid_ext_id: non_neg_integer() | nil,
          ssrc_to_rid: %{(ssrc :: non_neg_integer()) => rid :: String.t()}
        }

  defstruct [:rid_ext_id, :rrid_ext_id, ssrc_to_rid: %{}]

  @spec new([Extmap.t()]) :: t()
  def new(rtp_hdr_exts) do
    {rid, rrid} = find_rid_ids(rtp_hdr_exts)

    %__MODULE__{
      rid_ext_id: rid,
      rrid_ext_id: rrid
    }
  end

  @spec update(t(), [Extmap.t()]) :: t()
  def update(demuxer, rtp_hdr_exts) do
    {rid, rrid} = find_rid_ids(rtp_hdr_exts)

    %__MODULE__{demuxer | rid_ext_id: rid, rrid_ext_id: rrid}
  end

  @spec demux_packet(t(), Packet.t(), rtx?: boolean()) :: {String.t() | nil, t()}
  def demux_packet(demuxer, packet, opts \\ []) do
    rtx? = Keyword.get(opts, :rtx?, false)
    demuxer = update_ssrc_mapping(demuxer, packet, rtx?)

    %Packet{ssrc: ssrc} = packet

    case Map.fetch(demuxer.ssrc_to_rid, ssrc) do
      {:ok, last_rid} -> {last_rid, demuxer}
      :error -> {nil, demuxer}
    end
  end

  @spec demux_ssrc(t(), non_neg_integer()) :: String.t() | nil
  def demux_ssrc(demuxer, ssrc), do: Map.get(demuxer.ssrc_to_rid, ssrc)

  defp update_ssrc_mapping(demuxer, packet, rtx?) do
    id = if(rtx?, do: demuxer.rrid_ext_id, else: demuxer.rid_ext_id)

    rid =
      case Packet.fetch_extension(packet, id) do
        {:ok, %Extension{id: ^id} = ext} ->
          {:ok, rid_ext} = SourceDescription.from_raw(ext)
          rid_ext.text

        :error ->
          nil
      end

    %Packet{ssrc: ssrc} = packet

    case Map.fetch(demuxer.ssrc_to_rid, ssrc) do
      {:ok, last_rid} when rid != nil and rid != last_rid ->
        # temporary, as we believe this case shouldn't occur
        raise "Received new RID for already mapped SSRC. SSRC table: #{inspect(demuxer.ssrc_to_rid)}, packet ssrc: #{ssrc}, packet RID: #{rid}"

      :error when rid != nil ->
        put_in(demuxer.ssrc_to_rid[ssrc], rid)

      _other ->
        demuxer
    end
  end

  defp find_rid_ids(rtp_hdr_exts) do
    rid = find_id_by_uri(rtp_hdr_exts, @rid_uri)
    rrid = find_id_by_uri(rtp_hdr_exts, @rrid_uri)
    {rid, rrid}
  end

  defp find_id_by_uri(rtp_hdr_exts, uri) do
    Enum.find_value(rtp_hdr_exts, fn
      %Extmap{uri: ^uri, id: id} -> id
      _other -> nil
    end)
  end
end
