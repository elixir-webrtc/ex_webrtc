defmodule ExWebRTC.RTP.VP8.Munger do
  @moduledoc false
  # Module responsible for rewriting VP8 RTP payload fields
  # to provide transparent switch between simulcast encodings.
  import Bitwise

  alias ExWebRTC.RTP.VP8

  @type t() :: %__MODULE__{
          pic_id_used: boolean(),
          last_pic_id: integer(),
          pic_id_offset: integer(),
          tl0picidx_used: boolean(),
          last_tl0picidx: integer(),
          tl0picidx_offset: integer(),
          keyidx_used: boolean(),
          last_keyidx: integer(),
          keyidx_offset: integer()
        }

  defstruct pic_id_used: false,
            last_pic_id: 0,
            pic_id_offset: 0,
            tl0picidx_used: false,
            last_tl0picidx: 0,
            tl0picidx_offset: 0,
            keyidx_used: false,
            last_keyidx: 0,
            keyidx_offset: 0

  @spec new() :: t()
  def new() do
    %__MODULE__{}
  end

  @spec init(t(), binary()) :: t()
  def init(vp8_munger, rtp_payload) do
    {:ok, vp8_payload} = VP8.Payload.parse(rtp_payload)

    last_pic_id = vp8_payload.picture_id || 0
    last_tl0picidx = vp8_payload.tl0picidx || 0
    last_keyidx = vp8_payload.keyidx || 0

    %__MODULE__{
      vp8_munger
      | pic_id_used: vp8_payload.picture_id != nil,
        last_pic_id: last_pic_id,
        tl0picidx_used: vp8_payload.tl0picidx != nil,
        last_tl0picidx: last_tl0picidx,
        keyidx_used: vp8_payload.keyidx != nil,
        last_keyidx: last_keyidx
    }
  end

  @spec update(t(), binary()) :: t()
  def update(vp8_munger, rtp_payload) do
    {:ok, vp8_payload} = VP8.Payload.parse(rtp_payload)

    %VP8.Payload{
      keyidx: keyidx,
      picture_id: pic_id,
      tl0picidx: tl0picidx
    } = vp8_payload

    pic_id_offset = (vp8_munger.pic_id_used && pic_id - vp8_munger.last_pic_id - 1) || 0

    tl0picidx_offset =
      (vp8_munger.tl0picidx_used && tl0picidx - vp8_munger.last_tl0picidx - 1) || 0

    keyidx_offset = (vp8_munger.keyidx_used && keyidx - vp8_munger.last_keyidx - 1) || 0

    %__MODULE__{
      vp8_munger
      | pic_id_offset: pic_id_offset,
        tl0picidx_offset: tl0picidx_offset,
        keyidx_offset: keyidx_offset
    }
  end

  @spec munge(t(), binary()) :: {t(), binary()}
  def munge(vp8_munger, <<>> = rtp_payload), do: {vp8_munger, rtp_payload}

  def munge(vp8_munger, rtp_payload) do
    {:ok, vp8_payload} = VP8.Payload.parse(rtp_payload)

    %VP8.Payload{
      keyidx: keyidx,
      picture_id: pic_id,
      tl0picidx: tl0picidx
    } = vp8_payload

    munged_pic_id = pic_id && rem(pic_id + (1 <<< 15) - vp8_munger.pic_id_offset, 1 <<< 15)

    munged_tl0picidx =
      tl0picidx && rem(tl0picidx + (1 <<< 8) - vp8_munger.tl0picidx_offset, 1 <<< 8)

    munged_keyidx = keyidx && rem(keyidx + (1 <<< 5) - vp8_munger.keyidx_offset, 1 <<< 5)

    vp8_payload =
      %VP8.Payload{
        vp8_payload
        | keyidx: munged_keyidx,
          picture_id: munged_pic_id,
          tl0picidx: munged_tl0picidx
      }
      |> VP8.Payload.serialize()

    vp8_munger = %__MODULE__{
      vp8_munger
      | last_pic_id: munged_pic_id,
        last_tl0picidx: munged_tl0picidx,
        last_keyidx: munged_keyidx
    }

    {vp8_munger, vp8_payload}
  end
end
