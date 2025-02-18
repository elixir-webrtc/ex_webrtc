defmodule ExWebRTC.Recorder.Converter.Manifest do
  @moduledoc """
  Lists the streams processed using the Converter.

  Converter combines the tracks from the Recording based on their `:streams` field.
  """

  alias ExWebRTC.{MediaStreamTrack, Recorder}

  @type file_manifest :: %{
          :location => Recorder.Manifest.location(),
          :duration_seconds => non_neg_integer(),
          optional(:thumbnail_location) => Recorder.Manifest.location()
        }

  @type t :: %{MediaStreamTrack.stream_id() => file_manifest()}

  @doc false
  @spec to_upload_handler_manifest(t()) :: Recorder.S3.UploadHandler.manifest()
  def to_upload_handler_manifest(converter_manifest) do
    Enum.reduce(converter_manifest, %{}, fn
      {id, %{location: file, thumbnail_location: thumbnail}}, acc ->
        acc
        |> Map.put(id, %{location: file})
        |> Map.put("thumbnail_#{id}", %{location: thumbnail})

      {id, %{location: file}}, acc ->
        Map.put(acc, id, %{location: file})
    end)
  end

  @doc false
  @spec from_upload_handler_manifest(Recorder.S3.UploadHandler.manifest(), t()) :: t()
  def from_upload_handler_manifest(upload_handler_manifest, original_converter_manifest) do
    Enum.reduce(upload_handler_manifest, original_converter_manifest, fn
      {"thumbnail_" <> id, %{location: thumbnail}}, acc ->
        Map.update(
          acc,
          id,
          %{thumbnail_location: thumbnail},
          &Map.put(&1, :thumbnail_location, thumbnail)
        )

      {id, %{location: file}}, acc ->
        Map.update(acc, id, %{location: file}, &Map.put(&1, :location, file))
    end)
  end
end
