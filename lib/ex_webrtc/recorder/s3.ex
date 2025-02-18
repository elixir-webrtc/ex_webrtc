defmodule ExWebRTC.Recorder.S3 do
  @moduledoc """
  `ExWebRTC.Recorder` and `ExWebRTC.Recorder.Converter` can optionally upload/download files to/from S3-compatible storage.

  To use this functionality, you must add the following dependencies to your project:
  * `:ex_aws_s3`
  * `:ex_aws`
  * `:sweet_xml`
  * an HTTP client (e.g. `:req`)
  """

  @typedoc """
  Options described [here](https://hexdocs.pm/ex_aws_s3/ExAws.S3.html#module-configuration)
  and [here](https://hexdocs.pm/ex_aws/readme.html#aws-key-configuration)
  (e.g. `:access_key_id`, `:secret_access_key` `:scheme`, `:host`, `:port`, `:region`).

  They can be passed in order to override values defined in the application config (or environment variables).
  """
  @type override_option :: {atom(), term()}
  @type override_config :: [override_option()]

  @typedoc """
  Options for configuring upload of artifacts to S3-compatible storage.

  * `:bucket_name` (required) - Name of bucket objects will be uploaded to.
  * `:base_path` - S3 path prefix used for objects uploaded to the bucket. `""` by default.
  """
  @type upload_option :: {:bucket_name, String.t()} | {:base_path, String.t()}

  @type upload_config :: [upload_option() | override_option()]

  @typedoc """
  Reference to a started batch upload task.
  """
  @opaque upload_task_ref :: __MODULE__.UploadHandler.ref()
end
