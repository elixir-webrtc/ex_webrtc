defmodule ExWebRTC.RTP.Depayloader.H264 do
  @moduledoc """
  Extracts H264 NAL Units from RTP packets.

  Based on [RFC 6184](https://tools.ietf.org/html/rfc6184).

  Supported types: Single NALU, FU-A, STAP-A.
  """
  @behaviour ExWebRTC.RTP.Depayloader.Behaviour

  require Logger

  alias ExWebRTC.RTP.H264.{FU, NAL, StapA}

  @annexb_prefix <<1::32>>

  @type t() :: %__MODULE__{
          current_timestamp: nil,
          fu_parser_acc: nil
        }

  defstruct [:current_timestamp, :fu_parser_acc]

  @impl true
  def new() do
    %__MODULE__{}
  end

  @impl true
  def depayload(depayloader, %ExRTP.Packet{payload: <<>>, padding: true}), do: {nil, depayloader}

  def depayload(depayloader, packet) do
    with {:ok, {header, _payload} = nal} <- NAL.Header.parse_unit_header(packet.payload),
         unit_type = NAL.Header.decode_type(header),
         {:ok, {nal, depayloader}} <-
           handle_unit_type(unit_type, depayloader, packet, nal) do
      {nal, depayloader}
    else
      {:error, reason} ->
        Logger.warning("""
        Couldn't parse payload, reason: #{reason}. \
        Resetting depayloader state. Payload: #{inspect(packet.payload)}.\
        """)

        {:ok, %{depayloader | current_nal: nil, current_timestamp: nil}}
    end
  end

  defp handle_unit_type(:single_nalu, depayloader, packet, {_header, payload}) do
    {:ok,
     {prefix_annexb(payload), %__MODULE__{depayloader | current_timestamp: packet.timestamp}}}
  end

  defp handle_unit_type(
         :fu_a,
         %{current_timestamp: current_timestamp, fu_parser_acc: fu_parser_acc},
         packet,
         {header, payload}
       ) do
    if fu_parser_acc != nil and current_timestamp != packet.timestamp do
      {:error, "Invalid timestamp inside FU-A"}

      Logger.debug("""
      Received packet with FU-A type payload that is not a start of Fragmentation Unit with timestamp \
      different than last start and without finishing the previous FU. Dropping FU.\
      """)
    end

    case FU.parse(payload, fu_parser_acc || %FU{}) do
      {:ok, {data, type}} ->
        data = NAL.Header.add_header(data, 0, header.nal_ref_idc, type)

        {:ok,
         {prefix_annexb(data),
          %__MODULE__{current_timestamp: packet.timestamp, fu_parser_acc: nil}}}

      {:incomplete, fu} ->
        {:ok, {nil, %__MODULE__{fu_parser_acc: fu}}}

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_unit_type(:stap_a, depayloader, packet, {_header, payload}) do
    with {:ok, result} <- StapA.parse(payload) do
      nals = Enum.reduce(result, <<>>, fn nal, acc -> acc <> prefix_annexb(nal) end)
      {:ok, {nals, %__MODULE__{depayloader | current_timestamp: packet.timestamp}}}
    end
  end

  defp handle_unit_type(unsupported_type, _depayloader, _packet, _nal) do
    {:error, "Unsupported nal type #{unsupported_type}"}

    Logger.debug("""
      Received packet with unsupported NAL type. Supported types are: Single NALU, STAP-A, FU-A. Dropping packet.
    """)
  end

  defp prefix_annexb(nal) do
    @annexb_prefix <> nal
  end
end
