defmodule ExWebRTC.PeerConnection.Configuration do
  @moduledoc """
  `ExWebRTC.PeerConnection` configuration.
  """

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

  Keep in mind that you are free to pass any RTP header extension, but the underlying
  RTP parsing library (`ex_rtp`) might not support it. In such case, you have to parse the
  header extension yourself.

  The `id` passed to `extmap` will be used to create an SDP offer, but it might be overridden by the
  remote SDP offer (assuming that Elixir WebRTC's PeerConnection is the answerer). Fetch the config
  from the PeerConnection after a negotiation to obtain actual ids.

  This header extension will be included in all of the m-lines of provided `type` (or for both audio and video
  if `:all` is used).

  By default, only the `urn:ietf:params:rtp-hdrext:sdes:mid` is included for both audio and video
  (and is mandatory, thus must no be turned off).

  Be aware that some of the features (see `t:feature/0`) can implicitly add RTP header extensions).
  """
  @type header_extension() :: %{
          type: :audio | :video | :all,
          extmap: ExSDP.Attribute.Extmap.t()
        }

  @default_header_extensions [
    %{
      type: :all,
      extmap: %Extmap{id: 1, uri: @mid_uri}
    }
  ]

  @typedoc """
  RTCP feedbacks that are going to be included in the SDP offer/answer.

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
          header_extensions: [header_extension()],
          feedbacks: [rtcp_feedback()],
          features: [feature()]
        }

  @enforce_keys [:controlling_process, :ice_ip_filter]
  defstruct @enforce_keys ++
              [
                ice_servers: [],
                ice_transport_policy: :all,
                audio_codecs: @default_audio_codecs,
                video_codecs: @default_video_codecs,
                header_extensions: @default_header_extensions,
                feedbacks: @default_feedbacks,
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
    config =
      options
      |> Keyword.put_new(:controlling_process, self())
      |> Keyword.put_new(:ice_ip_filter, fn _ -> true end)
      |> then(&struct(__MODULE__, &1))
      |> add_features()

    ensure_valid(config)
    config
  end

  defp add_features(config) do
    %__MODULE__{features: features} = config

    features
    |> Enum.uniq()
    |> Enum.reduce(config, fn feature, config -> add_feature(feature, config) end)
  end

  defp add_feature(:twcc, config) do
    %__MODULE__{
      header_extensions: header_extensions,
      feedbacks: feedbacks
    } = config

    header_extensions =
      header_extensions
      |> Enum.find_index(fn %{extmap: %Extmap{uri: uri}} -> uri == @twcc_uri end)
      |> case do
        nil ->
          [free_id | _] = get_free_extension_ids(header_extensions)
          [%{type: :all, extmap: %Extmap{id: free_id, uri: @twcc_uri}} | header_extensions]

        idx ->
          List.update_at(header_extensions, idx, &%{&1 | type: :all})
      end

    feedbacks =
      feedbacks
      |> Enum.find_index(fn %{feedback: fb} -> fb == :twcc end)
      |> case do
        nil -> [%{type: :all, feedback: :twcc} | feedbacks]
        idx -> List.update_at(feedbacks, idx, &%{&1 | type: :all})
      end

    %__MODULE__{config | header_extensions: header_extensions, feedbacks: feedbacks}
  end

  defp add_feature(feature, config) when feature in [:inbound_rtx, :outbound_rtx] do
    %__MODULE__{
      audio_codecs: audio_codecs,
      video_codecs: video_codecs,
      feedbacks: feedbacks
    } = config

    feedbacks =
      feedbacks
      |> Enum.find_index(fn %{feedback: fb} -> fb == :nack end)
      |> case do
        nil ->
          [%{type: :video, feedback: :nack} | feedbacks]

        idx ->
          List.update_at(
            feedbacks,
            idx,
            &%{&1 | type: if(&1.type == :audio, do: :all, else: &1.type)}
          )
      end

    free_pts = get_free_payload_types(audio_codecs, video_codecs)

    {rtxs, _} =
      video_codecs
      |> Enum.reject(fn %RTPCodecParameters{mime_type: mt} -> String.starts_with?(mt, "rtx/") end)
      |> Enum.flat_map_reduce(free_pts, fn codec, pts ->
        video_codecs
        |> Enum.any?(fn
          %RTPCodecParameters{mime_type: "rtx/" <> _, sdp_fmtp_line: %FMTP{apt: apt}} ->
            apt == codec.payload_type

          _other ->
            false
        end)
        |> case do
          false ->
            [pt | other_pts] = pts

            rtx = %RTPCodecParameters{
              mime_type: "rtx/video",
              payload_type: pt,
              clock_rate: codec.clock_rate,
              sdp_fmtp_line: %FMTP{pt: pt, apt: codec.payload_type}
            }

            {[rtx], other_pts}

          true ->
            {[], pts}
        end
      end)

    %__MODULE__{config | feedbacks: feedbacks, video_codecs: video_codecs ++ rtxs}
  end

  defp add_feature(:inbound_simulcast, config) do
    %__MODULE__{header_extensions: header_extensions} = config
    [id1, id2 | _] = get_free_extension_ids(header_extensions)

    header_extensions =
      header_extensions
      |> Enum.find_index(fn %{extmap: %Extmap{uri: uri}} -> uri == @rid_uri end)
      |> case do
        nil ->
          [%{type: :video, extmap: %Extmap{id: id1, uri: @rid_uri}} | header_extensions]

        idx ->
          List.update_at(
            header_extensions,
            idx,
            &%{&1 | type: if(&1.type == :audio, do: :all, else: &1.type)}
          )
      end

    header_extensions =
      header_extensions
      |> Enum.find_index(fn %{extmap: %Extmap{uri: uri}} -> uri == @rrid_uri end)
      |> case do
        nil ->
          [%{type: :video, extmap: %Extmap{id: id2, uri: @rrid_uri}} | header_extensions]

        idx ->
          List.update_at(
            header_extensions,
            idx,
            &%{&1 | type: if(&1.type == :audio, do: :all, else: &1.type)}
          )
      end

    %__MODULE__{config | header_extensions: header_extensions}
  end

  defp add_feature(:reports, config), do: config

  defp get_free_extension_ids(header_extensions) do
    used_ids = Enum.map(header_extensions, fn %{extmap: %Extmap{id: id}} -> id end)
    Range.to_list(1..14) -- used_ids
  end

  defp get_free_payload_types(audio_codecs, video_codecs) do
    used_pts =
      Enum.map(audio_codecs ++ video_codecs, fn %RTPCodecParameters{payload_type: pt} -> pt end)

    Range.to_list(96..127) -- used_pts
  end

  defp ensure_valid(config) do
    %__MODULE__{
      audio_codecs: audio_codecs,
      video_codecs: video_codecs,
      header_extensions: header_extensions,
      feedbacks: feedbacks
    } = config

    # this function does not test very throughtly, but focuses
    # on the most error-prone areas
    # it may be extended if deemed necessary

    (audio_codecs ++ video_codecs)
    |> Enum.map(fn %RTPCodecParameters{payload_type: pt} -> pt end)
    |> ensure_uniq!("Detected duplicate payload types in provided codecs")

    (audio_codecs ++ video_codecs)
    |> Enum.map(fn %RTPCodecParameters{mime_type: mt, clock_rate: cr, sdp_fmtp_line: fmtp} ->
      {mt, cr, fmtp}
    end)
    |> ensure_uniq!("Detected duplicate codecs")

    header_extensions
    |> Enum.map(fn %{extmap: extmap} -> extmap.id end)
    |> ensure_uniq!("Detected duplicate RTP header extension ids")

    feedbacks
    |> Enum.map(fn %{feedback: feedback} -> feedback end)
    |> ensure_uniq!("Detected duplicate RTCP feedbacks")

    header_extensions
    |> Enum.find(fn %{extmap: %Extmap{uri: uri}, type: type} ->
      uri == @mid_uri and type == :all
    end)
    |> case do
      nil -> raise("Mandatory MID RTP header extension not found")
      _other -> :ok
    end

    feedbacks
    |> Enum.map(fn %{feedback: feedback} -> feedback end)
    |> ensure_uniq!("Detected duplicate RTCP feedbacks")
  end

  defp ensure_uniq!(elems, error_msg) do
    elems
    |> Enum.reduce(%{}, fn x, acc -> Map.update(acc, x, 1, &(&1 + 1)) end)
    |> Enum.any?(fn {_k, v} -> v != 1 end)
    |> case do
      true -> raise(error_msg)
      false -> :ok
    end
  end

  # @doc false
  # @spec supported_codec?(t(), RTPCodecParameters.t()) :: boolean()
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

  # @doc false
  # @spec update(t(), ExSDP.t()) :: t()
  def update(config, sdp) do
    # sdp_extmaps = SDPUtils.get_extensions(sdp)
    #
    # {sdp_rtx, sdp_codecs} =
    #   sdp
    #   |> SDPUtils.get_rtp_codec_parameters()
    #   |> Enum.split_with(&String.ends_with?(&1.mime_type, "rtx"))
    #
    # {audio_exts, video_exts} =
    #   update_rtp_hdr_extensions(sdp_extmaps, config.audio_rtp_hdr_exts, config.video_rtp_hdr_exts)
    #
    # {audio_codecs, video_codecs} =
    #   update_codecs(sdp_codecs, sdp_rtx, config.audio_codecs, config.video_codecs)

    # %__MODULE__{
    #   config
    #   | audio_rtp_hdr_exts: audio_exts,
    #     video_rtp_hdr_exts: video_exts,
    #     audio_codecs: audio_codecs,
    #     video_codecs: video_codecs
    # }
    config
  end

  defp update_rtp_hdr_extensions(sdp_extmaps, audio_exts, video_exts)
  defp update_rtp_hdr_extensions([], audio_exts, video_exts), do: {audio_exts, video_exts}

  defp update_rtp_hdr_extensions([extmap | sdp_extmaps], audio_exts, video_exts) do
    audio_exts = update_exts(audio_exts, extmap)
    video_exts = update_exts(video_exts, extmap)

    update_rtp_hdr_extensions(sdp_extmaps, audio_exts, video_exts)
  end

  defp update_exts(exts, extmap) when is_map_key(exts, extmap.uri),
    do: Map.put(exts, extmap.uri, %Extmap{extmap | direction: nil})

  defp update_exts(exts, _extmap), do: exts

  defp update_codecs(sdp_codecs, sdp_rtx, audio_codecs, video_codecs)

  defp update_codecs([], _sdp_rtx, audio_codecs, video_codecs) do
    {audio_codecs, video_codecs}
  end

  defp update_codecs([sdp_codec | sdp_codecs], sdp_rtx, audio_codecs, video_codecs) do
    type =
      case sdp_codec.mime_type do
        "audio/" <> _ -> :audio
        "video/" <> _ -> :video
      end

    codecs = if type == :audio, do: audio_codecs, else: video_codecs

    codec =
      codecs
      |> Enum.with_index()
      |> Enum.find(fn {codec, _idx} ->
        # For the time of comparison, assume the same payload type and rtcp_fbs and fmtp.
        # We don't want to take into account rtcp_fbs as they can be negotiated
        # i.e. we can reject those that are not supported by us.
        codec = %RTPCodecParameters{
          codec
          | payload_type: sdp_codec.payload_type,
            sdp_fmtp_line: sdp_codec.sdp_fmtp_line,
            rtcp_fbs: sdp_codec.rtcp_fbs
        }

        codec == sdp_codec
      end)

    case codec do
      nil ->
        update_codecs(sdp_codecs, sdp_rtx, audio_codecs, video_codecs)

      {codec, idx} ->
        codecs = update_rtx(codecs, sdp_rtx, codec.payload_type, sdp_codec.payload_type)

        fmtp =
          if codec.sdp_fmtp_line != nil do
            %{codec.sdp_fmtp_line | pt: sdp_codec.payload_type}
          else
            nil
          end

        codec = %RTPCodecParameters{
          codec
          | payload_type: sdp_codec.payload_type,
            sdp_fmtp_line: fmtp
        }

        codecs = List.replace_at(codecs, idx, codec)

        case type do
          :audio -> update_codecs(sdp_codecs, sdp_rtx, codecs, video_codecs)
          :video -> update_codecs(sdp_codecs, sdp_rtx, audio_codecs, codecs)
        end
    end
  end

  defp update_rtx(codecs, sdp_rtx, old_pt, new_pt) do
    new_rtx = Enum.find(sdp_rtx, fn codec -> codec.sdp_fmtp_line.apt == new_pt end)

    rtx =
      codecs
      |> Enum.with_index()
      |> Enum.find(fn {codec, _idx} ->
        String.ends_with?(codec.mime_type, "rtx") and codec.sdp_fmtp_line.apt == old_pt
      end)

    case rtx do
      {_rtx, idx} when new_rtx != nil ->
        List.replace_at(codecs, idx, new_rtx)

      {rtx, idx} ->
        fmtp = %{rtx.sdp_fmtp_line | apt: new_pt}
        List.replace_at(codecs, idx, %RTPCodecParameters{rtx | sdp_fmtp_line: fmtp})

      nil ->
        codecs
    end
  end

  # defp add_mandatory_rtp_hdr_extensions(options) do
  #   options
  #   |> Keyword.update(:audio_rtp_hdr_exts, %{}, fn exts ->
  #     Map.merge(exts, @mandatory_audio_rtp_hdr_exts)
  #   end)
  #   |> Keyword.update(:video_rtp_hdr_exts, %{}, fn exts ->
  #     Map.merge(exts, @mandatory_video_rtp_hdr_exts)
  #   end)
  # end

  # defp resolve_rtp_hdr_extensions(options) do
  #   {audio_exts, video_exts} =
  #     Keyword.get(options, :rtp_hdr_extensions, [])
  #     |> Enum.reduce({%{}, %{}}, fn ext, {audio_exts, video_exts} ->
  #       resolved_ext = Map.fetch!(@rtp_hdr_extensions, ext)
  #
  #       case resolved_ext.media_type do
  #         :audio ->
  #           audio_exts = Map.put(audio_exts, resolved_ext.ext.uri, resolved_ext.ext)
  #           {audio_exts, video_exts}
  #
  #         :all ->
  #           audio_exts = Map.put(audio_exts, resolved_ext.ext.uri, resolved_ext.ext)
  #           video_exts = Map.put(video_exts, resolved_ext.ext.uri, resolved_ext.ext)
  #           {audio_exts, video_exts}
  #       end
  #     end)
  #
  #   options
  #   |> Keyword.put(:audio_rtp_hdr_exts, audio_exts)
  #   |> Keyword.put(:video_rtp_hdr_exts, video_exts)
  #   |> Keyword.delete(:rtp_hdr_extensions)
  # end
end
