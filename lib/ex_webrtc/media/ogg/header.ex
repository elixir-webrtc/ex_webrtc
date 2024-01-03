defmodule ExWebRTC.Media.Ogg.Header do
  @moduledoc false
  # based on RFC 7845, sec. 5

  @id_signature "OpusHead"
  @comment_signature "OpusTags"

  @vendor "elixir-webrtc"

  @default_preskip 3840
  @default_gain 0
  # mono or stereo
  @channel_mapping 0

  # for now, we ignore the Ogg/Opus header when decoding
  @spec decode_id(binary()) :: :ok | {:error, term()}
  def decode_id(<<@id_signature, _rest::binary>>), do: :ok
  def decode_id(_packet), do: {:error, :invalid_id_header}

  @spec decode_id(binary()) :: :ok | {:error, term()}
  def decode_comment(<<@comment_signature, _rest::binary>>), do: :ok
  def decode_commend(_packet), do: {:error, :invalid_comment_header}

  @spec create_id(non_neg_integer(), non_neg_integer()) :: binary()
  def create_id(sample_rate, channel_count) do
    <<
      @id_signature,
      1,
      channel_count,
      @default_preskip::little-16,
      sample_rate::little-32,
      @default_gain::little-16,
      @channel_mapping
    >>
  end

  @spec create_comment() :: binary()
  def create_comment() do
    <<
      @comment_signature,
      byte_size(@vendor)::little-32,
      @vendor,
      # no additional user comments
      0
    >>
  end
end
