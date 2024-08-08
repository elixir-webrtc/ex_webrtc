defmodule ExWebRTC.RTP.VP8.Payload do
  @moduledoc false
  # Defines VP8 payload structure stored in RTP packet payload.
  #
  # Based on [RFC 7741: RTP Payload Format for VP8 Video](https://datatracker.ietf.org/doc/html/rfc7741).

  @type t() :: %__MODULE__{
          n: 0 | 1,
          s: 0 | 1,
          pid: non_neg_integer(),
          picture_id: non_neg_integer() | nil,
          tl0picidx: non_neg_integer() | nil,
          tid: non_neg_integer() | nil,
          y: 0 | 1 | nil,
          keyidx: non_neg_integer() | nil,
          payload: binary()
        }

  @enforce_keys [:n, :s, :pid, :payload]
  defstruct @enforce_keys ++ [:picture_id, :tl0picidx, :tid, :y, :keyidx]

  @doc """
  Parses RTP payload as VP8 payload.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, :invalid_packet}
  def parse(rtp_payload)

  def parse(<<>>), do: {:error, :invalid_packet}

  def parse(<<0::1, 0::1, n::1, s::1, 0::1, pid::3, payload::binary>>) do
    if payload == <<>> do
      {:error, :invalid_packet}
    else
      {:ok,
       %__MODULE__{
         n: n,
         s: s,
         pid: pid,
         payload: payload
       }}
    end
  end

  def parse(<<1::1, 0::1, n::1, s::1, 0::1, pid::3, i::1, l::1, t::1, k::1, 0::4, rest::binary>>) do
    with {:ok, picture_id, rest} <- parse_picture_id(i, rest),
         {:ok, tl0picidx, rest} <- parse_tl0picidx(l, rest),
         {:ok, tid, y, keyidx, rest} <- parse_tidykeyidx(t, k, rest) do
      if rest == <<>> do
        {:error, :invalid_packet}
      else
        {:ok,
         %__MODULE__{
           n: n,
           s: s,
           pid: pid,
           picture_id: picture_id,
           tl0picidx: tl0picidx,
           tid: tid,
           y: y,
           keyidx: keyidx,
           payload: rest
         }}
      end
    end
  end

  def parse(_), do: {:error, :invalid_packet}

  defp parse_picture_id(0, rest),
    do: {:ok, nil, rest}

  defp parse_picture_id(1, <<0::1, picture_id::7, rest::binary>>), do: {:ok, picture_id, rest}
  defp parse_picture_id(1, <<1::1, picture_id::15, rest::binary>>), do: {:ok, picture_id, rest}
  defp parse_picture_id(_, _), do: {:error, :invalid_packet}

  defp parse_tl0picidx(0, rest), do: {:ok, nil, rest}
  defp parse_tl0picidx(1, <<tl0picidx, rest::binary>>), do: {:ok, tl0picidx, rest}
  defp parse_tl0picidx(_, _), do: {:error, :invalid_packet}

  defp parse_tidykeyidx(0, 0, rest), do: {:ok, nil, nil, nil, rest}

  defp parse_tidykeyidx(1, 0, <<tid::2, y::1, _keyidx::5, rest::binary>>),
    do: {:ok, tid, y, nil, rest}

  # note that both pion and web browser always set y bit to 0 in this case
  # but RFC 7741, sec. 4.2 (definition for Y bit) explicitly states that Y bit
  # can be set when T is 0 and K is 1
  defp parse_tidykeyidx(0, 1, <<_tid::2, y::1, keyidx::5, rest::binary>>),
    do: {:ok, nil, y, keyidx, rest}

  defp parse_tidykeyidx(1, 1, <<tid::2, y::1, keyidx::5, rest::binary>>),
    do: {:ok, tid, y, keyidx, rest}

  defp parse_tidykeyidx(_, _, _), do: {:error, :invalid_packet}

  @spec serialize(t()) :: binary()
  def serialize(
        %__MODULE__{
          picture_id: nil,
          tl0picidx: nil,
          tid: nil,
          y: nil,
          keyidx: nil
        } = vp8_payload
      ) do
    p = vp8_payload
    <<0::1, 0::1, p.n::1, p.s::1, 0::1, p.pid::3, p.payload::binary>>
  end

  def serialize(vp8_payload) do
    p = vp8_payload
    i = if p.picture_id, do: 1, else: 0
    l = if p.tl0picidx, do: 1, else: 0
    t = if p.tid, do: 1, else: 0
    k = if p.keyidx, do: 1, else: 0

    payload =
      <<1::1, 0::1, p.n::1, p.s::1, 0::1, p.pid::3, i::1, l::1, t::1, k::1, 0::4>>
      |> add_picture_id(p.picture_id)
      |> add_tl0picidx(p.tl0picidx)
      |> add_tidykeyidx(p.tid, p.y, p.keyidx)

    <<payload::binary, vp8_payload.payload::binary>>
  end

  defp add_picture_id(payload, nil), do: payload

  defp add_picture_id(payload, picture_id) when picture_id in 0..127 do
    <<payload::binary, 0::1, picture_id::7>>
  end

  defp add_picture_id(payload, picture_id) when picture_id in 128..32_767 do
    <<payload::binary, 1::1, picture_id::15>>
  end

  defp add_tl0picidx(payload, nil), do: payload

  defp add_tl0picidx(payload, tl0picidx) do
    <<payload::binary, tl0picidx>>
  end

  defp add_tidykeyidx(payload, nil, nil, nil), do: payload

  defp add_tidykeyidx(_payload, tid, nil, _keyidx) when tid != nil,
    do: raise("VP8 Y bit has to be set when TID is set")

  defp add_tidykeyidx(payload, tid, y, keyidx) do
    <<payload::binary, tid || 0::2, y || 0::1, keyidx || 0::5>>
  end
end
