defmodule ExWebRTC.RTPTransceiver do
  @moduledoc """
  RTPTransceiver
  """

  alias ExWebRTC.{RTPCodecParameters, RTPReceiver}

  @type direction() :: :sendonly | :recvonly | :sendrecv | :inactive | :stopped
  @type kind() :: :audio | :video

  @type t() :: %__MODULE__{
          mid: String.t(),
          direction: direction(),
          kind: kind(),
          hdr_exts: [],
          codecs: [],
          rtp_receiver: nil
        }

  @enforce_keys [:mid, :direction, :kind]
  defstruct @enforce_keys ++ [codecs: [], hdr_exts: [], rtp_receiver: %RTPReceiver{}]

  @doc false
  def find_by_mid(transceivers, mid) do
    transceivers
    |> Enum.with_index(fn tr, idx -> {idx, tr} end)
    |> Enum.find(fn {_idx, tr} -> tr.mid == mid end)
  end

  # searches for transceiver for a given mline
  # if it exists, updates its configuration
  # if it doesn't exist, creats a new one
  # returns list of updated transceivers
  @doc false
  def update_or_create(transceivers, mid, mline) do
    case find_by_mid(transceivers, mid) do
      {idx, %__MODULE__{} = tr} ->
        List.replace_at(transceivers, idx, update(tr, mline))

      nil ->
        codecs = get_codecs(mline)
        hdr_exts = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.Extmap)
        ssrc = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.SSRC)

        tr = %__MODULE__{
          mid: mid,
          direction: :recvonly,
          kind: mline.type,
          codecs: codecs,
          hdr_exts: hdr_exts,
          rtp_receiver: %RTPReceiver{ssrc: ssrc}
        }

        transceivers ++ [tr]
    end
  end

  def to_mline(transceiver, config) do
    pt = Enum.map(transceiver.codecs, fn codec -> codec.payload_type end)

    media_formats =
      Enum.flat_map(transceiver.codecs, fn codec ->
        [_type, encoding] = String.split(codec.mime_type, "/")

        rtp_mapping = %ExSDP.Attribute.RTPMapping{
          clock_rate: codec.clock_rate,
          encoding: encoding,
          params: codec.channels,
          payload_type: codec.payload_type
        }

        [rtp_mapping, codec.sdp_fmtp_line, codec.rtcp_fbs]
      end)

    attributes =
      [
        transceiver.direction,
        {:mid, transceiver.mid},
        {:ice_ufrag, Keyword.fetch!(config, :ice_ufrag)},
        {:ice_pwd, Keyword.fetch!(config, :ice_pwd)},
        {:ice_options, Keyword.fetch!(config, :ice_options)},
        {:fingerprint, Keyword.fetch!(config, :fingerprint)},
        {:setup, Keyword.fetch!(config, :setup)},
        :rtcp_mux
      ] ++ if(Keyword.get(config, :rtcp, false), do: [{"rtcp", "9 IN IP4 0.0.0.0"}], else: [])

    %ExSDP.Media{
      ExSDP.Media.new(transceiver.kind, 9, "UDP/TLS/RTP/SAVPF", pt)
      | # mline must be followed by a cline, which must contain
        # the default value "IN IP4 0.0.0.0" (as there are no candidates yet)
        connection_data: [%ExSDP.ConnectionData{address: {0, 0, 0, 0}}]
    }
    |> ExSDP.Media.add_attributes(attributes ++ media_formats)
  end

  defp update(transceiver, mline) do
    codecs = get_codecs(mline)
    hdr_exts = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.Extmap)
    ssrc = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.SSRC)
    rtp_receiver = %RTPReceiver{ssrc: ssrc}
    %__MODULE__{transceiver | codecs: codecs, hdr_exts: hdr_exts, rtp_receiver: rtp_receiver}
  end

  defp get_codecs(mline) do
    rtp_mappings = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.RTPMapping)
    fmtps = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.FMTP)
    all_rtcp_fbs = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.RTCPFeedback)

    for rtp_mapping <- rtp_mappings do
      fmtp = Enum.find(fmtps, fn fmtp -> fmtp.pt == rtp_mapping.payload_type end)

      rtcp_fbs =
        Enum.filter(all_rtcp_fbs, fn rtcp_fb -> rtcp_fb.pt == rtp_mapping.payload_type end)

      RTPCodecParameters.new(mline.type, rtp_mapping, fmtp, rtcp_fbs)
    end
  end
end
