if Enum.each([ExAws.S3, ExAws], &Code.ensure_loaded?/1) do
  defmodule ExWebRTC.Recorder.S3.Utils do
  # XXX RENAMEME XXX XML?
    @moduledoc false

    @opaque t :: %__MODULE__{
      s3_config_overrides: keyword(),
      bucket_name: String.t(),
      base_path: Path.t()
    }

    @enforce_keys [:s3_config_overrides, :bucket_name, :base_path]#, :supervisor]
    defstruct @enforce_keys ++ [tasks: %{}]

    @spec new(keyword()) :: t()
    def new(config) do
      bucket_name = Keyword.fetch!(config, :bucket_name)
      base_path = Keyword.get(config, :base_path, "")
      s3_config_overrides = Keyword.drop(config, [:bucket_name, :base_path])

      %__MODULE__{
        bucket_name: bucket_name,
        base_path: base_path,
        s3_config_overrides: s3_config_overrides,
        # supervisor: Task.Supervisor.start_link()
      }
    end

    # XXX fill and use?
    def rewrite_manifest(handler, manifest) do
    end

    @spec spawn_upload_task(t(), Recorder.manifest()) :: {reference(), t()}
    def spawn_upload_task(handler, manifest) do
      paths = manifest |> Map.values() |> Enum.map(& &1.path)
      s3_paths = Map.new(paths, &{&1, Path.join(handler.base_path, Path.basename(&1))})

      # XXX this links...
      task = Task.async(fn ->
        # XXX results (should be id-based...)
        for {path, s3_path} <- s3_paths do
          __MODULE__.upload_file(
            path,
            handler.bucket_name,
            s3_path,
            handler.s3_config_overrides
          )
        end
      end)

      # XXX wjeb tu wiyncyj
      manifest =
        Map.new(manifest, fn {track_id, %{path: path} = track_data} ->
          {track_id, Map.put(track_data, :path, {:s3, handler.bucket_name, s3_paths[path]})}
        end)

      {task.ref, %__MODULE__{handler |
        tasks: Map.put(handler.tasks, task.ref, manifest)
      }}
    end

    # XXX WHICH MANIFEST?!
    @spec process_upload_result(t(), {reference(), term()}) :: {{:ok | :error, term()}, t()}
    def process_upload_result(handler, {ref, result}) do
      case Map.get(handler.tasks, ref) do
        nil ->
          {{:error, :unknown_task}, handler}

        manifest ->
          # XXX check result...
          IO.inspect(result, label: :UNUSED_RESULT_BE)
          {{:ok, manifest}, %__MODULE__{handler | tasks: Map.delete(handler.tasks, ref)}}
      end
    end

    ## UTILS

    def upload_file(path, s3_bucket_name, s3_path, s3_config \\ []) do
      path
      |> ExAws.S3.Upload.stream_file()
      |> ExAws.S3.upload(s3_bucket_name, s3_path)
      |> ExAws.request(s3_config)
    end

    def fetch_file(s3_bucket_name, s3_path, output_path, s3_config \\ []) do
      ExAws.S3.download_file(s3_bucket_name, s3_path, output_path)
      |> ExAws.request(s3_config)
    end
  end
else
  defmodule ExWebRTC.Recorder.S3.Utils do
    @moduledoc false

    @tip "Add the `:ex_aws_s3` and `:ex_aws` dependencies to your project in order to upload and store recordings on S3-compatible storage"

    def upload_file, do: error()
    def fetch_file, do: error()

    defp error do
      text = "XXX WRITEME S3 support is turned off."
      raise("#{text} #{@tip}")
    end
  end
end
