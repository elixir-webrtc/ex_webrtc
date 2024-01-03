defmodule ExWebRTC.Media.OggWriter do
  @moduledoc """
  Writes Opus packets to an Ogg container file.

  For now, works only with packets from a single Opus stream.

  Based on:
  * [Xiph's official Ogg documentation](https://xiph.org/ogg/)
  * [RFC 7845: Ogg Encapsulation for the Opus Audio Codec](https://www.rfc-editor.org/rfc/rfc7845.txt)
  * [RFC 6716: Definition of the Opus Audio Codec](https://www.rfc-editor.org/rfc/rfc6716.txt)
  """

  import Bitwise

  alias ExWebRTC.Media.Ogg.Header
  alias ExWebRTC.Media.Opus

  @max_page_len 255 * 255
  @max_serial_no (1 <<< 32) - 1

  alias ExWebRTC.Media.Ogg.Page

  @opaque t() :: %__MODULE__{
            file: File.io_device(),
            page: Page.t(),
            seg_count: non_neg_integer()
          }

  @enforce_keys [:file, :page, :seg_count]
  defstruct @enforce_keys

  @spec open(
          Path.t(),
          sample_rate: non_neg_integer(),
          channel_count: non_neg_integer()
        ) :: {:ok, t()} | {:error, File.posix()}
  def open(path, opts \\ []) do
    page = %Page{
      serial_no: Enum.random(0..@max_serial_no),
      granule_pos: 0,
      sequence_no: 0
    }

    with {:ok, file} <- File.open(path, [:write]),
         writer <- %__MODULE__{file: file, page: page, seg_count: 0} do
      write_headers(writer, opts)
    end
  end

  @spec write_packet(t(), binary()) :: {:ok, t()} | {:error, term()}
  def write_packet(_writer, packet) when byte_size(packet) > @max_page_len do
    # we dont handle packets that would have to span more than one page
    {:error, :packet_too_long}
  end

  def write_packet(%__MODULE__{} = writer, packet) do
    seg_count = segment_count(packet)
    new_count = writer.seg_count + seg_count

    with {:ok, writer} <- if(new_count > 255, do: write_page(writer), else: {:ok, writer}),
         {:ok, duration} <- Opus.duration(packet) do
      # sample count == duration in seconds * clock rate == our duration / 1000 * 48_000
      sample_count = 48 * duration

      page = %Page{
        writer.page
        | packets: [packet | writer.page.packets],
          granule_pos: writer.page.granule_pos + sample_count
      }

      {:ok, %__MODULE__{writer | page: page, seg_count: writer.seg_count + seg_count}}
    end
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{file: file} = writer) do
    with {:ok, _writer} <- write_page(writer, true) do
      File.close(file)
    end
  end

  defp write_page(%__MODULE__{file: file, page: page}, last? \\ false) do
    page = %Page{page | last?: last?, packets: Enum.reverse(page.packets)}

    with :ok <- Page.write(file, page) do
      page = %Page{page | sequence_no: page.sequence_no + 1, packets: []}
      {:ok, %__MODULE__{file: file, page: page, seg_count: 0}}
    end
  end

  defp write_headers(%__MODULE__{file: file, page: page} = writer, opts) do
    sample_rate = Keyword.get(opts, :sample_rate, 48_000)
    channel_count = Keyword.get(opts, :channel_count, 1)

    id_header = Header.create_id(sample_rate, channel_count)
    comment_header = Header.create_comment()

    id_page = %Page{page | first?: true, sequence_no: 0, packets: [id_header]}
    comment_page = %Page{page | sequence_no: 1, packets: [comment_header]}

    with :ok <- Page.write(file, id_page),
         :ok <- Page.write(file, comment_page) do
      {:ok, %__MODULE__{writer | page: %Page{page | sequence_no: 2}}}
    end
  end

  defp segment_count(packet), do: div(byte_size(packet), 255) + 1
end
