defmodule ExWebRTC.SDPUtils do
  @moduledoc false

  alias ExWebRTC.RTPTransceiver

  @spec get_answer_mline(ExSDP.Media.t(), RTPTransceiver.t(), Keyword.t()) :: ExSDP.Media.t()
  def get_answer_mline(mline, transceiver, config) do
    # TODO: we need to filter the media formats according to our capabilities
    media_formats =
      Enum.filter(mline.attributes, fn
        %ExSDP.Attribute.RTPMapping{} -> true
        %ExSDP.Attribute.FMTP{} -> true
        _other -> false
      end)

    payload_types =
      Enum.flat_map(media_formats, fn
        %ExSDP.Attribute.RTPMapping{payload_type: pt} -> [pt]
        _other -> []
      end)

    offered_direction = ExSDP.Media.get_attribute(mline, :direction)
    direction = get_direction(offered_direction, transceiver.direction)

    attributes =
      [
        direction,
        {:mid, transceiver.mid},
        {:ice_ufrag, Keyword.fetch!(config, :ice_ufrag)},
        {:ice_pwd, Keyword.fetch!(config, :ice_pwd)},
        {:ice_options, Keyword.fetch!(config, :ice_options)},
        {:fingerprint, Keyword.fetch!(config, :fingerprint)},
        {:setup, Keyword.fetch!(config, :setup)},
        # TODO: probably should fail if the offer doesn't contain rtcp-mux
        # as we don't support non-muxed streams
        :rtcp_mux
      ]

    # TODO: validation of some the stuff in remote SDP
    %ExSDP.Media{
      ExSDP.Media.new(mline.type, 9, mline.protocol, payload_types)
      | # mline must be followed by a cline, which must contain
        # the default value "IN IP4 0.0.0.0" (as there are no candidates yet)
        connection_data: [%ExSDP.ConnectionData{address: {0, 0, 0, 0}}]
    }
    |> ExSDP.Media.add_attributes(attributes ++ media_formats)
  end

  def to_offer_mline(transceiver, config) do
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
      if(Keyword.get(config, :rtcp, false), do: [{"rtcp", "9 IN IP4 0.0.0.0"}], else: []) ++
        [
          transceiver.direction,
          {:mid, transceiver.mid},
          {:ice_ufrag, Keyword.fetch!(config, :ice_ufrag)},
          {:ice_pwd, Keyword.fetch!(config, :ice_pwd)},
          {:ice_options, Keyword.fetch!(config, :ice_options)},
          {:fingerprint, Keyword.fetch!(config, :fingerprint)},
          {:setup, Keyword.fetch!(config, :setup)},
          :rtcp_mux
        ]

    %ExSDP.Media{
      ExSDP.Media.new(transceiver.kind, 9, "UDP/TLS/RTP/SAVPF", pt)
      | # mline must be followed by a cline, which must contain
        # the default value "IN IP4 0.0.0.0" (as there are no candidates yet)
        connection_data: [%ExSDP.ConnectionData{address: {0, 0, 0, 0}}]
    }
    |> ExSDP.Media.add_attributes(attributes ++ media_formats)
  end

  @spec get_media_direction(ExSDP.Media.t()) ::
          :sendrecv | :sendonly | :recvonly | :inactive | nil
  def get_media_direction(media) do
    Enum.find(media.attributes, fn attr ->
      attr in [:sendrecv, :sendonly, :recvonly, :inactive]
    end)
  end

  @spec ensure_mid(ExSDP.t()) :: :ok | {:error, :missing_mid | :duplicated_mid}
  def ensure_mid(sdp) do
    sdp.media
    |> Enum.reduce_while({:ok, []}, fn media, {:ok, acc} ->
      case ExSDP.Media.get_attributes(media, :mid) do
        [{:mid, mid}] -> {:cont, {:ok, [mid | acc]}}
        [] -> {:halt, {:error, :missing_mid}}
        other when is_list(other) -> {:halt, {:error, :duplicated_mid}}
      end
    end)
    |> case do
      {:ok, mids} -> if Enum.uniq(mids) == mids, do: :ok, else: {:error, :duplicated_mid}
      error -> error
    end
  end

  @spec ensure_bundle(ExSDP.t()) ::
          :ok
          | {:error,
             :non_exhaustive_bundle_group
             | :missing_bundle_group
             | :multiple_bundle_groups
             | :invalid_bundle_group}
  def ensure_bundle(sdp) do
    groups = ExSDP.get_attributes(sdp, ExSDP.Attribute.Group)

    mline_mids =
      Enum.map(sdp.media, fn media ->
        {:mid, mid} = ExSDP.Media.get_attribute(media, :mid)
        mid
      end)

    case groups do
      [%ExSDP.Attribute.Group{semantics: "BUNDLE", mids: group_mids}] ->
        case {mline_mids -- group_mids, group_mids -- mline_mids} do
          {[], []} -> :ok
          {_, []} -> {:error, :non_exhaustive_bundle_group}
          _other -> {:error, :invalid_bundle_group}
        end

      [] ->
        {:error, :missing_bundle_group}

      other when is_list(other) ->
        {:error, :multiple_bundle_groups}
    end
  end

  @spec get_ice_credentials(ExSDP.t()) ::
          {:ok, {binary(), binary()}}
          | {:error,
             :missing_ice_pwd
             | :missing_ice_ufrag
             | :missing_ice_credentials
             | :conflicting_ice_credentials}
  def get_ice_credentials(sdp) do
    session_creds = do_get_ice_credentials(sdp)
    mline_creds = Enum.map(sdp.media, fn mline -> do_get_ice_credentials(mline) end)

    case {session_creds, mline_creds} do
      # no session creds and no mlines (empty SDP)
      {{nil, nil}, []} ->
        {:error, :missing_ice_credentials}

      # session creds but no mlines (empty SDP)
      {session_creds, []} ->
        {:ok, session_creds}

      {{nil, nil}, mline_creds} ->
        with :ok <- ensure_ice_credentials_present(mline_creds),
             :ok <- ensure_ice_credentials_unique(mline_creds) do
          {:ok, List.first(mline_creds)}
        end

      {{s_ufrag, s_pwd} = session_creds, mline_creds} ->
        creds =
          Enum.map([session_creds | mline_creds], fn
            {nil, nil} -> session_creds
            {nil, pwd} -> {s_ufrag, pwd}
            {ufrag, nil} -> {ufrag, s_pwd}
            other -> other
          end)

        case ensure_ice_credentials_unique(creds) do
          :ok -> {:ok, List.first(creds)}
          error -> error
        end
    end
  end

  defp do_get_ice_credentials(sdp_or_mline) do
    get_attr =
      case sdp_or_mline do
        %ExSDP{} -> &ExSDP.get_attribute/2
        %ExSDP.Media{} -> &ExSDP.Media.get_attribute/2
      end

    ice_ufrag =
      case get_attr.(sdp_or_mline, :ice_ufrag) do
        {:ice_ufrag, ice_ufrag} -> ice_ufrag
        nil -> nil
      end

    ice_pwd =
      case get_attr.(sdp_or_mline, :ice_pwd) do
        {:ice_pwd, ice_pwd} -> ice_pwd
        nil -> nil
      end

    {ice_ufrag, ice_pwd}
  end

  defp ensure_ice_credentials_present(creds) do
    creds
    |> Enum.find(fn {ice_ufrag, ice_pwd} -> ice_ufrag == nil or ice_pwd == nil end)
    |> case do
      {nil, nil} ->
        {:error, :missing_ice_credentials}

      {nil, _} ->
        {:error, :missing_ice_ufrag}

      {_, nil} ->
        {:error, :missing_ice_pwd}

      nil ->
        :ok
    end
  end

  defp ensure_ice_credentials_unique(creds) do
    case Enum.uniq(creds) do
      [_] -> :ok
      _ -> {:error, :conflicting_ice_credentials}
    end
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
end
