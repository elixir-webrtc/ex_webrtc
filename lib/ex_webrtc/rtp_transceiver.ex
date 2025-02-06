defmodule ExWebRTC.RTPTransceiver do
  @moduledoc """
  Implementation of the [RTCRtpTransceiver](https://www.w3.org/TR/webrtc/#dom-rtcrtptransceiver).
  """

  require Logger

  alias ExWebRTC.{
    MediaStreamTrack,
    PeerConnection.Configuration,
    RTPCodecParameters,
    RTPReceiver,
    RTPSender,
    SDPUtils,
    Utils
  }

  alias ExRTCP.Packet.{ReceiverReport, SenderReport, TransportFeedback.NACK, PayloadFeedback.PLI}

  @report_interval 1000
  @nack_interval 100

  @type id() :: integer()

  @typedoc false
  @type transceiver() :: %{
          id: id(),
          mid: String.t() | nil,
          mline_idx: non_neg_integer() | nil,
          direction: direction(),
          current_direction: direction() | nil,
          fired_direction: direction() | nil,
          kind: kind(),
          header_extensions: [ExSDP.Attribute.Extmap.t()],
          codecs: [RTPCodecParameters.t()],
          receiver: RTPReceiver.receiver(),
          sender: RTPSender.sender(),
          stopping: boolean(),
          stopped: boolean(),
          added_by_add_track: boolean()
        }

  @typedoc """
  Possible directions of the transceiver.

  For the exact meaning, refer to the [RTCRtpTransceiver: direction property](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpTransceiver/direction).
  """
  @type direction() :: :sendonly | :recvonly | :sendrecv | :inactive | :stopped

  @typedoc """
  Possible types of media that a transceiver can handle.
  """
  @type kind() :: :audio | :video

  @typedoc """
  Struct representing a transceiver.

  The fields mostly match these of [RTCRtpTransceiver](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpTransceiver),
  except for:
  * `id` - to uniquely identify the transceiver.
  * `kind` - kind of the handled media, added for convenience.
  * `codecs` and `header_extensions` - codecs and RTP header extensions that the transceiver can handle.
  """
  @type t() :: %__MODULE__{
          id: id(),
          kind: kind(),
          current_direction: direction() | nil,
          direction: direction(),
          mid: String.t() | nil,
          stopping: boolean(),
          stopped: boolean(),
          receiver: RTPReceiver.t(),
          sender: RTPSender.t(),
          header_extensions: [ExSDP.Attribute.Extmap.t()],
          codecs: [RTPCodecParameters.t()]
        }

  @enforce_keys [
    :id,
    :kind,
    :direction,
    :current_direction,
    :mid,
    :stopping,
    :stopped,
    :receiver,
    :sender,
    :header_extensions,
    :codecs
  ]
  defstruct @enforce_keys

  @doc false
  @spec to_struct(transceiver()) :: t()
  def to_struct(transceiver) do
    sender = RTPSender.to_struct(transceiver.sender)
    receiver = RTPReceiver.to_struct(transceiver.receiver)

    transceiver
    |> Map.take([
      :id,
      :kind,
      :direction,
      :current_direction,
      :mid,
      :header_extensions,
      :codecs,
      :stopping,
      :stopped
    ])
    |> Map.merge(%{sender: sender, receiver: receiver})
    |> then(&struct!(__MODULE__, &1))
  end

  @doc false
  @spec new(kind(), MediaStreamTrack.t() | nil, Configuration.t(), Keyword.t()) :: transceiver()
  def new(kind, sender_track, config, options) do
    direction = Keyword.get(options, :direction, :sendrecv)

    {header_extensions, codecs} =
      case kind do
        :audio -> {config.audio_extensions, config.audio_codecs}
        :video -> {config.video_extensions, config.video_codecs}
      end

    track = MediaStreamTrack.new(kind)

    id = Utils.generate_id()

    if :rtcp_reports in config.features do
      send(self(), {:send_reports, id})
    end

    if kind == :video and :inbound_rtx in config.features do
      send(self(), {:send_nacks, id})
    end

    receiver = RTPReceiver.new(track, codecs, header_extensions, config.features)

    sender = RTPSender.new(sender_track, options[:ssrc], options[:rtx_ssrc], config.features)

    %{
      id: id,
      direction: direction,
      current_direction: nil,
      fired_direction: nil,
      mid: nil,
      mline_idx: nil,
      kind: kind,
      receiver: receiver,
      sender: sender,
      codecs: codecs,
      header_extensions: header_extensions,
      added_by_add_track: Keyword.get(options, :added_by_add_track, false),
      stopping: false,
      stopped: false
    }
  end

  @doc false
  @spec from_mline(
          ExSDP.Media.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Configuration.t()
        ) :: transceiver()
  def from_mline(mline, mline_idx, ssrc, rtx_ssrc, config) do
    header_extensions = Configuration.intersect_extensions(config, mline)
    codecs = Configuration.intersect_codecs(config, mline)

    if codecs == [] do
      rtpmap = ExSDP.get_attribute(mline, :rtpmap)

      Logger.debug(
        "No valid codecs for \"#{rtpmap}\" found in registered %ExWebRTC.PeerConnection.Configuration{}"
      )
    end

    {:mid, mid} = ExSDP.get_attribute(mline, :mid)

    track = MediaStreamTrack.from_mline(mline)

    id = Utils.generate_id()

    if :rtcp_reports in config.features do
      send(self(), {:send_reports, id})
    end

    if mline.type == :video and :inbound_rtx in config.features do
      send(self(), {:send_nacks, id})
    end

    receiver = RTPReceiver.new(track, codecs, header_extensions, config.features)

    sender = RTPSender.new(nil, ssrc, rtx_ssrc, config.features)
    sender = RTPSender.update(sender, mid, codecs, header_extensions)

    %{
      id: id,
      direction: :recvonly,
      current_direction: nil,
      fired_direction: nil,
      mid: mid,
      mline_idx: mline_idx,
      kind: mline.type,
      receiver: receiver,
      sender: sender,
      codecs: codecs,
      header_extensions: header_extensions,
      added_by_add_track: false,
      stopping: false,
      stopped: false
    }
  end

  @doc false
  @spec associable?(transceiver(), ExSDP.Media.t()) :: boolean()
  def associable?(transceiver, mline) do
    %{
      mid: mid,
      kind: kind,
      added_by_add_track: added_by_add_track,
      stopped: stopped
    } = transceiver

    direction = SDPUtils.get_media_direction(mline)

    is_nil(mid) and added_by_add_track and
      kind == mline.type and not stopped and
      direction in [:sendrecv, :recvonly]
  end

  @doc false
  @spec update(transceiver(), ExSDP.Media.t(), Configuration.t()) :: transceiver()
  def update(transceiver, mline, config) do
    {:mid, mid} = ExSDP.get_attribute(mline, :mid)
    if transceiver.mid != nil and mid != transceiver.mid, do: raise(ArgumentError)

    codecs = Configuration.intersect_codecs(config, mline)
    header_extensions = Configuration.intersect_extensions(config, mline)
    stream_ids = SDPUtils.get_stream_ids(mline)

    receiver = RTPReceiver.update(transceiver.receiver, codecs, header_extensions, stream_ids)
    sender = RTPSender.update(transceiver.sender, mid, codecs, header_extensions)

    %{
      transceiver
      | mid: mid,
        codecs: codecs,
        header_extensions: header_extensions,
        sender: sender,
        receiver: receiver
    }
  end

  @doc false
  @spec set_direction(transceiver(), direction()) :: t()
  def set_direction(transceiver, direction) do
    %{transceiver | direction: direction}
  end

  @doc false
  @spec set_sender_codec(transceiver(), RTPCodecParameters.t()) ::
          {:ok, transceiver()} | {:error, term()}
  def set_sender_codec(transceiver, codec) do
    case RTPSender.set_codec(transceiver.sender, codec) do
      {:ok, sender} -> {:ok, %{transceiver | sender: sender}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec can_add_track?(transceiver(), kind()) :: boolean()
  def can_add_track?(transceiver, kind) do
    transceiver.kind == kind and
      transceiver.sender.track == nil and
      transceiver.current_direction not in [:sendrecv, :sendonly]
  end

  @doc false
  @spec add_track(transceiver(), MediaStreamTrack.t()) :: transceiver()
  def add_track(transceiver, track) do
    sender = %{transceiver.sender | track: track}

    direction =
      case transceiver.direction do
        :recvonly -> :sendrecv
        :inactive -> :sendonly
        other -> other
      end

    %{transceiver | sender: sender, direction: direction}
  end

  @doc false
  @spec replace_track(transceiver(), MediaStreamTrack.t()) :: transceiver()
  def replace_track(transceiver, track) do
    sender = %{transceiver.sender | track: track}
    %{transceiver | sender: sender}
  end

  @doc false
  @spec remove_track(transceiver()) :: transceiver()
  def remove_track(transceiver) do
    sender = %{transceiver.sender | track: nil}

    direction =
      case transceiver.direction do
        :sendrecv -> :recvonly
        :sendonly -> :inactive
        other -> other
      end

    %{transceiver | sender: sender, direction: direction}
  end

  @doc false
  @spec receive_packet(transceiver(), ExRTP.Packet.t(), non_neg_integer()) ::
          {:ok, {String.t() | nil, ExRTP.Packet.t()}, transceiver()} | :error
  def receive_packet(transceiver, packet, size) do
    case check_if_rtx(transceiver.codecs, packet) do
      {:ok, apt} -> RTPReceiver.receive_rtx(transceiver.receiver, packet, apt)
      :error -> {:ok, packet, transceiver.receiver}
    end
    |> case do
      {:ok, packet, receiver} ->
        {rid, receiver} = RTPReceiver.receive_packet(receiver, packet, size)
        transceiver = %{transceiver | receiver: receiver}
        {:ok, {rid, packet}, transceiver}

      _other ->
        :error
    end
  end

  @doc false
  @spec receive_report(transceiver(), ExRTCP.Packet.SenderReport.t()) :: transceiver()
  def receive_report(transceiver, report) do
    receiver = RTPReceiver.receive_report(transceiver.receiver, report)
    %{transceiver | receiver: receiver}
  end

  @doc false
  @spec receive_nack(transceiver(), ExRTCP.Packet.TransportFeedback.NACK.t()) ::
          {[ExRTP.Packet.t()], transceiver()}
  def receive_nack(transceiver, nack) do
    {packets, sender} = RTPSender.receive_nack(transceiver.sender, nack)
    transceiver = %{transceiver | sender: sender}
    {packets, transceiver}
  end

  @doc false
  @spec receive_pli(transceiver(), PLI.t()) :: transceiver()
  def receive_pli(transceiver, pli) do
    sender = RTPSender.receive_pli(transceiver.sender, pli)
    %{transceiver | sender: sender}
  end

  @doc false
  @spec send_packet(transceiver(), ExRTP.Packet.t(), boolean()) :: {binary(), transceiver()}
  def send_packet(transceiver, packet, rtx?) do
    case RTPSender.send_packet(transceiver.sender, packet, rtx?) do
      {<<>>, sender} ->
        {<<>>, %{transceiver | sender: sender}}

      {packet, sender} ->
        receiver =
          if rtx? do
            transceiver.receiver
          else
            RTPReceiver.update_sender_ssrc(transceiver.receiver, sender.ssrc)
          end

        transceiver = %{transceiver | sender: sender, receiver: receiver}

        {packet, transceiver}
    end
  end

  @doc false
  @spec get_reports(transceiver()) :: {[SenderReport.t() | ReceiverReport.t()], transceiver()}
  def get_reports(transceiver) do
    Process.send_after(self(), {:send_reports, transceiver.id}, report_interval())

    {sender_reports, sender} = RTPSender.get_reports(transceiver.sender)
    {receiver_reports, receiver} = RTPReceiver.get_reports(transceiver.receiver)

    transceiver = %{transceiver | sender: sender, receiver: receiver}
    {sender_reports ++ receiver_reports, transceiver}
  end

  @doc false
  @spec get_nacks(transceiver()) :: {[NACK.t()], transceiver()}
  def get_nacks(transceiver) do
    Process.send_after(self(), {:send_nacks, transceiver.id}, @nack_interval)

    {nacks, receiver} = RTPReceiver.get_nacks(transceiver.receiver)
    transceiver = %{transceiver | receiver: receiver}

    {nacks, transceiver}
  end

  @doc false
  @spec get_pli(transceiver(), String.t() | nil) :: {PLI.t(), transceiver()} | :error
  def get_pli(transceiver, rid) do
    case RTPReceiver.get_pli(transceiver.receiver, rid) do
      :error -> :error
      {pli, receiver} -> {pli, %{transceiver | receiver: receiver}}
    end
  end

  @doc false
  @spec to_answer_mline(transceiver(), ExSDP.Media.t(), Keyword.t()) :: ExSDP.Media.t()
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
        transceiver = %{transceiver | codecs: codecs}
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
        simulcast_attrs = SDPUtils.reverse_simulcast(mline)

        opts =
          opts
          |> Keyword.put(:direction, direction)
          |> Keyword.put(:simulcast, simulcast_attrs)

        to_mline(transceiver, opts)
    end
  end

  @doc false
  @spec to_offer_mline(transceiver(), Keyword.t()) :: ExSDP.Media.t()
  def to_offer_mline(transceiver, opts) do
    mline = to_mline(transceiver, opts)
    if transceiver.stopping, do: %ExSDP.Media{mline | port: 0}, else: mline
  end

  @doc false
  @spec assign_mid(transceiver(), String.t()) :: transceiver()
  def assign_mid(transceiver, mid) do
    sender = %{transceiver.sender | mid: mid}
    %{transceiver | mid: mid, sender: sender}
  end

  @doc false
  @spec stop(transceiver(), (-> term())) :: transceiver()
  def stop(transceiver, on_track_ended) do
    transceiver =
      if transceiver.stopping,
        do: transceiver,
        else: stop_sending_and_receiving(transceiver, on_track_ended)

    # should we reset stopping or leave it as true?
    %{transceiver | stopped: true, stopping: false, current_direction: nil}
  end

  @doc false
  @spec stop_sending_and_receiving(transceiver(), (-> term())) :: transceiver()
  def stop_sending_and_receiving(transceiver, on_track_ended) do
    # TODO send RTCP BYE for each RTP stream
    # TODO stop receiving media
    on_track_ended.()
    %{transceiver | direction: :inactive, stopping: true}
  end

  @doc false
  @spec get_stats(transceiver(), non_neg_integer()) :: [map()]
  def get_stats(transceiver, timestamp) do
    tr_stats = %{kind: transceiver.kind, mid: transceiver.mid}

    case transceiver.current_direction do
      :sendonly ->
        stats = RTPSender.get_stats(transceiver.sender, timestamp)
        [Map.merge(stats, tr_stats)]

      :recvonly ->
        stats = RTPReceiver.get_stats(transceiver.receiver, timestamp)
        Enum.map(stats, &Map.merge(&1, tr_stats))

      :sendrecv ->
        sender_stats = RTPSender.get_stats(transceiver.sender, timestamp)
        receiver_stats = RTPReceiver.get_stats(transceiver.receiver, timestamp)

        [Map.merge(sender_stats, tr_stats)] ++
          Enum.map(receiver_stats, &Map.merge(&1, tr_stats))

      _other ->
        []
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

    direction = Keyword.get(opts, :direction, transceiver.direction)

    attributes =
      if(Keyword.get(opts, :rtcp, false), do: [{"rtcp", "9 IN IP4 0.0.0.0"}], else: []) ++
        Keyword.get(opts, :simulcast, []) ++
        [
          direction,
          {:mid, transceiver.mid},
          {:ice_ufrag, Keyword.fetch!(opts, :ice_ufrag)},
          {:ice_pwd, Keyword.fetch!(opts, :ice_pwd)},
          {:ice_options, Keyword.fetch!(opts, :ice_options)},
          {:fingerprint, Keyword.fetch!(opts, :fingerprint)},
          {:setup, Keyword.fetch!(opts, :setup)},
          :rtcp_mux
        ] ++ transceiver.header_extensions

    # add sender attrs only if we send
    sender_attrs =
      if direction in [:sendonly, :sendrecv] do
        # sender codecs are set when negotiation completes,
        # hence, to generate the first offer, we need to use transceiver codecs
        codecs =
          if transceiver.sender.codecs == [],
            do: transceiver.codecs,
            else: transceiver.sender.codecs

        get_sender_attrs(
          transceiver.sender.track,
          codecs,
          transceiver.sender.ssrc,
          transceiver.sender.rtx_ssrc
        )
      else
        []
      end

    %ExSDP.Media{
      ExSDP.Media.new(transceiver.kind, 9, "UDP/TLS/RTP/SAVPF", pt)
      | # mline must be followed by a cline, which must contain
        # the default value "IN IP4 0.0.0.0" (as there are no candidates yet)
        connection_data: [%ExSDP.ConnectionData{address: {0, 0, 0, 0}}]
    }
    |> ExSDP.add_attributes(attributes ++ media_formats ++ sender_attrs)
  end

  @doc false
  defp get_sender_attrs(track, codecs, ssrc, rtx_ssrc) do
    # Don't include track id. See RFC 8829 sec. 5.2.1
    msid_attrs =
      case track do
        %MediaStreamTrack{streams: streams} when streams != [] ->
          Enum.map(streams, &ExSDP.Attribute.MSID.new(&1, nil))

        _other ->
          # In theory, we should do this "for each MediaStream that was associated with the transceiver",
          # but web browsers (chrome, ff) include MSID even when there aren't any MediaStreams
          [ExSDP.Attribute.MSID.new("-", nil)]
      end

    ssrc_attrs = get_ssrc_attrs(codecs, ssrc, rtx_ssrc, track)

    msid_attrs ++ ssrc_attrs
  end

  defp get_ssrc_attrs(codecs, ssrc, rtx_ssrc, track) do
    codec = Enum.any?(codecs, fn codec -> not String.ends_with?(codec.mime_type, "/rtx") end)
    rtx_codec = Enum.any?(codecs, fn codec -> String.ends_with?(codec.mime_type, "/rtx") end)

    do_get_ssrc_attrs(codec, rtx_codec, ssrc, rtx_ssrc, track)
  end

  # we didn't manage to negotiate any codec
  defp do_get_ssrc_attrs(false, _rtx_codec, _ssrc, _rtx_ssrc, _track) do
    []
  end

  # we have a codec but not rtx codec
  defp do_get_ssrc_attrs(_codec, false, ssrc, _rtx_ssrc, track) do
    streams = (track && track.streams) || []

    case streams do
      [] ->
        [%ExSDP.Attribute.SSRC{id: ssrc, attribute: "msid", value: "-"}]

      streams ->
        Enum.map(streams, fn stream ->
          %ExSDP.Attribute.SSRC{id: ssrc, attribute: "msid", value: stream}
        end)
    end
  end

  # we have both codec and rtx codec
  defp do_get_ssrc_attrs(_codec, _rtx_codec, ssrc, rtx_ssrc, track) do
    streams = (track && track.streams) || []

    fid = %ExSDP.Attribute.SSRCGroup{semantics: "FID", ssrcs: [ssrc, rtx_ssrc]}

    ssrc_attrs =
      case streams do
        [] ->
          [
            %ExSDP.Attribute.SSRC{id: ssrc, attribute: "msid", value: "-"},
            %ExSDP.Attribute.SSRC{id: rtx_ssrc, attribute: "msid", value: "-"}
          ]

        streams ->
          {ssrc_attrs, rtx_ssrc_attrs} =
            Enum.reduce(streams, {[], []}, fn stream, {ssrc_attrs, rtx_ssrc_attrs} ->
              ssrc_attr = %ExSDP.Attribute.SSRC{id: ssrc, attribute: "msid", value: stream}
              ssrc_attrs = [ssrc_attr | ssrc_attrs]

              rtx_ssrc_attr = %ExSDP.Attribute.SSRC{
                id: rtx_ssrc,
                attribute: "msid",
                value: stream
              }

              rtx_ssrc_attrs = [rtx_ssrc_attr | rtx_ssrc_attrs]

              {ssrc_attrs, rtx_ssrc_attrs}
            end)

          Enum.reverse(ssrc_attrs) ++ Enum.reverse(rtx_ssrc_attrs)
      end

    [fid | ssrc_attrs]
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

  defp check_if_rtx(codecs, packet) do
    codec = Enum.find(codecs, &(&1.payload_type == packet.payload_type))

    if codec != nil and String.ends_with?(codec.mime_type, "rtx") do
      {:ok, codec.sdp_fmtp_line.apt}
    else
      :error
    end
  end

  defp report_interval do
    # we use const interval for RTCP reports
    # that is varied randomly over the range [0.5, 1.5]
    # of it's original value to avoid synchronization
    # https://datatracker.ietf.org/doc/html/rfc3550#page-27
    factor = :rand.uniform() + 0.5
    trunc(factor * @report_interval)
  end
end
