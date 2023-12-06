defmodule ExWebRTC.SDPUtils do
  @moduledoc false

  alias ExRTP.Packet.Extension

  @type extension() :: {Extension.SourceDescription, atom()}

  @spec get_media_direction(ExSDP.Media.t()) ::
          :sendrecv | :sendonly | :recvonly | :inactive | nil
  def get_media_direction(media) do
    Enum.find(media.attributes, fn attr ->
      attr in [:sendrecv, :sendonly, :recvonly, :inactive]
    end)
  end

  @spec delete_attribute(ExSDP.t() | ExSDP.Media.t(), module() | atom() | binary()) ::
          ExSDP.t() | ExSDP.Media.t()
  def delete_attribute(sdp_or_mline, key) do
    delete_attributes(sdp_or_mline, [key])
  end

  @spec delete_attributes(ExSDP.t() | ExSDP.Media.t(), [module() | atom() | binary()]) ::
          ExSDP.t() | ExSDP.Media.t()
  def delete_attributes(sdp_or_mline, attributes) when is_list(attributes) do
    new_attrs =
      Enum.reject(sdp_or_mline.attributes, fn
        %module{} -> module in attributes
        {k, _v} -> k in attributes
        # flag attributes
        k -> k in attributes
      end)

    Map.put(sdp_or_mline, :attributes, new_attrs)
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

  @spec ensure_rtcp_mux(ExSDP.t()) :: :ok | {:error, :rtcp_mux_not_indicated}
  def ensure_rtcp_mux(sdp) do
    sdp.media
    |> Enum.all?(&(ExSDP.Media.get_attribute(&1, :rtcp_mux) == :rtcp_mux))
    |> case do
      true -> :ok
      false -> {:error, :missing_rtcp_mux}
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

  @spec get_ice_candidates(ExSDP.t()) :: [String.t()]
  def get_ice_candidates(sdp) do
    sdp.media
    |> Enum.flat_map(&ExSDP.Media.get_attributes(&1, "candidate"))
    |> Enum.map(fn {"candidate", attr} -> attr end)
  end

  @spec get_dtls_role(ExSDP.t()) ::
          {:ok, :active | :passive | :actpass} | {:error, :not_dtls_role}
  def get_dtls_role(sdp) do
    session_role = ExSDP.get_attribute(sdp, :setup)

    mline_roles =
      sdp.media
      |> Enum.flat_map(&ExSDP.Media.get_attributes(&1, :setup))
      |> Enum.map(fn {_, setup} -> setup end)

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
          {:ok, {:fingerprint, {:sha256, binary()}}}
          | {:error, :missing_cert_fingerprint | :conflicting_cert_fingerprints}
  def get_cert_fingerprint(sdp) do
    session_fingerprint = do_get_cert_fingerprint(sdp)
    mline_fingerprints = Enum.map(sdp.media, fn mline -> do_get_cert_fingerprint(mline) end)

    case {session_fingerprint, mline_fingerprints} do
      {nil, []} ->
        {:error, :missing_cert_fingerprint}

      {session_fingerprint, []} ->
        {:ok, session_fingerprint}

      {nil, mline_fingerprints} ->
        with :ok <- ensure_fingerprints_present(mline_fingerprints),
             :ok <- ensure_fingerprints_unique(mline_fingerprints) do
          {:ok, List.first(mline_fingerprints)}
        end

      {session_fingerprint, mline_fingerprints} ->
        with :ok <- ensure_fingerprints_present(mline_fingerprints),
             :ok <- ensure_fingerprints_unique([session_fingerprint | mline_fingerprints]) do
          {:ok, session_fingerprint}
        end
    end
  end

  @spec get_extensions(ExSDP.t()) :: %{(id :: non_neg_integer()) => extension() | :unknown}
  def get_extensions(sdp) do
    # we assume that, if extension is present in multiple mlines, the IDs are the same (RFC 8285)
    sdp.media
    |> Enum.flat_map(&ExSDP.Media.get_attributes(&1, :extmap))
    |> Map.new(fn extmap ->
      # TODO: handle direction and extension attributes
      ext = urn_to_extension(extmap.uri)
      {extmap.id, ext}
    end)
  end

  @spec get_payload_to_mid(ExSDP.t()) :: %{(pt :: non_neg_integer()) => mid :: binary()}
  def get_payload_to_mid(sdp) do
    # if payload type is used in more than 1 mline, it cannot be used to identify the mline
    # thus, it is not placed in the returned map
    sdp.media
    |> Enum.flat_map(fn mline ->
      {:mid, mid} = ExSDP.Media.get_attribute(mline, :mid)
      encodings = ExSDP.Media.get_attributes(mline, :rtpmap)

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
      with {:mid, mid} <- ExSDP.Media.get_attribute(mline, :mid),
           %ExSDP.Attribute.SSRC{} = ssrc <- ExSDP.Media.get_attribute(mline, :ssrc) do
        [{ssrc, mid}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  # TODO: handle other types of extensions
  defp urn_to_extension("urn:ietf:params:rtp-hdrext:sdes:" <> item)
       when item in ["mid", "cname"],
       do: {Extension.SourceDescription, String.to_atom(item)}

  defp urn_to_extension(_other), do: :unknown

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

  defp do_get_cert_fingerprint(sdp_or_mline) do
    get_attr =
      case sdp_or_mline do
        %ExSDP{} -> &ExSDP.get_attribute/2
        %ExSDP.Media{} -> &ExSDP.Media.get_attribute/2
      end

    get_attr.(sdp_or_mline, :fingerprint)
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
    if Enum.all?(fingerprints, &(&1 != nil)) do
      :ok
    else
      {:error, :missing_cert_fingerprint}
    end
  end

  defp ensure_fingerprints_unique(fingerprints) do
    case Enum.uniq(fingerprints) do
      [_] -> :ok
      _ -> {:error, :conflicting_cert_fingerprints}
    end
  end
end
