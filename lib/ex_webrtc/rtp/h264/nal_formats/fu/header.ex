defmodule ExWebRTC.RTP.H264.FU.Header do
  @moduledoc """
  Defines a structure representing Fragmentation Unit (FU) header
  which is defined in [RFC6184](https://tools.ietf.org/html/rfc6184#page-31)

  ```
    +---------------+
    |0|1|2|3|4|5|6|7|
    +-+-+-+-+-+-+-+-+
    |S|E|R|  Type   |
    +---------------+
  ```
  """

  alias Membrane.RTP.H264.NAL

  @typedoc """
  MUST be set to true only in the first packet in a sequence.
  """
  @type start_flag :: boolean()

  @typedoc """
  MUST be set to true only in the last packet in a sequence.
  """
  @type end_flag :: boolean()

  @enforce_keys [:type]
  defstruct start_bit: false, end_bit: false, type: 0

  @type t :: %__MODULE__{
          start_bit: start_flag(),
          end_bit: end_flag(),
          type: NAL.Header.type()
        }

  defguardp valid_frame_boundary(start, finish) when start != 1 or finish != 1

  @doc """
  Parses Fragmentation Unit Header

  It will fail if the Start bit and End bit are both set to one in the
  same Fragmentation Unit Header, because a fragmented NAL unit
  MUST NOT be transmitted in one FU.
  """
  @spec parse(data :: binary()) :: {:error, :packet_malformed} | {:ok, {t(), nal :: binary()}}
  def parse(<<start::1, finish::1, 0::1, nal_type::5, rest::binary>>)
      when nal_type in 1..23 and valid_frame_boundary(start, finish) do
    header = %__MODULE__{
      start_bit: start == 1,
      end_bit: finish == 1,
      type: nal_type
    }

    {:ok, {header, rest}}
  end

  def parse(_binary), do: {:error, :packet_malformed}

  @doc """
  Adds FU header
  """
  @spec add_header(binary(), 0 | 1, 0 | 1, NAL.Header.type()) :: binary()
  def add_header(payload, start_bit, end_bit, type),
    do: <<start_bit::1, end_bit::1, 0::1, type::5>> <> payload
end
