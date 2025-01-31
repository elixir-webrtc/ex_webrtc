defmodule ExWebRTC.PeerConnection.Configuration do
  @moduledoc """
  `ExWebRTC.PeerConnection` configuration.
  """

  require Logger

  alias ExICE.ICEAgent
  alias ExWebRTC.{RTPCodecParameters, SDPUtils}
  alias ExSDP.Attribute.{Extmap, FMTP, RTCPFeedback}

  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"
  @twcc_uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
  @rid_uri "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"
  @rrid_uri "urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id"

  @default_audio_codecs [
    %RTPCodecParameters{
      payload_type: 111,
      mime_type: "audio/opus",
      clock_rate: 48_000,
      channels: 2
    }
  ]

  @default_video_codecs [
    %RTPCodecParameters{
      payload_type: 98,
      mime_type: "video/H264",
      clock_rate: 90_000,
      sdp_fmtp_line: %FMTP{
        pt: 98,
        level_asymmetry_allowed: true,
        packetization_mode: 0,
        profile_level_id: 0x42E01F
      }
    },
    %RTPCodecParameters{
      payload_type: 99,
      mime_type: "video/H264",
      clock_rate: 90_000,
      sdp_fmtp_line: %FMTP{
        pt: 99,
        level_asymmetry_allowed: true,
        packetization_mode: 1,
        profile_level_id: 0x42E01F
      }
    },
    %RTPCodecParameters{
      payload_type: 96,
      mime_type: "video/VP8",
      clock_rate: 90_000
    },
    %RTPCodecParameters{
      payload_type: 45,
      mime_type: "video/AV1",
      clock_rate: 90_000,
      sdp_fmtp_line: %FMTP{pt: 45, level_idx: 5, profile: 0, tier: 0}
    }
  ]

  @typedoc """
  ICE (STUN and/or TURN) server used to create the ICE connection.
  """
  @type ice_server() :: %{
          optional(:credential) => String.t(),
          optional(:username) => String.t(),
          :urls => [String.t()] | String.t()
        }

  @typedoc """
  RTP header extension that are going to be included in the SDP offer/answer.

  Keep in mind that you are free to pass any RTP header extension URI, but the underlying
  RTP parsing library (`ex_rtp`) might not support it. In such case, you have to parse the
  header extension yourself.

  This header extension will be included in all of the m-lines of provided `type` (or for both audio and video
  if `:all` is used).

  Use `default_rtp_header_extensions/0` to check the RTP header extensions included by default.
  When passing a list of RTP header extensions to `t:options/0`, it will override the default RTP header extensions.

  Be aware that some of the features (see `t:feature/0`) can implicitly add RTP header extensions).
  """
  @type rtp_header_extension() :: %{
          type: :audio | :video | :all,
          uri: String.t()
        }

  @default_rtp_header_extensions [%{type: :all, uri: @mid_uri}, %{type: :video, uri: @rid_uri}]

  @typedoc """
  RTCP feedbacks that are going to be added by default to all of the codecs.

  Use `default_rtcp_feedbacks/0` to check the RTCP feedbacks included by default. When passing a
  list of RTPC feedbacks to `t:options/0`, it will override the default feedbacks.

  Be aware that some of the features (see `t:feature/0`) can implicitly add RTCP feedbacks.
  """
  @type rtcp_feedback() :: %{
          type: :audio | :video | :all,
          feedback: :nack | :fir | :pli | :twcc
        }

  @default_rtcp_feedbacks [
    %{type: :video, feedback: :fir},
    %{type: :video, feedback: :pli}
  ]

  @typedoc """
  Features provided by the ExWebRTC's PeerConnection:

  * `:twcc` - ExWebRTC's PeerConnection will generate TWCC RTCP feedbacks based on incoming packets and
  send them to the remote peer (implicitly adds the `http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01` to negotiated
  RTP header extensions and `:twcc` RTCP feedback to all of the negotiated codecs, both audio and video).
  * `:inbound_rtx` - ExWebRTC's PeerConnection will generate NACK RTCP feedbacks in response to missing incoming video packets and properly handle incoming
  retransmissions (implicitly adds the `:nack` RTCP feedback and a matching `a=rtpmap:[id] rtx/...` attribute for every negotiated video codec).
  * `:outbound_rtx` - ExWebRTC's PeerConnection will respond to incoming NACK RTCP feedbacks and retransmit packets accordingly (implicitly adds the same
  attributes as `:inbound_rtx`).
  * `:rtcp_reports` - ExWebRTC's PeerConnection will generate and send RTCP Sender/Receiver Reports based on incoming/send RTP packets.

  Use `default_features/0` to get the list of features enabled by default. When passing a list of features to
  `t:options/0`, it will override the default features.
  """
  @type feature() ::
          :twcc
          | :inbound_rtx
          | :outbound_rtx
          | :rtcp_reports

  @default_features [:twcc, :inbound_rtx, :outbound_rtx, :rtcp_reports]

  @typedoc """
  Options that can be passed to `ExWebRTC.PeerConnection.start_link/1`.

  * `controlling_process` - a pid of a process where all messages will be sent. `self()` by default,
  * `ice_servers` - list of STUN/TURN servers to use. By default, no servers are provided.
  * `ice_transport_policy` - which type of ICE candidates should be used. Defaults to `:all`.
  * `ice_ip_filter` - filter applied when gathering local candidates. By default, all IP addresses are accepted.
  * `ice_port_range` - range of ports that ICE will use for gathering host candidates. Defaults to ephemeral ports.
  * `audio_codecs` and `video_codecs` - lists of audio and video codecs to negotiate. By default these are equal to
  `default_audio_codecs/0` and `default_video_codecs/0`. To extend the list with your own codecs, do
  `audio_codecs: Configuration.default_audio_codecs() ++ my_codecs`.
  * `features` - feature flags for some of the ExWebRTC functinalities. Refer to `t:feature/0` for more information.
  * `rtp_header_extensions` - list of RTP header extensions to negotiate. Refer to `t:rtp_header_extension/0` for more information.
  * `rtcp_feedbacks` - list of RTCP feedbacks to negotiate. Refer to `t:rtcp_feedback/0` for more information.

  Instead of manually enabling an RTP header extension or an RTCP feedback, you may want to use a `t:feature/0`, which will enable
  necessary header extensions under the hood. If you enable RTCP feedback/RTP header extension corresponding to some feature (but not the feature itself),
  the functionality might not work (e.g. even if you enable TWCC RTP header extension and TWCC feedbacks, without enabling the `:twcc` features, TWCC feedbacks
  won't be sent).

  ExWebRTC does not allow for configuration of some of the W3C options, but behaves as if these values were used:
  * bundle_policy - `max_bundle`
  * ice_candidate_pool_size - `0`
  * rtcp_mux_policy - `require`
  """
  @type options() :: [
          controlling_process: Process.dest(),
          ice_servers: [ice_server()],
          ice_transport_policy: :relay | :all,
          ice_ip_filter: ICEAgent.ip_filter(),
          ice_port_range: Enumerable.t(non_neg_integer()),
          audio_codecs: [RTPCodecParameters.t()],
          video_codecs: [RTPCodecParameters.t()],
          features: [feature()],
          rtp_header_extensions: [rtp_header_extension()],
          rtcp_feedbacks: [rtcp_feedback()]
        ]

  @typedoc """
  `ExWebRTC.PeerConnection` configuration.

  It is created from options passed to `ExWebRTC.PeerConnection.start_link/1`.
  See `t:options/0` for more.
  """
  @type t() :: %__MODULE__{
          controlling_process: Process.dest(),
          ice_servers: [ice_server()],
          ice_transport_policy: :relay | :all,
          ice_ip_filter: (:inet.ip_address() -> boolean()) | nil,
          ice_port_range: Enumerable.t(non_neg_integer()),
          audio_codecs: [RTPCodecParameters.t()],
          video_codecs: [RTPCodecParameters.t()],
          audio_extensions: [Extmap.t()],
          video_extensions: [Extmap.t()],
          features: [feature()]
        }

  @enforce_keys [
    :controlling_process,
    :ice_ip_filter,
    :audio_extensions,
    :video_extensions
  ]
  defstruct @enforce_keys ++
              [
                ice_servers: [],
                ice_transport_policy: :all,
                ice_port_range: [0],
                audio_codecs: @default_audio_codecs,
                video_codecs: @default_video_codecs,
                features: @default_features
              ]

  @doc """
  Returns a list of default audio codecs.
  """
  @spec default_audio_codecs() :: [RTPCodecParameters.t()]
  def default_audio_codecs(), do: @default_audio_codecs

  @doc """
  Returns a list of default video codecs.
  """
  @spec default_video_codecs() :: [RTPCodecParameters.t()]
  def default_video_codecs(), do: @default_video_codecs

  @doc """
  Returns a list of default RTCP feedbacks include in SDP offer/answer.
  """
  @spec default_rtcp_feedbacks() :: [rtcp_feedback()]
  def default_rtcp_feedbacks(), do: @default_rtcp_feedbacks

  @doc """
  Returns a list of default RTP header extensions to include in SDP offer/answer.
  """
  @spec default_rtp_header_extensions() :: [rtp_header_extension()]
  def default_rtp_header_extensions(), do: @default_rtp_header_extensions

  @doc """
  Returns a list of PeerConnection features enabled by default.
  """
  @spec default_features() :: [feature()]
  def default_features(), do: @default_features

  @doc false
  @spec from_options!(options()) :: t()
  def from_options!(options) do
    extensions = Keyword.get(options, :rtp_header_extensions, @default_rtp_header_extensions)

    unless %{type: :all, uri: @mid_uri} in extensions do
      Logger.warning("""
      MID RTP header extension was not found in #{inspect(extensions)}.
      While this is correct, it is strongly recommended to include \
      MID RTP header extension to avoid any difficulties with packet demultiplexing.
      """)
    end

    {audio_extensions, video_extensions} =
      extensions
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        {%{type: :all, uri: uri}, id} -> [{:audio, uri, id}, {:video, uri, id}]
        {%{type: type, uri: uri}, id} -> [{type, uri, id}]
      end)
      |> Enum.map(fn {type, uri, id} -> {type, %Extmap{id: id, uri: uri}} end)
      |> Enum.split_with(fn {type, _extmap} -> type == :audio end)

    feedbacks = Keyword.get(options, :rtcp_feedbacks, @default_rtcp_feedbacks)

    options
    |> Keyword.put(:audio_extensions, Enum.map(audio_extensions, fn {_, ext} -> ext end))
    |> Keyword.put(:video_extensions, Enum.map(video_extensions, fn {_, ext} -> ext end))
    |> then(&struct(__MODULE__, &1))
    |> populate_feedbacks(feedbacks)
    |> add_features()
  end

  defp add_features(config) do
    %__MODULE__{features: features} = config

    features =
      if :inbound_rtx in features or :outbound_rtx in features do
        Enum.reject(features, &(&1 in [:inbound_rtx, :outbound_rtx])) ++ [:rtx]
      else
        features
      end

    features
    |> Enum.uniq()
    |> Enum.reduce(config, fn feature, config -> add_feature(feature, config) end)
  end

  defp add_feature(:twcc, config) do
    %__MODULE__{
      video_codecs: video_codecs,
      audio_codecs: audio_codecs,
      audio_extensions: audio_extensions,
      video_extensions: video_extensions
    } = config

    [free_id | _] = get_free_extension_ids(video_extensions ++ audio_extensions)
    video_extensions = add_extension(video_extensions, %Extmap{id: free_id, uri: @twcc_uri})
    audio_extensions = add_extension(audio_extensions, %Extmap{id: free_id, uri: @twcc_uri})

    audio_codecs = Enum.map(audio_codecs, &add_feedback(&1, :twcc))
    video_codecs = Enum.map(video_codecs, &add_feedback(&1, :twcc))

    %__MODULE__{
      config
      | video_codecs: video_codecs,
        audio_codecs: audio_codecs,
        video_extensions: video_extensions,
        audio_extensions: audio_extensions
    }
  end

  defp add_feature(:rtx, config) do
    %__MODULE__{
      video_extensions: video_extensions,
      audio_extensions: audio_extensions,
      audio_codecs: audio_codecs,
      video_codecs: video_codecs
    } = config

    video_codecs = Enum.map(video_codecs, &add_feedback(&1, :nack))

    [id | _] = get_free_extension_ids(video_extensions ++ audio_extensions)
    video_extensions = add_extension(video_extensions, %Extmap{id: id, uri: @rrid_uri})

    free_pts = get_free_payload_types(audio_codecs ++ video_codecs)

    {rtxs, _} =
      video_codecs
      |> Enum.reject(&rtx?/1)
      |> Enum.flat_map_reduce(free_pts, fn codec, pts ->
        if has_rtx?(codec, video_codecs) do
          {[], pts}
        else
          [pt | other_pts] = pts

          rtx = %RTPCodecParameters{
            mime_type: "video/rtx",
            payload_type: pt,
            clock_rate: codec.clock_rate,
            sdp_fmtp_line: %FMTP{pt: pt, apt: codec.payload_type}
          }

          {[rtx], other_pts}
        end
      end)

    %__MODULE__{config | video_codecs: video_codecs ++ rtxs, video_extensions: video_extensions}
  end

  defp add_feature(:rtcp_reports, config), do: config

  defp populate_feedbacks(config, feedbacks) do
    %__MODULE__{
      audio_codecs: audio_codecs,
      video_codecs: video_codecs
    } = config

    audio_codecs =
      audio_codecs
      |> Enum.map(fn codec ->
        feedbacks
        |> Enum.reject(&(&1.type == :video))
        |> Enum.reduce(codec, fn fb, codec -> add_feedback(codec, fb.feedback) end)
      end)

    video_codecs =
      video_codecs
      |> Enum.map(fn codec ->
        feedbacks
        |> Enum.reject(&(&1.type == :audio))
        |> Enum.reduce(codec, fn fb, codec -> add_feedback(codec, fb.feedback) end)
      end)

    %__MODULE__{config | audio_codecs: audio_codecs, video_codecs: video_codecs}
  end

  defp get_free_extension_ids(extensions) do
    used_ids = Enum.map(extensions, fn %Extmap{id: id} -> id end)
    Range.to_list(1..14) -- used_ids
  end

  defp get_free_payload_types(codecs) do
    used_pts = Enum.map(codecs, fn %RTPCodecParameters{payload_type: pt} -> pt end)
    Range.to_list(96..127) -- used_pts
  end

  defp add_extension(extensions, new_ext) do
    extensions
    |> Enum.find(fn %Extmap{uri: uri} -> uri == new_ext.uri end)
    |> case do
      nil -> extensions ++ [new_ext]
      _ext -> extensions
    end
  end

  defp add_feedback(codec, fb_type) do
    %RTPCodecParameters{rtcp_fbs: fbs, payload_type: pt} = codec

    if rtx?(codec) do
      codec
    else
      fb = %RTCPFeedback{pt: pt, feedback_type: fb_type}
      fbs = Enum.uniq([fb | fbs])
      %RTPCodecParameters{codec | rtcp_fbs: fbs}
    end
  end

  defp rtx?(codec), do: String.ends_with?(codec.mime_type, "/rtx")

  defp has_rtx?(codec, codecs) do
    Enum.any?(codecs, fn maybe_rtx ->
      rtx?(maybe_rtx) and maybe_rtx.sdp_fmtp_line.apt == codec.payload_type
    end)
  end

  @doc false
  @spec update(t(), ExSDP.t()) :: t()
  def update(config, sdp) do
    config
    |> update_extensions(sdp)
    |> update_codecs(sdp)
  end

  defp update_extensions(config, sdp) do
    # we assume that extension have the same id no matter the mline
    %__MODULE__{audio_extensions: audio_extensions, video_extensions: video_extensions} = config
    sdp_extensions = SDPUtils.get_extensions(sdp)
    free_ids = get_free_extension_ids(sdp_extensions)

    {audio_extensions, free_ids} =
      do_update_extensions(audio_extensions, sdp_extensions, free_ids)

    {video_extensions, _free_ids} =
      do_update_extensions(video_extensions, sdp_extensions, free_ids)

    %__MODULE__{config | audio_extensions: audio_extensions, video_extensions: video_extensions}
  end

  defp do_update_extensions(extensions, sdp_extensions, free_ids) do
    # we replace extension ids in config to ids from the SDP
    # in case we have an extension in config but not in SDP, we replace
    # its id to some free (not present in SDP) id, so it doesn't conflict
    Enum.map_reduce(extensions, free_ids, fn ext, free_ids ->
      sdp_extensions
      |> Enum.find(&(&1.uri == ext.uri))
      |> case do
        nil ->
          [id | rest] = free_ids
          {%Extmap{ext | id: id}, rest}

        other ->
          {%Extmap{ext | id: other.id}, free_ids}
      end
    end)
  end

  defp update_codecs(config, sdp) do
    %__MODULE__{audio_codecs: audio_codecs, video_codecs: video_codecs} = config
    sdp_codecs = SDPUtils.get_rtp_codec_parameters(sdp)
    free_pts = get_free_payload_types(sdp_codecs)

    {audio_codecs, free_pts} = do_update_codecs(audio_codecs, sdp_codecs, free_pts)
    {video_codecs, _free_pts} = do_update_codecs(video_codecs, sdp_codecs, free_pts)

    %__MODULE__{config | audio_codecs: audio_codecs, video_codecs: video_codecs}
  end

  defp do_update_codecs(codecs, sdp_codecs, free_pts) do
    # we replace codec payload types in config to payload types from SDP
    # both normal codecs and rtx (we also update apt FMTP attribute in rtxs)
    # other codecs that are present in config but not in SDP
    # are also updated with values from a pool of free payload types (not present in SDP)
    # to make sure they don't conflict
    {sdp_rtxs, sdp_codecs} = Enum.split_with(sdp_codecs, &rtx?/1)
    {rtxs, codecs} = Enum.split_with(codecs, &rtx?/1)

    {codecs, {free_pts, mapping}} =
      Enum.map_reduce(codecs, {free_pts, %{}}, fn codec, {free_pts, mapping} ->
        sdp_codecs
        |> Enum.find(
          &(String.downcase(&1.mime_type) == String.downcase(codec.mime_type) and
              &1.clock_rate == codec.clock_rate and
              &1.channels == codec.channels and fmtp_equal_soft?(codec, &1))
        )
        |> case do
          nil ->
            [pt | rest] = free_pts
            new_codec = do_update_codec(codec, pt)
            {new_codec, {rest, Map.put(mapping, codec.payload_type, pt)}}

          other ->
            new_codec = do_update_codec(codec, other.payload_type)
            {new_codec, {free_pts, Map.put(mapping, codec.payload_type, other.payload_type)}}
        end
      end)

    {rtxs, free_pts} =
      rtxs
      |> Enum.map(fn %RTPCodecParameters{sdp_fmtp_line: %FMTP{apt: apt} = fmtp} = rtx ->
        %RTPCodecParameters{rtx | sdp_fmtp_line: %FMTP{fmtp | apt: Map.fetch!(mapping, apt)}}
      end)
      |> Enum.map_reduce(free_pts, fn rtx, free_pts ->
        sdp_rtxs
        |> Enum.find(&(&1.sdp_fmtp_line.apt == rtx.sdp_fmtp_line.apt))
        |> case do
          nil ->
            [pt | rest] = free_pts
            rtx = do_update_codec(rtx, pt)
            {rtx, rest}

          other ->
            rtx = do_update_codec(rtx, other.payload_type)
            {rtx, free_pts}
        end
      end)

    {codecs ++ rtxs, free_pts}
  end

  defp do_update_codec(codec, new_pt) do
    %RTPCodecParameters{rtcp_fbs: fbs, sdp_fmtp_line: fmtp} = codec
    new_fbs = Enum.map(fbs, &%RTCPFeedback{&1 | pt: new_pt})
    new_fmtp = if(fmtp == nil, do: nil, else: %FMTP{fmtp | pt: new_pt})
    %RTPCodecParameters{codec | payload_type: new_pt, rtcp_fbs: new_fbs, sdp_fmtp_line: new_fmtp}
  end

  @doc false
  @spec intersect_codecs(t(), ExSDP.Media.t()) :: [RTPCodecParameters.t()]
  def intersect_codecs(config, mline) do
    # we assume that this function is called after
    # the config was updated based on the remote SDP
    # so the payload types (in codec_equal?) should match
    codecs =
      case mline.type do
        :audio -> config.audio_codecs
        :video -> config.video_codecs
      end

    mline
    |> SDPUtils.get_rtp_codec_parameters()
    |> Enum.flat_map(fn sdp_codec ->
      codecs
      |> Enum.find(&codec_equal?(&1, sdp_codec))
      |> case do
        nil ->
          []

        other ->
          fbs = Enum.filter(sdp_codec.rtcp_fbs, &(&1 in other.rtcp_fbs))
          [%RTPCodecParameters{sdp_codec | rtcp_fbs: fbs}]
      end
    end)
  end

  @doc false
  @spec codec_equal?(RTPCodecParameters.t(), RTPCodecParameters.t()) :: boolean()
  def codec_equal?(c1, c2) do
    String.downcase(c1.mime_type) == String.downcase(c2.mime_type) and
      c1.payload_type == c2.payload_type and
      c1.clock_rate == c2.clock_rate and
      c1.channels == c2.channels and fmtp_equal?(c1, c2)
  end

  defp fmtp_equal?(%{sdp_fmtp_line: nil}, _c2), do: true
  defp fmtp_equal?(_c1, %{sdp_fmtp_line: nil}), do: true
  defp fmtp_equal?(c1, c2), do: c1.sdp_fmtp_line == c2.sdp_fmtp_line

  defp fmtp_equal_soft?(%{sdp_fmtp_line: nil}, _c2), do: true
  defp fmtp_equal_soft?(_c1, %{sdp_fmtp_line: nil}), do: true

  defp fmtp_equal_soft?(c1, c2) do
    fmtp1 = %{c1.sdp_fmtp_line | pt: nil}
    fmtp2 = %{c2.sdp_fmtp_line | pt: nil}

    fmtp1 == fmtp2
  end

  @doc false
  @spec intersect_extensions(t(), ExSDP.Media.t()) :: [Extmap.t()]
  def intersect_extensions(config, mline) do
    extensions =
      case mline.type do
        :audio -> config.audio_extensions
        :video -> config.video_extensions
      end

    mline
    |> ExSDP.get_attributes(Extmap)
    |> Enum.flat_map(fn sdp_extension ->
      extensions
      |> Enum.find(
        &(&1.id == sdp_extension.id and
            &1.uri == sdp_extension.uri)
      )
      |> case do
        nil -> []
        _other -> [%Extmap{sdp_extension | direction: nil}]
      end
    end)
  end
end
