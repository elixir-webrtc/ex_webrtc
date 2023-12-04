defmodule ExWebRTC.RTPTransceiver do
  @moduledoc """
  RTPTransceiver
  """

  alias ExWebRTC.{
    PeerConnection.Configuration,
    RTPCodecParameters,
    RTPReceiver,
    RTPSender,
    MediaStreamTrack
  }

  @type direction() :: :sendonly | :recvonly | :sendrecv | :inactive | :stopped
  @type kind() :: :audio | :video

  @type t() :: %__MODULE__{
          mid: String.t(),
          current_direction: direction(),
          direction: direction(),
          kind: kind(),
          rtp_hdr_exts: [ExSDP.Attribute.Extmap.t()],
          codecs: [RTPCodecParameters.t()],
          receiver: RTPReceiver.t(),
          sender: RTPSender.t()
        }

  @enforce_keys [:mid, :direction, :kind]
  defstruct @enforce_keys ++
              [
                current_direction: nil,
                codecs: [],
                rtp_hdr_exts: [],
                receiver: %RTPReceiver{},
                sender: %RTPSender{}
              ]

  @doc false
  def find_by_mid(transceivers, mid) do
    transceivers
    |> Enum.with_index(fn tr, idx -> {idx, tr} end)
    |> Enum.find(fn {_idx, tr} -> tr.mid == mid end)
  end

  @doc false
  @spec to_answer_mline(t(), ExSDP.Media.t(), Keyword.t()) :: ExSDP.Media.t()
  def to_answer_mline(transceiver, mline, opts) do
    if transceiver.codecs == [] do
      # reject mline and skip further processing
      # see RFC 8299 sec. 5.3.1 and RFC 3264 sec. 6
      %ExSDP.Media{mline | port: 0}
    else
      offered_direction = ExSDP.Media.get_attribute(mline, :direction)
      direction = get_direction(offered_direction, transceiver.direction)
      opts = Keyword.put(opts, :direction, direction)
      to_mline(transceiver, opts)
    end
  end

  @doc false
  @spec to_offer_mline(t(), Keyword.t()) :: ExSDP.Media.t()
  def to_offer_mline(transceiver, opts) do
    to_mline(transceiver, opts)
  end

  # searches for transceiver for a given mline
  # if it exists, updates its configuration
  # if it doesn't exist, creats a new one
  # returns list of updated transceivers
  @doc false
  def update_or_create(transceivers, mid, mline, config) do
    case find_by_mid(transceivers, mid) do
      {idx, %__MODULE__{} = tr} ->
        List.replace_at(transceivers, idx, update(tr, mline, config))

      nil ->
        codecs = get_codecs(mline, config)
        rtp_hdr_exts = get_rtp_hdr_extensions(mline, config)

        track = MediaStreamTrack.new(mline.type)

        tr = %__MODULE__{
          mid: mid,
          direction: :recvonly,
          kind: mline.type,
          codecs: codecs,
          rtp_hdr_exts: rtp_hdr_exts,
          receiver: %RTPReceiver{track: track}
        }

        transceivers ++ [tr]
    end
  end

  defp to_mline(transceiver, opts) do
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
      if(Keyword.get(opts, :rtcp, false), do: [{"rtcp", "9 IN IP4 0.0.0.0"}], else: []) ++
        [
          Keyword.get(opts, :direction, transceiver.direction),
          {:mid, transceiver.mid},
          {:ice_ufrag, Keyword.fetch!(opts, :ice_ufrag)},
          {:ice_pwd, Keyword.fetch!(opts, :ice_pwd)},
          {:ice_options, Keyword.fetch!(opts, :ice_options)},
          {:fingerprint, Keyword.fetch!(opts, :fingerprint)},
          {:setup, Keyword.fetch!(opts, :setup)},
          :rtcp_mux
        ] ++ transceiver.rtp_hdr_exts

    %ExSDP.Media{
      ExSDP.Media.new(transceiver.kind, 9, "UDP/TLS/RTP/SAVPF", pt)
      | # mline must be followed by a cline, which must contain
        # the default value "IN IP4 0.0.0.0" (as there are no candidates yet)
        connection_data: [%ExSDP.ConnectionData{address: {0, 0, 0, 0}}]
    }
    |> ExSDP.Media.add_attributes(attributes ++ media_formats)
  end

  # RFC 3264 (6.1) + RFC 8829 (5.3.1)
  # AFAIK one of the cases should always match
  # bc we won't assign/create an inactive transceiver to i.e. sendonly mline
  # also neither of the arguments should ever be :stopped
  defp get_direction(_, :inactive), do: :inactive
  defp get_direction(:sendonly, t) when t in [:sendrecv, :recvonly], do: :recvonly
  defp get_direction(:recvonly, t) when t in [:sendrecv, :sendonly], do: :sendonly
  defp get_direction(o, other) when o in [:sendrecv, nil], do: other
  defp get_direction(:inactive, _), do: :inactive

  defp update(transceiver, mline, config) do
    codecs = get_codecs(mline, config)
    rtp_hdr_exts = get_rtp_hdr_extensions(mline, config)
    # TODO: potentially update tracks

    %__MODULE__{
      transceiver
      | codecs: codecs,
        rtp_hdr_exts: rtp_hdr_exts
    }
  end

  defp get_codecs(mline, config) do
    rtp_mappings = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.RTPMapping)
    fmtps = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.FMTP)
    all_rtcp_fbs = ExSDP.Media.get_attributes(mline, ExSDP.Attribute.RTCPFeedback)

    rtp_mappings
    |> Stream.map(fn rtp_mapping ->
      fmtp = Enum.find(fmtps, &(&1.pt == rtp_mapping.payload_type))

      rtcp_fbs =
        all_rtcp_fbs
        |> Stream.filter(&(&1.pt == rtp_mapping.payload_type))
        |> Enum.filter(&Configuration.is_supported_rtcp_fb(config, &1))

      RTPCodecParameters.new(mline.type, rtp_mapping, fmtp, rtcp_fbs)
    end)
    |> Enum.filter(fn codec -> Configuration.is_supported_codec(config, codec) end)
  end

  defp get_rtp_hdr_extensions(mline, config) do
    mline
    |> ExSDP.Media.get_attributes(ExSDP.Attribute.Extmap)
    |> Enum.filter(&Configuration.is_supported_rtp_hdr_extension(config, &1, mline.type))
  end
end
