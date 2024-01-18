defmodule ExWebRTC.RTPTransceiver do
  @moduledoc """
  Implementation of the [RTCRtpTransceiver](https://www.w3.org/TR/webrtc/#dom-rtcrtptransceiver).
  """

  alias ExWebRTC.{
    MediaStreamTrack,
    PeerConnection.Configuration,
    RTPCodecParameters,
    RTPReceiver,
    RTPSender,
    SDPUtils,
    Utils
  }

  @type id() :: integer()
  @type direction() :: :sendonly | :recvonly | :sendrecv | :inactive | :stopped
  @type kind() :: :audio | :video

  @type t() :: %__MODULE__{
          id: id(),
          mid: String.t() | nil,
          mline_idx: non_neg_integer() | nil,
          direction: direction(),
          current_direction: direction() | nil,
          fired_direction: direction() | nil,
          kind: kind(),
          rtp_hdr_exts: [ExSDP.Attribute.Extmap.t()],
          codecs: [RTPCodecParameters.t()],
          receiver: RTPReceiver.t(),
          sender: RTPSender.t(),
          stopping: boolean(),
          stopped: boolean()
        }

  @enforce_keys [:id, :direction, :kind, :sender, :receiver]
  defstruct @enforce_keys ++
              [
                :mid,
                :mline_idx,
                :current_direction,
                :fired_direction,
                codecs: [],
                rtp_hdr_exts: [],
                stopping: false,
                stopped: false
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
    # or assign payload type on their own.
    codecs =
      if direction in [:sendrecv, :sendonly] do
        Enum.slice(codecs, 0, 1)
      else
        codecs
      end

    track = MediaStreamTrack.new(kind)

    %__MODULE__{
      id: Utils.generate_id(),
      direction: direction,
      kind: kind,
      codecs: codecs,
      rtp_hdr_exts: rtp_hdr_exts,
      receiver: %RTPReceiver{track: track},
      sender: RTPSender.new(sender_track, List.first(codecs), rtp_hdr_exts, options[:ssrc])
    }
  end

  @doc false
  @spec from_mline(ExSDP.Media.t(), non_neg_integer(), Configuration.t()) :: t()
  def from_mline(mline, mline_idx, config) do
    codecs = get_codecs(mline, config)
    rtp_hdr_exts = get_rtp_hdr_extensions(mline, config)
    {:mid, mid} = ExSDP.get_attribute(mline, :mid)

    track = MediaStreamTrack.new(mline.type)

    %__MODULE__{
      id: Utils.generate_id(),
      mid: mid,
      mline_idx: mline_idx,
      direction: :recvonly,
      kind: mline.type,
      codecs: codecs,
      rtp_hdr_exts: rtp_hdr_exts,
      receiver: %RTPReceiver{track: track},
      sender: RTPSender.new(nil, List.first(codecs), rtp_hdr_exts, mid, nil)
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
    # Reject mline. See RFC 8829 sec. 5.3.1 and RFC 3264 sec. 6.
    # We could reject earlier (as RFC suggests) but we generate
    # answer mline at first to have consistent fingerprint, ice_ufrag and
    # ice_pwd values across mlines.
    # We also set direction to inactive, even though JSEP doesn't require it.
    # See see https://github.com/w3c/webrtc-pc/issues/2927
    cond do
      transceiver.codecs == [] ->
        # there has to be at least one format so take it from the offer
        codecs = SDPUtils.get_rtp_codec_parameters(mline)
        transceiver = %__MODULE__{transceiver | codecs: codecs}
        opts = Keyword.put(opts, :direction, :inactive)
        mline = to_mline(transceiver, opts)
        %ExSDP.Media{mline | port: 0}

      transceiver.stopping == true or transceiver.stopped == true ->
        opts = Keyword.put(opts, :direction, :inactive)
        mline = to_mline(transceiver, opts)
        %ExSDP.Media{mline | port: 0}

      true ->
        offered_direction = SDPUtils.get_media_direction(mline)
        direction = get_direction(offered_direction, transceiver.direction)
        opts = Keyword.put(opts, :direction, direction)
        to_mline(transceiver, opts)
    end
  end

  @doc false
  @spec to_offer_mline(t(), Keyword.t()) :: ExSDP.Media.t()
  def to_offer_mline(transceiver, opts) do
    mline = to_mline(transceiver, opts)
    if transceiver.stopping, do: %ExSDP.Media{mline | port: 0}, else: mline
  end

  @doc false
  # asssings mid to the transceiver and its sender
  @spec assign_mid(t(), String.t()) :: t()
  def assign_mid(transceiver, mid) do
    sender = %RTPSender{transceiver.sender | mid: mid}
    %__MODULE__{transceiver | mid: mid, sender: sender}
  end

  @doc false
  @spec stop(t(), (-> term())) :: t()
  def stop(transceiver, on_track_ended) do
    tr =
      if transceiver.stopping,
        do: transceiver,
        else: stop_sending_and_receiving(transceiver, on_track_ended)

    # should we reset stopping or leave it as true?
    %__MODULE__{tr | stopped: true, stopping: false, current_direction: nil}
  end

  @doc false
  @spec stop_sending_and_receiving(t(), (-> term())) :: t()
  def stop_sending_and_receiving(transceiver, on_track_ended) do
    # TODO send RTCP BYE for each RTP stream
    # TODO stop receiving media
    on_track_ended.()
    %__MODULE__{transceiver | direction: :inactive, stopping: true}
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
    |> ExSDP.add_attributes(attributes ++ media_formats)
  end

  # RFC 3264 (6.1) + RFC 8829 (5.3.1)
  # AFAIK one of the cases should always match
  # bc we won't assign/create an inactive transceiver to i.e. sendonly mline
  # also neither of the arguments should ever be :stopped
  defp get_direction(_, :inactive), do: :inactive
  defp get_direction(:sendonly, t) when t in [:sendrecv, :recvonly], do: :recvonly
  defp get_direction(:recvonly, t) when t in [:sendrecv, :sendonly], do: :sendonly
  defp get_direction(:recvonly, :recvonly), do: :inactive
  defp get_direction(o, other) when o in [:sendrecv, nil], do: other
  defp get_direction(:inactive, _), do: :inactive

  defp get_codecs(mline, config) do
    mline
    |> SDPUtils.get_rtp_codec_parameters()
    |> Stream.filter(&Configuration.supported_codec?(config, &1))
    |> Enum.map(fn codec ->
      rtcp_fbs =
        Enum.filter(codec.rtcp_fbs, fn rtcp_fb ->
          Configuration.supported_rtcp_fb?(config, rtcp_fb)
        end)

      %RTPCodecParameters{codec | rtcp_fbs: rtcp_fbs}
    end)
  end

  defp get_rtp_hdr_extensions(mline, config) do
    mline
    |> ExSDP.get_attributes(ExSDP.Attribute.Extmap)
    |> Enum.filter(&Configuration.supported_rtp_hdr_extension?(config, &1, mline.type))
  end
end
