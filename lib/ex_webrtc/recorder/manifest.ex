defmodule ExWebRTC.Recorder.Manifest do
  @moduledoc """
  Lists the tracks recorded by a specific Recorder instance.
  """

  alias ExWebRTC.MediaStreamTrack

  @typedoc """
  Location of a manifest entry.

  Can be one of the following:
  * Local path, e.g. `"foo/bar/recording.webm"`
  * URL with the `file://` scheme, e.g. `"file:///baz/qux/recording.webm"`
  * URL with the `s3://` scheme, e.g. `"s3://my-bucket-name/abc/recording.webm"`
  """
  @type location :: String.t()

  @type track_manifest :: %{
          start_time: DateTime.t(),
          kind: :video | :audio,
          streams: [MediaStreamTrack.stream_id()],
          rid_map: %{MediaStreamTrack.rid() => integer()},
          location: location()
        }

  @type t :: %{MediaStreamTrack.id() => track_manifest()}

  @doc false
  @spec from_json!(map()) :: t()
  def from_json!(json_manifest) do
    Map.new(json_manifest, fn {id, entry} ->
      {id, parse_entry(entry)}
    end)
  end

  defp parse_entry(%{
         "start_time" => start_time,
         "kind" => kind,
         "streams" => streams,
         "rid_map" => rid_map,
         "location" => location
       }) do
    %{
      streams: streams,
      location: location,
      start_time: parse_start_time(start_time),
      rid_map: parse_rid_map(rid_map),
      kind: parse_kind(kind)
    }
  end

  defp parse_start_time(start_time) do
    {:ok, start_time, _offset} = DateTime.from_iso8601(start_time)
    start_time
  end

  defp parse_rid_map(rid_map) do
    Map.new(rid_map, fn
      {"nil", v} -> {nil, v}
      {layer, v} -> {layer, v}
    end)
  end

  defp parse_kind("video"), do: :video
  defp parse_kind("audio"), do: :audio
end
