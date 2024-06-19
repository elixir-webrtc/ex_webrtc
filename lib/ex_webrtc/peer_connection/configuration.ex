defmodule ExWebRTC.PeerConnection.Configuration do
  @moduledoc """
  `ExWebRTC.PeerConnection` configuration.
  """

  require Logger

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
      channels: 2,
      sdp_fmtp_line: %FMTP{pt: 111, minptime: 10, useinbandfec: true}
    }
  ]

  @default_video_codecs [
    %RTPCodecParameters{
      payload_type: 96,
      mime_type: "video/VP8",
      clock_rate: 90_000
    },
    %RTPCodecParameters{
      payload_type: 98,
      mime_type: "video/H264",
      clock_rate: 90_000,
      sdp_fmtp_line: %FMTP{
        pt: 98,
        level_asymmetry_allowed: true,
        packetization_mode: 1,
        profile_level_id: 0x42001F
      }
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

  By default, only the `urn:ietf:params:rtp-hdrext:sdes:mid` is included for both audio and video
  (and is mandatory, thus must no be turned off).

  Be aware that some of the features (see `t:feature/0`) can implicitly add RTP header extensions).
  """
  @type header_extension() :: %{
          type: :audio | :video | :all,
          uri: String.t()
        }

  @default_header_extensions [%{type: :all, uri: @mid_uri}]

  @typedoc """
  RTCP feedbacks that are going to be added by default to all of the codecs.

  All of the supported types are included in the SDP offer/answer by default for video, only the `:twcc` for audio.
  Use `Configuration.default_feedbacks() - [some_feedback]` when passing it to `t:options/0` to
  disable `some_feedback`.

  Be aware that some of the features (see `t:feature/0`) can implicitly add RTCP feedbacks.
  """
  @type rtcp_feedback() :: %{
          type: :audio | :video | :all,
          feedback: :nack | :fir | :pli | :twcc
        }

  @default_feedbacks [
    %{type: :video, feedback: :fir},
    %{type: :video, feedback: :pli}
  ]

  @typedoc """
  Features provided by the ExWebRTC's PeerConnection:

  * `:twcc` - ExWebRTC's PeerConnection will generate TWCC RTCP feedbacks based on incoming packets and
  send them to the remote peer (implicitly adds the `http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01` to negotiated
  RTP header extensions and `:twcc` RTCP feedback to all of the negotiated codecs, both audio and video).
  * `:inbound_rtx` - ExWebRTC's PeerConnection will generate NACK RTCP feedbacks in response to missing incoming video packets and properly handle incoming
  retransmissions (implicitly adds the `:nack` RTCP feedback and a maching `a=rtpmap:[id] rtx/[type]` attribute for every negotiated video codec).
  * `:outbound_rtx` - ExWebRTC's PeerConnection will respond to incoming NACK RTCP feedbacks and retransmit packets accordingly (implicitly adds the same
  attributes as `:inbound_rtx`).
  * `:inbound_simulcast` - ExWebRTC's will positively respond to SDP offers with Simulcast and handle incoming simulcast packets (implicitly adds
  `urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id` and `urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id` RTP header extensions to all of the negotiated video
  m-lines).
  * `:reports` - ExWebRTC's PeerConnection will generate and send RTCP Sender and/or Receiver reports based on incoming/send RTP packets.

  By default, all of the features are enabled. Use `Configuration.default_features() -- [some_feature]` when
  passing `t:options/0` to disable `some_feature`.
  """
  @type feature() ::
          :twcc
          | :inbound_rtx
          | :outbound_rtx
          | :inbound_simulcast
          | :reports

  @default_features [:twcc, :inbound_rtx, :outbound_rtx, :inbound_simulcast, :reports]

  @typedoc """
  Options that can be passed to `ExWebRTC.PeerConnection.start_link/1`.

  * `controlling_process` - a pid of a process where all messages will be sent. `self()` by default,
  * `ice_servers` - list of STUN/TURN servers to use. By default, no servers are provided.
  * `ice_transport_policy` - which type of ICE candidates should be used. Defaults to `:all`.
  * `ice_ip_filter` - filter applied when gathering local candidates. By default, all IP addresses are accepted.
  * `audio_codecs` and `video_codecs` - lists of audio and video codecs to negotiate. By default these are equal to
  `default_audio_codecs/0` and `default_video_codecs/0`. To extend the list with your own codecs, do
  `audio_codecs: Configuration.default_audio_codecs() ++ my_codecs`.
  * `header_extensions` - list of RTP header extensions to negotiate. Refer to `t:header_extension/0` for more information.
  * `feedbacks` - list of RTCP feedbacks to negotiate. Refer to `t:rtcp_feedback/0` for more information.
  * `features` - feature flags for some of the ExWebRTC functinalities. Refer to `t:feature/0` for more information.

  ExWebRTC does not allow for configuration of some of the W3C options, but behaves as if these values were used:
  * bundle_policy - `max_bundle`
  * ice_candidate_pool_size - `0`
  * rtcp_mux_policy - `require`
  """
  @type options() :: [
          controlling_process: Process.dest(),
          ice_servers: [ice_server()],
          ice_transport_policy: :relay | :all,
          ice_ip_filter: (:inet.ip_address() -> boolean()),
          audio_codecs: [RTPCodecParameters.t()],
          video_codecs: [RTPCodecParameters.t()],
          header_extensions: [header_extension()],
          feedbacks: [rtcp_feedback()],
          features: [feature()]
        ]

  @typedoc false
  @type t() :: %__MODULE__{
          ice_servers: [ice_server()],
          ice_transport_policy: :relay | :all,
          ice_ip_filter: (:inet.ip_address() -> boolean()),
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
  @spec default_feedbacks() :: [rtcp_feedback()]
  def default_feedbacks(), do: @default_feedbacks

  @doc """
  Returns a list of default RTP header extensions to include in SDP offer/answer.
  """
  @spec default_header_extensions() :: [header_extension()]
  def default_header_extensions(), do: @default_header_extensions

  @doc false
  @spec from_options!(options()) :: t()
  def from_options!(options) do
    extensions = Keyword.get(options, :header_extensions, @default_header_extensions)

    unless %{type: :all, uri: @mid_uri} in extensions do
      raise "Mandatory MID RTP header extensions was not found in #{inspect(extensions)}"
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

    feedbacks = Keyword.get(options, :feedbacks, @default_feedbacks)

    options
    |> Keyword.put_new(:controlling_process, self())
    |> Keyword.put_new(:ice_ip_filter, fn _ -> true end)
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
      audio_codecs: audio_codecs,
      video_codecs: video_codecs
    } = config

    video_codecs = Enum.map(video_codecs, &add_feedback(&1, :nack))

    free_pts = get_free_payload_types(audio_codecs ++ video_codecs)

    {rtxs, _} =
      video_codecs
      |> Enum.reject(&rtx?/1)
      |> Enum.flat_map_reduce(free_pts, fn codec, pts ->
        video_codecs
        |> Enum.any?(fn maybe_rtx ->
          rtx?(maybe_rtx) and maybe_rtx.sdp_fmtp_line.apt == codec.payload_type
        end)
        |> case do
          false ->
            [pt | other_pts] = pts

            rtx = %RTPCodecParameters{
              mime_type: "video/rtx",
              payload_type: pt,
              clock_rate: codec.clock_rate,
              sdp_fmtp_line: %FMTP{pt: pt, apt: codec.payload_type}
            }

            {[rtx], other_pts}

          true ->
            {[], pts}
        end
      end)

    %__MODULE__{config | video_codecs: video_codecs ++ rtxs}
  end

  defp add_feature(:inbound_simulcast, config) do
    %__MODULE__{video_extensions: video_extensions, audio_extensions: audio_extensions} = config
    [id1, id2 | _] = get_free_extension_ids(video_extensions ++ audio_extensions)

    audio_extensions = add_extension(audio_extensions, %Extmap{id: id1, uri: @rid_uri})
    video_extensions = add_extension(video_extensions, %Extmap{id: id1, uri: @rid_uri})

    audio_extensions = add_extension(audio_extensions, %Extmap{id: id2, uri: @rrid_uri})
    video_extensions = add_extension(video_extensions, %Extmap{id: id2, uri: @rrid_uri})

    %__MODULE__{config | audio_extensions: audio_extensions, video_extensions: video_extensions}
  end

  defp add_feature(:reports, config), do: config

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
    (Range.to_list(1..14) -- used_ids) |> Enum.uniq()
  end

  defp get_free_payload_types(codecs) do
    used_pts = Enum.map(codecs, fn %RTPCodecParameters{payload_type: pt} -> pt end)
    (Range.to_list(96..127) -- used_pts) |> Enum.uniq()
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

  @doc false
  @spec update(t(), ExSDP.t()) :: t()
  def update(config, sdp) do
    config
    |> update_header_extensions(sdp)
    |> update_codecs(sdp)
  end

  defp update_header_extensions(config, sdp) do
    # we assume that extension have the same id no matter the mline
    %__MODULE__{audio_extensions: audio_extensions, video_extensions: video_extensions} = config
    sdp_extensions = SDPUtils.get_extensions(sdp)
    free_ids = get_free_extension_ids(sdp_extensions)

    {audio_extensions, free_ids} =
      do_update_header_extensions(audio_extensions, sdp_extensions, free_ids)

    {video_extensions, _free_ids} =
      do_update_header_extensions(video_extensions, sdp_extensions, free_ids)

    %__MODULE__{config | audio_extensions: audio_extensions, video_extensions: video_extensions}
  end

  defp do_update_header_extensions(extensions, sdp_extensions, free_ids) do
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
    {sdp_rtxs, sdp_codecs} = Enum.split_with(sdp_codecs, &String.ends_with?(&1.mime_type, "/rtx"))
    {rtxs, codecs} = Enum.split_with(codecs, &String.ends_with?(&1.mime_type, "/rtx"))

    {codecs, {free_pts, mapping}} =
      Enum.map_reduce(codecs, {free_pts, %{}}, fn codec, {free_pts, mapping} ->
        sdp_codecs
        |> Enum.find(
          &(&1.mime_type == codec.mime_type and
              &1.clock_rate == codec.clock_rate and
              &1.channels == codec.channels)
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

  # @doc false
  @spec supported_codec?(t(), RTPCodecParameters.t()) :: boolean()
  def supported_codec?(config, codec) do
    # This function doesn't check if rtcp-fb is supported.
    # Instead, `supported_rtcp_fb?` has to be used to filter out
    # rtcp-fb that are not supported.
    # TODO: this function doesn't compare fmtp at all
    Enum.any?(config.audio_codecs ++ config.video_codecs, fn supported_codec ->
      # For the purposes of comparison, lowercase mime check
      %{
        supported_codec
        | mime_type: String.downcase(supported_codec.mime_type),
          rtcp_fbs: codec.rtcp_fbs,
          sdp_fmtp_line: codec.sdp_fmtp_line
      } == %{
        codec
        | mime_type: String.downcase(codec.mime_type)
      }
    end)
  end

  # @doc false
  # @spec supported_rtp_hdr_extension?(t(), Extmap.t(), :audio | :video) ::
  #         boolean()
  def supported_rtp_hdr_extension?(config, rtp_hdr_extension, media_type) do
    supported_uris =
      case media_type do
        :audio -> Map.keys(config.audio_rtp_hdr_exts)
        :video -> Map.keys(config.video_rtp_hdr_exts)
      end

    rtp_hdr_extension.uri in supported_uris
  end

  # @doc false
  # @spec supported_rtcp_fb?(t(), RTCPFeedback.t()) :: boolean()
  def supported_rtcp_fb?(_config, _rtcp_fb), do: false
end
