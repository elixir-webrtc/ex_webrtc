defmodule ExWebRTC.RTPTransceiver do
  @moduledoc """
  RTPTransceiver
  """

  alias ExWebRTC.{
    MediaStreamTrack,
    PeerConnection.Configuration,
    RTPCodecParameters,
    RTPReceiver,
    RTPSender,
    SDPUtils
  }

  @type direction() :: :sendonly | :recvonly | :sendrecv | :inactive | :stopped
  @type kind() :: :audio | :video

  @type t() :: %__MODULE__{
          mid: String.t() | nil,
          direction: direction(),
          current_direction: direction() | nil,
          kind: kind(),
          rtp_hdr_exts: [ExSDP.Attribute.Extmap.t()],
          codecs: [RTPCodecParameters.t()],
          receiver: RTPReceiver.t(),
          sender: RTPSender.t()
        }

  @enforce_keys [:mid, :direction, :current_direction, :kind, :sender, :receiver]
  defstruct @enforce_keys ++
              [
                codecs: [],
                rtp_hdr_exts: []
              ]

  @doc false
  @spec new(kind(), MediaStreamTrack.t() | nil, Configuration.t(), Keyword.t()) :: t()
  def new(kind, sender_track, config, options) do
    direction = Keyword.get(options, :direction, :sendrecv)

    {rtp_hdr_exts, codecs} =
      case kind do
        :audio -> {Map.values(config.audio_rtp_hdr_exts), config.audio_codecs}
        :video -> {Map.values(config.video_rtp_hdr_exts), config.video_codecs}
      end

    # When we create sendonly or sendrecv transceiver, we always only take one codec
    # to avoid ambiguity when assigning payload type for RTP packets in RTPSender.
    # In other case, if PeerConnection negotiated multiple codecs,
    # user would have to pass RTP codec when sending RTP packets,
    # or assing payload type on their own.
    codecs =
      if direction in [:sendrecv, :sendonly] do
        Enum.slice(codecs, 0, 1)
      else
        codecs
      end

    track = MediaStreamTrack.new(kind)

    %__MODULE__{
      mid: nil,
      direction: direction,
      current_direction: nil,
      kind: kind,
      codecs: codecs,
      rtp_hdr_exts: rtp_hdr_exts,
      receiver: %RTPReceiver{track: track},
      sender: RTPSender.new(sender_track, List.first(codecs), rtp_hdr_exts)
    }
  end

  @doc false
  @spec from_mline(ExSDP.Media.t(), Configuration.t()) :: t()
  def from_mline(mline, config) do
    codecs = get_codecs(mline, config)
    rtp_hdr_exts = get_rtp_hdr_extensions(mline, config)
    {:mid, mid} = ExSDP.Media.get_attribute(mline, :mid)

    track = MediaStreamTrack.new(mline.type)

    %__MODULE__{
      mid: mid,
      direction: :recvonly,
      current_direction: nil,
      kind: mline.type,
      codecs: codecs,
      rtp_hdr_exts: rtp_hdr_exts,
      receiver: %RTPReceiver{track: track},
      sender: RTPSender.new(nil, List.first(codecs), rtp_hdr_exts, mid)
    }
  end

  @doc false
  @spec update(t(), ExSDP.Media.t(), Configuration.t()) :: t()
  def update(transceiver, mline, config) do
    codecs = get_codecs(mline, config)
    rtp_hdr_exts = get_rtp_hdr_extensions(mline, config)
    sender = RTPSender.update(transceiver.sender, List.first(codecs), rtp_hdr_exts)

    %__MODULE__{
      transceiver
      | codecs: codecs,
        rtp_hdr_exts: rtp_hdr_exts,
        sender: sender
    }
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

  @doc false
  # asssings mid to the transceiver and its sender
  @spec assign_mid(t(), String.t()) :: t()
  def assign_mid(transceiver, mid) do
    sender = %RTPSender{transceiver.sender | mid: mid}
    %{transceiver | mid: mid, sender: sender}
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

  defp get_codecs(mline, config) do
    mline
    |> SDPUtils.get_rtp_codec_parameters()
    |> Stream.filter(&Configuration.is_supported_codec(config, &1))
    |> Enum.map(fn codec ->
      rtcp_fbs =
        Enum.filter(codec.rtcp_fbs, fn rtcp_fb ->
          Configuration.is_supported_rtcp_fb(config, rtcp_fb)
        end)

      %RTPCodecParameters{codec | rtcp_fbs: rtcp_fbs}
    end)
  end

  defp get_rtp_hdr_extensions(mline, config) do
    mline
    |> ExSDP.Media.get_attributes(ExSDP.Attribute.Extmap)
    |> Enum.filter(&Configuration.is_supported_rtp_hdr_extension(config, &1, mline.type))
  end
end
