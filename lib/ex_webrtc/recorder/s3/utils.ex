if Enum.each([ExAws.S3, ExAws, SweetXml], &Code.ensure_loaded?/1) do
  defmodule ExWebRTC.Recorder.S3.Utils do
    @moduledoc false

    @spec upload_file(Path.t(), String.t(), String.t(), keyword()) :: {:ok | :error, term()}
    def upload_file(path, s3_bucket_name, s3_path, s3_config \\ []) do
      path
      |> ExAws.S3.Upload.stream_file()
      |> ExAws.S3.upload(s3_bucket_name, s3_path)
      |> ExAws.request(s3_config)
    end

    @spec fetch_file(String.t(), String.t(), Path.t(), keyword()) :: {:ok | :error, term()}
    def fetch_file(s3_bucket_name, s3_path, output_path, s3_config \\ []) do
      ExAws.S3.download_file(s3_bucket_name, s3_path, output_path)
      |> ExAws.request(s3_config)
    end

    @spec to_url(String.t(), String.t()) :: {:ok, String.t()} | :error
    def to_url(s3_bucket_name, s3_path) do
      with {:ok, bucket_name} <- validate_bucket_name(s3_bucket_name),
           {:ok, s3_path} <- validate_s3_path(s3_path) do
        {:ok, "s3://#{bucket_name}/#{s3_path}"}
      else
        _other -> :error
      end
    end

    @spec parse_url(String.t()) :: {:ok, String.t(), String.t()} | :error
    def parse_url(url)

    def parse_url("s3://" <> rest) do
      with [bucket_name, s3_path] <- String.split(rest, "/", parts: 2),
           {:ok, bucket_name} <- validate_bucket_name(bucket_name),
           {:ok, s3_path} <- validate_s3_path(s3_path) do
        {:ok, bucket_name, s3_path}
      else
        _other -> :error
      end
    end

    def parse_url(_other), do: :error

    @spec validate_bucket_name(String.t()) :: {:ok, String.t()} | :error
    def validate_bucket_name(name) do
      # Based on https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html
      #   - between 3 and 63 chars
      #   - only lowercase letters, numbers, dots and hyphens
      #   - must begin and end with a letter or number
      if Regex.match?(~r/^[a-z0-9][a-z0-9\.-]{1,61}[a-z0-9]$/, name),
        do: {:ok, name},
        else: :error
    end

    @spec validate_s3_path(String.t()) :: {:ok, String.t()} | :error
    def validate_s3_path(path) do
      # Based on https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-keys.html
      #   - between 1 and 1024 bytes
      #   - additionally, we're disallowing paths starting with a forward slash
      if Regex.match?(~r|^[^/].{0,1023}$|, path),
        do: {:ok, path},
        else: :error
    end
  end
else
  defmodule ExWebRTC.Recorder.S3.Utils do
    @moduledoc false

    def upload_file(_, _, _, _ \\ nil), do: error()
    def fetch_file(_, _, _, _ \\ nil), do: error()
    def to_url(_, _), do: error()
    def parse_url(_), do: error()
    def validate_bucket_name(_), do: error()
    def validate_s3_path(_), do: error()

    defp error do
      raise """
      S3 support is turned off. Add the `:ex_aws_s3`, `:ex_aws` and `:sweet_xml` dependencies to your project \
      in order to upload and fetch files from S3-compatible storage\
      """
    end
  end
end
