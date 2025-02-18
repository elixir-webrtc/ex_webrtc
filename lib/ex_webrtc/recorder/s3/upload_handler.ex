if Enum.each([ExAws.S3, ExAws, SweetXml], &Code.ensure_loaded?/1) do
  defmodule ExWebRTC.Recorder.S3.UploadHandler do
    @moduledoc false

    alias ExWebRTC.Recorder
    require Logger

    @type object_manifest :: %{location: Recorder.Manifest.location()}
    @type manifest :: %{String.t() => object_manifest()}

    @opaque ref :: Task.ref()

    @opaque t :: %__MODULE__{
              s3_config_overrides: keyword(),
              bucket_name: String.t(),
              base_path: Path.t(),
              tasks: %{ref() => manifest()}
            }

    @enforce_keys [:s3_config_overrides, :bucket_name, :base_path]
    defstruct @enforce_keys ++ [tasks: %{}]

    @spec new(keyword()) :: t()
    def new(config) do
      {:ok, bucket_name} =
        config |> Keyword.fetch!(:bucket_name) |> Recorder.S3.Utils.validate_bucket_name()

      base_path = Keyword.get(config, :base_path, "")
      {:ok, _test_path} = base_path |> Path.join("a") |> Recorder.S3.Utils.validate_s3_path()
      s3_config_overrides = Keyword.drop(config, [:bucket_name, :base_path])

      %__MODULE__{
        bucket_name: bucket_name,
        base_path: base_path,
        s3_config_overrides: s3_config_overrides
      }
    end

    @spec spawn_task(t(), manifest()) :: {ref(), t()}
    def spawn_task(
          %__MODULE__{bucket_name: bucket_name, s3_config_overrides: s3_config_overrides} =
            handler,
          manifest
        ) do
      s3_paths =
        Map.new(manifest, fn {id, %{location: path}} ->
          s3_path = path |> Path.basename() |> then(&Path.join(handler.base_path, &1))

          {id, s3_path}
        end)

      download_manifest =
        Map.new(manifest, fn {id, object_data} ->
          {:ok, location} = Recorder.S3.Utils.to_url(bucket_name, s3_paths[id])

          {id, %{object_data | location: location}}
        end)

      # FIXME: this links, ideally we should spawn a supervised task instead
      task = Task.async(fn -> upload(manifest, bucket_name, s3_paths, s3_config_overrides) end)

      {task.ref,
       %__MODULE__{handler | tasks: Map.put(handler.tasks, task.ref, download_manifest)}}
    end

    @spec process_result(t(), {ref(), term()}) :: {:ok | {:error, term()}, manifest(), t()}
    def process_result(%__MODULE__{tasks: tasks} = handler, {ref, result}) do
      {manifest, tasks} = Map.pop(tasks, ref)

      result =
        with true <- manifest != nil,
             0 <- result |> Map.values() |> Enum.count(&match?({:error, _}, &1)) do
          Logger.debug("Batch upload task of #{map_size(result)} files successful")
          :ok
        else
          false ->
            Logger.warning("""
            Upload handler unable to process result of unknown task with ref #{inspect(ref)}\
            """)

            {:error, :unknown_task}

          fail_count ->
            Logger.warning("""
            Failed to upload #{fail_count} of #{map_size(result)} files attempted\
            """)

            {:error, :upload_failed}
        end

      {result, manifest, %__MODULE__{handler | tasks: tasks}}
    end

    defp upload(manifest, bucket_name, s3_paths, s3_config_overrides) do
      Map.new(manifest, fn {id, %{location: path}} ->
        %{^id => s3_path} = s3_paths
        Logger.debug("Uploading `#{path}` to bucket `#{bucket_name}`, path `#{s3_path}`")

        result = Recorder.S3.Utils.upload_file(path, bucket_name, s3_path, s3_config_overrides)

        case result do
          {:ok, _output} ->
            Logger.debug(
              "Successfully uploaded `#{path}` to bucket `#{bucket_name}`, path `#{s3_path}`"
            )

          {:error, reason} ->
            Logger.warning("""
            Upload of `#{path}` to bucket `#{bucket_name}`, path `#{s3_path}` \
            failed with reason #{inspect(reason)}\
            """)
        end

        {id, result}
      end)
    end
  end
else
  defmodule ExWebRTC.Recorder.S3.UploadHandler do
    @moduledoc false

    @opaque ref :: term()

    def new(_), do: error()
    def spawn_task(_, _), do: error()
    def process_result(_, _), do: error()

    defp error do
      raise """
      S3 support is turned off. Add the `:ex_aws_s3`, `:ex_aws` and `:sweet_xml` dependencies to your project \
      in order to upload recordings to S3-compatible storage\
      """
    end
  end
end
