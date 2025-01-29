if Enum.each([ExAws.S3, ExAws, SweetXml], &Code.ensure_loaded?/1) do
  defmodule ExWebRTC.Recorder.S3.UploadHandler do
    @moduledoc false
    alias ExWebRTC.Recorder
    require Logger

    @type manifest :: Recorder.manifest() | Recorder.Converter.manifest()

    @opaque t :: %__MODULE__{
      s3_config_overrides: keyword(),
      bucket_name: String.t(),
      base_path: Path.t(),
      tasks: %{Task.ref() => manifest()}
    }

    @enforce_keys [:s3_config_overrides, :bucket_name, :base_path]
    defstruct @enforce_keys ++ [tasks: %{}]

    @spec new(keyword()) :: t()
    def new(config) do
      {:ok, bucket_name} = config |> Keyword.fetch!(:bucket_name) |> Recorder.S3.Utils.validate_bucket_name()
      base_path = Keyword.get(config, :base_path, "")
      {:ok, _test_path} = base_path |> Path.join("a") |> Recorder.S3.Utils.validate_s3_path()
      s3_config_overrides = Keyword.drop(config, [:bucket_name, :base_path])

      %__MODULE__{
        bucket_name: bucket_name,
        base_path: base_path,
        s3_config_overrides: s3_config_overrides,
      }
    end

    @spec spawn_task(t(), manifest()) :: {Task.ref(), t()}
    def spawn_task(%__MODULE__{bucket_name: bucket_name, s3_config_overrides: s3_config_overrides} = handler, upload_manifest) do
      s3_paths =
        Map.new(upload_manifest, fn {id, %{location: path}} ->
          s3_path = path |> Path.basename() |> then(&Path.join(handler.base_path, &1))

          {id, s3_path}
        end)

      # XXX wjeb tu wiyncyj?
      download_manifest =
        Map.new(upload_manifest, fn {id, track_data} ->
          {:ok, location} = Recorder.S3.Utils.to_url(bucket_name, s3_paths[id])

          {id, %{track_data | location: location}}
        end)

      # FIXME: this links, ideally we should spawn a supervised task instead
      task = Task.async(fn ->
        Map.new(upload_manifest, fn {id, %{location: path}} ->
          %{^id => s3_path} = s3_paths
          Logger.debug("Uploading `#{inspect(path)}` to bucket `#{bucket_name}`, path `#{s3_path}`")
          Logger.warning("Uploading `#{inspect(path)}` to bucket `#{bucket_name}`, path `#{s3_path}`")

          result = Recorder.S3.Utils.upload_file(path, bucket_name, s3_path, s3_config_overrides)
          # XXX log warning/error on upload fail?

          {id, result}
        end)
      end)

      {task.ref, %__MODULE__{handler |
        tasks: Map.put(handler.tasks, task.ref, download_manifest)
      }}
    end

    @spec process_result(t(), {Task.ref(), term()}) :: {{:ok, manifest()} | {:error, term()}, t()}
    def process_result(handler, {ref, result}) do
      case Map.get(handler.tasks, ref) do
        nil ->
          {{:error, :unknown_task}, handler}

        manifest ->
          # XXX check result... and inform about fails...
          IO.inspect(result, label: :compound_result_is)
          {{:ok, manifest}, %__MODULE__{handler | tasks: Map.delete(handler.tasks, ref)}}
      end
    end
  end
else
  defmodule ExWebRTC.Recorder.S3.UploadHandler do
    @moduledoc false

    @tip "Add the `:ex_aws_s3`, `:ex_aws` and `:sweet_xml` dependencies to your project in order to upload recordings to S3-compatible storage"

    def new(_), do: error()
    def spawn_task(_, _), do: error()
    def process_result(_, _), do: error()

    defp error do
      text = "WRITEME S3 support is turned off."
      raise("#{text} #{@tip}")
    end
  end
end
