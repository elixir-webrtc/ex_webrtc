defmodule ExWebRTC.SDPUtils do
  @moduledoc false

  alias ExRTP.Packet.Extension
  alias ExSDP.Attribute.{Extmap, RID, Simulcast}

  alias ExWebRTC.RTPCodecParameters

  @type extension() :: {Extension.SourceDescription, atom()}

  @spec ensure_mid(ExSDP.t()) :: :ok | {:error, :missing_mid | :duplicated_mid}
  def ensure_mid(sdp) do
    sdp.media
    |> Enum.reduce_while({:ok, []}, fn media, {:ok, acc} ->
      case ExSDP.get_attributes(media, :mid) do
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

    mline_mids = get_bundle_mids(sdp.media)

    case filter_groups(groups, "BUNDLE") do
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

  defp filter_groups(groups, to_filter) do
    Enum.filter(groups, fn %ExSDP.Attribute.Group{semantics: name} -> name == to_filter end)
  end

  @spec ensure_rtcp_mux(ExSDP.t()) :: :ok | {:error, :missing_rtcp_mux}
  def ensure_rtcp_mux(sdp) do
    sdp.media
    |> Enum.all?(&(ExSDP.get_attribute(&1, :rtcp_mux) == :rtcp_mux))
    |> case do
      true -> :ok
      false -> {:error, :missing_rtcp_mux}
    end
  end

  @spec get_media_direction(ExSDP.Media.t()) ::
          :sendrecv | :sendonly | :recvonly | :inactive | nil
  def get_media_direction(media) do
    Enum.find(media.attributes, fn attr ->
      attr in [:sendrecv, :sendonly, :recvonly, :inactive]
    end)
  end

  @spec get_rids(ExSDP.Media.t()) :: [String.t()] | nil
  def get_rids(media) do
    Enum.flat_map(media.attributes, fn
      %RID{direction: :send, id: id} -> [id]
      _other -> []
    end)
    |> case do
      [] -> nil
      other -> other
    end
  end

  @spec reverse_simulcast(ExSDP.Media.t()) :: [ExSDP.Attribute.t()]
  def reverse_simulcast(media) do
    Enum.flat_map(media.attributes, fn
      %RID{direction: :send} = rid -> [%RID{rid | direction: :recv}]
      %Simulcast{send: send, recv: recv} -> [%Simulcast{send: recv, recv: send}]
      _other -> []
    end)
  end

  @spec get_bundle_mids([ExSDP.Media.t()]) :: [String.t()]
  def get_bundle_mids(mlines) do
    # Rejected m-lines are not included in the BUNDLE group.
    # See RFC 8829, sec. 5.2.2, p. 10.
    Enum.map(mlines, fn mline ->
      unless rejected?(mline) do
        {:mid, mid} = ExSDP.get_attribute(mline, :mid)
        mid
      end
    end)
    |> Enum.reject(&(&1 == nil))
  end

  @spec get_stream_ids(ExSDP.Media.t()) :: [String.t()]
  def get_stream_ids(media) do
    ExSDP.get_attributes(media, :msid)
    |> Enum.reject(fn msid -> msid.id == "-" end)
    |> Enum.map(fn msid -> msid.id end)
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

  @spec get_ice_candidates(ExSDP.t()) :: [String.t()]
  def get_ice_candidates(sdp) do
    sdp.media
    |> Enum.flat_map(&ExSDP.get_attributes(&1, "candidate"))
    |> Enum.map(fn {"candidate", attr} -> attr end)
  end

  @spec add_ice_candidates(ExSDP.t(), [String.t()]) :: ExSDP.t()
  def add_ice_candidates(sdp, candidates) do
    # We only add candidates to the first mline
    # as we don't support bundle-policies other than "max-bundle".
    # See RFC 8829, sec. 4.1.1.
    candidates = Enum.map(candidates, &{"candidate", &1})

    if sdp.media != [] do
      mline =
        sdp.media
        |> List.first()
        |> ExSDP.add_attributes(candidates)

      media = List.replace_at(sdp.media, 0, mline)
      %ExSDP{sdp | media: media}
    else
      sdp
    end
  end

  @spec get_dtls_role(ExSDP.t()) ::
          {:ok, :active | :passive | :actpass}
          | {:error, :missing_dtls_role | :conflicting_dtls_roles}
  def get_dtls_role(sdp) do
    session_role =
      case ExSDP.get_attribute(sdp, :setup) do
        {:setup, setup} -> setup
        nil -> nil
      end

    mline_roles =
      sdp.media
      |> Enum.flat_map(&ExSDP.get_attributes(&1, :setup))
      |> Enum.map(fn {:setup, setup} -> setup end)

    case {session_role, mline_roles} do
      {nil, []} ->
        {:error, :missing_dtls_role}

      {session_role, []} ->
        {:ok, session_role}

      {session_role, mline_roles} ->
        roles =
          if session_role != nil do
            mline_roles ++ [session_role]
          else
            mline_roles
          end

        case Enum.uniq(roles) do
          [role] -> {:ok, role}
          _other -> {:error, :conflicting_dtls_roles}
        end
    end
  end

  @spec get_cert_fingerprint(ExSDP.t()) ::
          {:ok, {:fingerprint, {atom(), binary()}}}
          | {:error, :missing_cert_fingerprint | :conflicting_cert_fingerprints}
  def get_cert_fingerprint(sdp) do
    session_fingerprint = ExSDP.get_attribute(sdp, :fingerprint)
    mline_fingerprints = Enum.map(sdp.media, &ExSDP.get_attribute(&1, :fingerprint))

    case {session_fingerprint, mline_fingerprints} do
      {nil, []} ->
        {:error, :missing_cert_fingerprint}

      {session_fingerprint, []} ->
        {:ok, session_fingerprint}

      {nil, mline_fingerprints} ->
        with :ok <- ensure_fingerprints_present(mline_fingerprints),
             :ok <- ensure_fingerprints_unique(mline_fingerprints) do
          {:ok, List.first(mline_fingerprints)}
        else
          {:error, :no_cert_fingerprints} -> {:error, :missing_cert_fingerprint}
          other -> other
        end

      {session_fingerprint, mline_fingerprints} ->
        with :ok <- ensure_fingerprints_present(mline_fingerprints),
             :ok <- ensure_fingerprints_unique([session_fingerprint | mline_fingerprints]) do
          {:ok, session_fingerprint}
        else
          {:error, :no_cert_fingerprints} -> {:ok, session_fingerprint}
          other -> other
        end
    end
  end

  @spec get_extensions(ExSDP.t()) :: [Extmap.t()]
  def get_extensions(sdp) do
    # we assume that, if extension is present in multiple mlines, the IDs are the same (RFC 8285)
    Enum.flat_map(sdp.media, &ExSDP.get_attributes(&1, Extmap))
  end

  @spec get_rtp_codec_parameters(ExSDP.t() | ExSDP.Media.t()) :: [RTPCodecParameters.t()]
  def get_rtp_codec_parameters(sdp_or_mline)

  def get_rtp_codec_parameters(%ExSDP{} = sdp), do: do_get_rtp_codec_parameters(sdp.media)

  def get_rtp_codec_parameters(%ExSDP.Media{} = mline),
    do: do_get_rtp_codec_parameters(List.wrap(mline))

  defp do_get_rtp_codec_parameters(mlines) do
    Enum.flat_map(mlines, fn mline ->
      rtp_mappings = ExSDP.get_attributes(mline, :rtpmap)
      fmtps = ExSDP.get_attributes(mline, :fmtp)
      all_rtcp_fbs = ExSDP.get_attributes(mline, :rtcp_feedback)

      rtp_mappings
      |> Enum.map(fn rtp_mapping ->
        fmtp = Enum.find(fmtps, &(&1.pt == rtp_mapping.payload_type))
        rtcp_fbs = Enum.filter(all_rtcp_fbs, &(&1.pt == rtp_mapping.payload_type))

        RTPCodecParameters.new(mline.type, rtp_mapping, fmtp, rtcp_fbs)
      end)
    end)
  end

  @spec get_payload_to_mid(ExSDP.t()) :: %{(pt :: non_neg_integer()) => mid :: binary()}
  def get_payload_to_mid(sdp) do
    # if payload type is used in more than 1 mline, it cannot be used to identify the mline
    # thus, it is not placed in the returned map
    sdp.media
    |> Enum.flat_map(fn mline ->
      {:mid, mid} = ExSDP.get_attribute(mline, :mid)
      encodings = ExSDP.get_attributes(mline, :rtpmap)

      Enum.map(encodings, &{&1.payload_type, mid})
    end)
    |> Enum.reduce(%{}, fn
      {pt, _mid}, acc when is_map_key(acc, pt) -> Map.put(acc, pt, nil)
      {pt, mid}, acc -> Map.put(acc, pt, mid)
    end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @spec get_ssrc_to_mid(ExSDP.t()) :: %{(ssrc :: String.t()) => mid :: String.t()}
  def get_ssrc_to_mid(sdp) do
    sdp.media
    |> Enum.flat_map(fn mline ->
      with {:mid, mid} <- ExSDP.get_attribute(mline, :mid),
           %ExSDP.Attribute.SSRC{id: ssrc} <- ExSDP.get_attribute(mline, :ssrc) do
        [{ssrc, mid}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  @spec find_mline_by_mid(ExSDP.t(), binary()) :: ExSDP.Media.t() | nil
  def find_mline_by_mid(sdp, mid) do
    Enum.find(sdp.media, fn mline ->
      {:mid, mline_mid} = ExSDP.get_attribute(mline, :mid)
      mline_mid == mid
    end)
  end

  @spec find_free_mline_idx(ExSDP.t(), [non_neg_integer()]) :: non_neg_integer() | nil
  def find_free_mline_idx(sdp, indices) do
    sdp.media
    |> Stream.with_index()
    |> Enum.find_index(fn {mline, idx} -> mline.port == 0 and idx not in indices end)
  end

  @spec rejected?(ExSDP.Media.t()) :: boolean()
  def rejected?(%ExSDP.Media{port: 0} = media) do
    # An m-line is only rejected when its port is set to 0,
    # and there is no `bundle-only` attribute.
    # See RFC 8843, sec. 6.
    "bundle-only" not in media.attributes
  end

  def rejected?(%ExSDP.Media{}), do: false

  defp do_get_ice_credentials(sdp_or_mline) do
    ice_ufrag =
      case ExSDP.get_attribute(sdp_or_mline, :ice_ufrag) do
        {:ice_ufrag, ice_ufrag} -> ice_ufrag
        nil -> nil
      end

    ice_pwd =
      case ExSDP.get_attribute(sdp_or_mline, :ice_pwd) do
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

  defp ensure_fingerprints_present(fingerprints) do
    cond do
      Enum.all?(fingerprints, &(&1 == nil)) -> {:error, :no_cert_fingerprints}
      Enum.any?(fingerprints, &(&1 == nil)) -> {:error, :missing_cert_fingerprint}
      true -> :ok
    end
  end

  defp ensure_fingerprints_unique(fingerprints) do
    case Enum.uniq(fingerprints) do
      [_] -> :ok
      _ -> {:error, :conflicting_cert_fingerprints}
    end
  end
end
