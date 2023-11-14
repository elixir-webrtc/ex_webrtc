defmodule ExWebRTC.SDPUtils do
  @moduledoc false

  alias ExRTP.Packet.Extension.SourceDescription

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

  @spec get_extensions(ExSDP.t()) :: %{non_neg_integer() => {module(), atom()}}
  def get_extensions(sdp) do
    # we assume that, if extension is present in multiple mlines, the IDs are the same (RFC 8285)
    sdp.media
    |> Enum.flat_map(&ExSDP.Media.get_attributes(&1, :extmap))
    |> Enum.flat_map(fn
      %{id: id, uri: "urn:ietf:params:rtp-hdrext:sdes:mid"} -> [{id, {SourceDescription, :mid}}]
      # TODO: handle other types of extensions
      _ -> []
    end)
    |> Map.new()
  end

  @spec get_payload_types(ExSDP.t()) :: %{non_neg_integer() => binary()}
  def get_payload_types(sdp) do
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
end
