defmodule ExWebRTC.PeerConnection.Configuration do
  @moduledoc """
  `ExWebRTC.PeerConnection` configuration.
  """

  alias ExWebRTC.{RTPCodecParameters, SDPUtils}
  alias ExSDP.Attribute.{Extmap, FMTP, RTCPFeedback}

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
      payload_type: 45,
      mime_type: "video/AV1",
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

  @rtp_hdr_extensions %{
    :mid => %{media_type: :all, ext: %Extmap{id: 1, uri: "urn:ietf:params:rtp-hdrext:sdes:mid"}},
    :audio_level => %{
      media_type: :audio,
      ext: %Extmap{id: 2, uri: "urn:ietf:params:rtp-hdrext:ssrc-audio-level"}
    }
  }

  @mandatory_audio_rtp_hdr_exts Map.new([:mid], fn ext_shortcut ->
                                  extmap = Map.fetch!(@rtp_hdr_extensions, ext_shortcut).ext
                                  {extmap.uri, extmap}
                                end)

  @mandatory_video_rtp_hdr_exts Map.new([:mid], fn ext_shortcut ->
                                  extmap = Map.fetch!(@rtp_hdr_extensions, ext_shortcut).ext
                                  {extmap.uri, extmap}
                                end)

  @typedoc """
  Supported RTP header extensions.
  """
  @type rtp_hdr_extension() :: :audio_level

  @type ice_server() :: %{
          optional(:credential) => String.t(),
          optional(:username) => String.t(),
          :urls => [String.t()] | String.t()
        }

  @typedoc """
  Options that can be passed to `ExWebRTC.PeerConnection.start_link/1`.

  * `ice_servers` - list of STUN servers to use.
  TURN servers are not supported right now and will be filtered out.
  * `ice_ip_filter` - filter applied when gathering local candidates
  * `audio_codecs` - list of audio codecs to use.
  Use `default_audio_codecs/0` to get a list of default audio codecs.
  This option overrides default audio codecs.
  If you wish to add codecs to default ones do 
  `audio_codecs: Configuration.default_audio_codecs() ++ my_codecs`
  * `video_codecs` - the same as `audio_codecs` but for video.
  If you wish to e.g. only use AV1, pass as video_codecs:
  ```
    video_codecs: [
      %ExWebRTC.RTPCodecParameters{
        payload_type: 45,
        mime_type: "video/AV1",
        clock_rate: 90_000
      }
    ]
  ```
  * `rtp_hdr_extensions` - list of RTP header extensions to use.
  MID extension is enabled by default and cannot be turned off.
  If an extension can be used both for audio and video media, it
  will be added to every mline.
  If an extension is audio-only, it will only be added to audio mlines.
  If an extension is video-only, it will only be added to video mlines.

  Besides options listed above, ExWebRTC uses the following config:
  * bundle_policy - max_bundle
  * ice_candidate_pool_size - 0
  * ice_transport_policy - all
  * rtcp_mux_policy - require

  This config cannot be changed.
  """
  @type options() :: [
          ice_servers: [ice_server()],
          ice_ip_filter: (:inet.ip_address() -> boolean()),
          audio_codecs: [RTPCodecParameters.t()],
          video_codecs: [RTPCodecParameters.t()],
          rtp_hdr_extensions: [rtp_hdr_extension()]
        ]

  @typedoc false
  @type t() :: %__MODULE__{
          ice_servers: [ice_server()],
          ice_ip_filter: (:inet.ip_address() -> boolean()),
          audio_codecs: [RTPCodecParameters.t()],
          video_codecs: [RTPCodecParameters.t()],
          audio_rtp_hdr_exts: %{(uri :: String.t()) => Extmap.t()},
          video_rtp_hdr_exts: %{(uri :: String.t()) => Extmap.t()}
        }

  defstruct ice_servers: [],
            ice_ip_filter: nil,
            audio_codecs: @default_audio_codecs,
            video_codecs: @default_video_codecs,
            audio_rtp_hdr_exts: @mandatory_audio_rtp_hdr_exts,
            video_rtp_hdr_exts: @mandatory_video_rtp_hdr_exts

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

  @doc false
  @spec from_options!(options()) :: t()
  def from_options!(options) do
    options =
      options
      |> resolve_rtp_hdr_extensions()
      |> add_mandatory_rtp_hdr_extensions()
      # ATM, ExICE does not support relay via TURN
      |> reject_turn_servers()

    struct!(__MODULE__, options)
  end

  @doc false
  @spec supported_codec?(t(), RTPCodecParameters.t()) :: boolean()
  def supported_codec?(config, codec) do
    # This function doesn't check if rtcp-fb is supported.
    # Instead, `supported_rtcp_fb?` has to be used to filter out
    # rtcp-fb that are not supported.
    Enum.any?(config.audio_codecs ++ config.video_codecs, fn supported_codec ->
      %{supported_codec | rtcp_fbs: codec.rtcp_fbs} == codec
    end)
  end

  @doc false
  @spec supported_rtp_hdr_extension?(t(), Extmap.t(), :audio | :video) ::
          boolean()
  def supported_rtp_hdr_extension?(config, rtp_hdr_extension, media_type) do
    supported_uris =
      case media_type do
        :audio -> Map.keys(config.audio_rtp_hdr_exts)
        :video -> Map.keys(config.video_rtp_hdr_exts)
      end

    rtp_hdr_extension.uri in supported_uris
  end

  @doc false
  @spec supported_rtcp_fb?(t(), RTCPFeedback.t()) :: boolean()
  def supported_rtcp_fb?(_config, _rtcp_fb), do: false

  @doc false
  @spec update(t(), ExSDP.t()) :: t()
  def update(config, sdp) do
    sdp_extmaps = SDPUtils.get_extensions(sdp)
    sdp_codecs = SDPUtils.get_rtp_codec_parameters(sdp)

    {audio_exts, video_exts} =
      update_rtp_hdr_extensions(sdp_extmaps, config.audio_rtp_hdr_exts, config.video_rtp_hdr_exts)

    {audio_codecs, video_codecs} =
      update_codecs(sdp_codecs, config.audio_codecs, config.video_codecs)

    %__MODULE__{
      config
      | audio_rtp_hdr_exts: audio_exts,
        video_rtp_hdr_exts: video_exts,
        audio_codecs: audio_codecs,
        video_codecs: video_codecs
    }
  end

  defp update_rtp_hdr_extensions(sdp_extmaps, audio_exts, video_exts)
  defp update_rtp_hdr_extensions([], audio_exts, video_exts), do: {audio_exts, video_exts}

  defp update_rtp_hdr_extensions([extmap | sdp_extmaps], audio_exts, video_exts)
       when is_map_key(audio_exts, extmap.uri) do
    update_rtp_hdr_extensions(sdp_extmaps, Map.put(audio_exts, extmap.uri, extmap), video_exts)
  end

  defp update_rtp_hdr_extensions([extmap | sdp_extmaps], audio_exts, video_exts)
       when is_map_key(video_exts, extmap.uri) do
    update_rtp_hdr_extensions(sdp_extmaps, audio_exts, Map.put(video_exts, extmap.uri, extmap))
  end

  defp update_rtp_hdr_extensions([_extmap | sdp_extmaps], audio_exts, video_exts) do
    update_rtp_hdr_extensions(sdp_extmaps, audio_exts, video_exts)
  end

  defp update_codecs(sdp_codecs, audio_codecs, video_codecs)

  defp update_codecs([], audio_codecs, video_codecs) do
    {audio_codecs, video_codecs}
  end

  defp update_codecs(
         [%{mime_type: "audio/" <> _} = codec | sdp_codecs],
         audio_codecs,
         video_codecs
       ) do
    audio_codec =
      audio_codecs
      |> Stream.with_index()
      |> Enum.find(fn {audio_codec, _idx} ->
        # For the time of comparision, assume the same payload type and rtcp_fbs.
        # We don't want to take into account rtcp_fbs as they can be negotiated
        # i.e. we can reject those that are not supported by us.
        fmtp =
          if audio_codec.sdp_fmtp_line != nil and codec.sdp_fmtp_line != nil do
            %FMTP{audio_codec.sdp_fmtp_line | pt: codec.payload_type}
          else
            audio_codec.sdp_fmtp_line
          end

        audio_codec = %RTPCodecParameters{
          audio_codec
          | payload_type: codec.payload_type,
            sdp_fmtp_line: fmtp,
            rtcp_fbs: codec.rtcp_fbs
        }

        audio_codec == codec
      end)

    case audio_codec do
      nil ->
        update_codecs(sdp_codecs, audio_codecs, video_codecs)

      {audio_codec, idx} ->
        audio_codec = %RTPCodecParameters{
          audio_codec
          | payload_type: codec.payload_type,
            sdp_fmtp_line: codec.sdp_fmtp_line
        }

        audio_codecs = List.insert_at(audio_codecs, idx, audio_codec)
        update_codecs(sdp_codecs, audio_codecs, video_codecs)
    end
  end

  defp update_codecs(
         [%{mime_type: "video/" <> _} = codec | sdp_codecs],
         audio_codecs,
         video_codecs
       ) do
    video_codec =
      video_codecs
      |> Stream.with_index()
      |> Enum.find(fn {video_codec, _idx} ->
        fmtp =
          if video_codec.sdp_fmtp_line != nil and codec.sdp_fmtp_line != nil do
            %FMTP{video_codec.sdp_fmtp_line | pt: codec.payload_type}
          else
            video_codec.sdp_fmtp_line
          end

        video_codec = %RTPCodecParameters{
          video_codec
          | payload_type: codec.payload_type,
            sdp_fmtp_line: fmtp,
            rtcp_fbs: codec.rtcp_fbs
        }

        video_codec == codec
      end)

    case video_codec do
      nil ->
        update_codecs(sdp_codecs, audio_codecs, video_codecs)

      {video_codec, idx} ->
        video_codec = %RTPCodecParameters{
          video_codec
          | payload_type: codec.payload_type,
            sdp_fmtp_line: codec.sdp_fmtp_line
        }

        video_codecs = List.insert_at(video_codecs, idx, video_codec)
        update_codecs(sdp_codecs, audio_codecs, video_codecs)
    end
  end

  defp add_mandatory_rtp_hdr_extensions(options) do
    options
    |> Keyword.update(:audio_rtp_hdr_exts, %{}, fn exts ->
      Map.merge(exts, @mandatory_audio_rtp_hdr_exts)
    end)
    |> Keyword.update(:video_rtp_hdr_exts, %{}, fn exts ->
      Map.merge(exts, @mandatory_video_rtp_hdr_exts)
    end)
  end

  defp resolve_rtp_hdr_extensions(options) do
    {audio_exts, video_exts} =
      Keyword.get(options, :rtp_hdr_extensions, [])
      |> Enum.reduce({%{}, %{}}, fn ext, {audio_exts, video_exts} ->
        resolved_ext = Map.fetch!(@rtp_hdr_extensions, ext)

        case resolved_ext.media_type do
          :audio ->
            audio_exts = Map.put(audio_exts, resolved_ext.ext.uri, resolved_ext.ext)
            {audio_exts, video_exts}

          :all ->
            audio_exts = Map.put(audio_exts, resolved_ext.ext.uri, resolved_ext.ext)
            video_exts = Map.put(video_exts, resolved_ext.ext.uri, resolved_ext.ext)
            {audio_exts, video_exts}
        end
      end)

    options
    |> Keyword.put(:audio_rtp_hdr_exts, audio_exts)
    |> Keyword.put(:video_rtp_hdr_exts, video_exts)
    |> Keyword.delete(:rtp_hdr_extensions)
  end

  defp reject_turn_servers(options) do
    Keyword.update(options, :ice_servers, [], fn ice_servers ->
      ice_servers
      |> Enum.flat_map(&List.wrap(&1.urls))
      |> Enum.filter(&String.starts_with?(&1, "stun:"))
    end)
  end
end
