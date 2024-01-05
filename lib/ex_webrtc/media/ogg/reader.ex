defmodule ExWebRTC.Media.Ogg.Reader do
  @moduledoc """
  Reads Opus packets from an Ogg container file.

  For now, works only with single Opus stream in the container.

  Based on:
  * [Xiph's official Ogg documentation](https://xiph.org/ogg/)
  * [RFC 7845: Ogg Encapsulation for the Opus Audio Codec](https://www.rfc-editor.org/rfc/rfc7845.txt)
  * [RFC 6716: Definition of the Opus Audio Codec](https://www.rfc-editor.org/rfc/rfc6716.txt)
  """

  alias ExWebRTC.Media.Ogg.{Header, Page}
  alias ExWebRTC.Media.Opus

  @opaque t() :: %{
            file: File.io_device(),
            packets: [binary()],
            rest: binary()
          }

  @doc """
  Opens Ogg file.

  For now, works only with single Opus stream in the container.
  This function reads the ID and Comment Headers (and, for now, ignores them).
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, term()}
  def open(path) do
    with {:ok, file} <- File.open(path),
         reader <- %{file: file, packets: [], rest: <<>>},
         {:ok, id_header, reader} <- do_next_packet(reader),
         {:ok, comment_header, reader} <- do_next_packet(reader),
         :ok <- Header.decode_id(id_header),
         :ok <- Header.decode_comment(comment_header) do
      {:ok, reader}
    else
      :eof -> {:error, :invalid_file}
      {:error, _res} = err -> err
    end
  end

  @doc """
  Reads next Ogg packet.

  One Ogg packet is equivalent to one Opus packet.
  This function also returns the duration of the audio in milliseconds, based on Opus packet TOC sequence (see RFC 6716, sec. 3).
  It assumes that all of the Ogg packets belong to the same stream.
  """
  @spec next_packet(t()) :: {:ok, {binary(), non_neg_integer()}, t()} | {:error, term()} | :eof
  def next_packet(reader) do
    with {:ok, packet, reader} <- do_next_packet(reader),
         {:ok, duration} <- Opus.duration(packet) do
      {:ok, {packet, duration}, reader}
    end
  end

  @doc """
  Closes an Ogg reader.

  When a process owning the Ogg reader exits, Ogg reader is closed automatically. 
  """
  @spec close(t()) :: :ok | {:error, term()}
  def close(%{file: file}) do
    File.close(file)
  end

  defp do_next_packet(%{packets: [first | packets]} = reader) do
    {:ok, first, %{reader | packets: packets}}
  end

  defp do_next_packet(%{packets: []} = reader) do
    with {:ok, %Page{packets: packets, rest: rest}} <- Page.read(reader.file) do
      case packets do
        [] ->
          do_next_packet(%{reader | packets: [], rest: reader.rest <> rest})

        [first | packets] ->
          packet = rest <> first
          reader = %{reader | packets: packets, rest: rest}
          {:ok, packet, reader}
      end
    end
  end
end
