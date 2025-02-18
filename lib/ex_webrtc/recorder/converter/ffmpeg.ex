defmodule ExWebRTC.Recorder.Converter.FFmpeg do
  @moduledoc false

  alias ExWebRTC.Recorder.Converter

  @spec combine_av!(Path.t(), integer(), Path.t(), integer(), Path.t()) :: Path.t() | no_return()
  def combine_av!(
        video_file,
        video_start_timestamp_ms,
        audio_file,
        audio_start_timestamp_ms,
        output_file
      ) do
    {video_start_time, audio_start_time} =
      calculate_start_times(video_start_timestamp_ms, audio_start_timestamp_ms)

    {_io, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-ss #{video_start_time} -i #{video_file} -ss #{audio_start_time} -i #{audio_file} -c:v copy -c:a copy -shortest #{output_file}),
        stderr_to_stdout: true
      )

    output_file
  end

  @spec generate_thumbnail!(Path.t(), Converter.thumbnails_ctx()) :: Path.t() | no_return()
  def generate_thumbnail!(file, thumbnails_ctx) do
    thumbnail_file = "#{file}_thumbnail.jpg"

    {_io, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-i #{file} -vf thumbnail,scale=#{thumbnails_ctx.width}:#{thumbnails_ctx.height} -frames:v 1 #{thumbnail_file}),
        stderr_to_stdout: true
      )

    thumbnail_file
  end

  @spec get_duration_in_seconds!(Path.t()) :: non_neg_integer() | no_return()
  def get_duration_in_seconds!(file) do
    {duration, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{file})
      )

    {duration_seconds, _rest} = Float.parse(duration)
    round(duration_seconds)
  end

  defp calculate_start_times(video_start_ms, audio_start_ms) do
    diff = abs(video_start_ms - audio_start_ms)
    s = div(diff, 1000)
    ms = rem(diff, 1000)
    delayed_start_time = :io_lib.format("00:00:~2..0w.~3..0w", [s, ms]) |> to_string()

    if video_start_ms > audio_start_ms,
      do: {"00:00:00.000", delayed_start_time},
      else: {delayed_start_time, "00:00:00.000"}
  end
end
