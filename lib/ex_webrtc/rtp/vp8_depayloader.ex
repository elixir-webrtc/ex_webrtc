defmodule ExWebRTC.RTP.VP8Depayloader do
  @moduledoc """
  Reassembles VP8 frames from RTP packets.
  """
  require Logger

  defmodule VP8Payload do
    @moduledoc false

    @type t() :: %__MODULE__{
            n: boolean(),
            s: boolean(),
            pid: non_neg_integer() | nil,
            picture_id: non_neg_integer() | nil,
            tl0picidx: non_neg_integer() | nil,
            tid: non_neg_integer() | nil,
            y: boolean() | nil,
            keyidx: non_neg_integer() | nil,
            payload: binary()
          }

    @enforce_keys [:n, :s, :pid, :payload]
    defstruct @enforce_keys ++ [:picture_id, :tl0picidx, :tid, :y, :keyidx]
  end

  @opaque t() :: %__MODULE__{
            current_frame: nil,
            current_timestamp: nil
          }

  defstruct [:current_frame, :current_timestamp]

  @spec new() :: t()
  def new() do
    %__MODULE__{}
  end

  @spec write(t(), ExRTP.Packet.t()) :: {:ok, t()} | {:ok, binary(), t()}
  def write(depayloader, packet) do
    case parse(packet.payload) do
      {:ok, vp8_payload} ->
        depayloader =
          case {depayloader.current_frame, vp8_payload} do
            {nil, %VP8Payload{s: 1, pid: 0}} ->
              %{
                depayloader
                | current_frame: vp8_payload.payload,
                  current_timestamp: packet.timestamp
              }

            {nil, _vp8_payload} ->
              Logger.debug("Dropping vp8 payload as it doesn't start a new frame")
              depayloader

            {_current_frame, %VP8Payload{s: 1, pid: 0}} ->
              Logger.debug("""
              Received packet that starts a new frame without finishing the previous frame. \
              Droping previous frame.\
              """)

              %{depayloader | current_frame: vp8_payload.payload}

            _ when packet.timestamp != depayloader.current_timestamp ->
              Logger.debug("""
              Received packet with timestamp from a new frame that is not a start of this frame \
              and without finishing the previous frame. Droping both.\
              """)

              %{depayloader | current_frame: nil, current_timestamp: nil}

            {current_frame, vp8_payload} ->
              %{depayloader | current_frame: current_frame <> vp8_payload.payload}
          end

        case {depayloader.current_frame, packet.marker} do
          {current_frame, true} when current_frame != nil ->
            {:ok, current_frame, %{depayloader | current_frame: nil, current_timestamp: nil}}

          _ ->
            {:ok, depayloader}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp parse(<<0::1, 0::1, n::1, s::1, 0::1, pid::3, payload::binary>>) do
    %VP8Payload{
      n: n,
      s: s,
      pid: pid,
      payload: payload
    }
  end

  defp parse(<<1::1, 0::1, n::1, s::1, 0::1, pid::3, i::1, l::1, t::1, k::1, 0::4, rest::binary>>) do
    with {:ok, picture_id, rest} <- parse_picture_id(i, rest),
         {:ok, tl0picidx, rest} <- parse_tl0picidx(l, rest),
         {:ok, tid, y, keyidx, rest} <- parse_tidykeyidx(t, k, rest) do
      {:ok,
       %VP8Payload{
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

  defp parse_picture_id(0, rest), do: {:ok, nil, rest}
  defp parse_picture_id(1, <<0::1, picture_id::7, rest::binary>>), do: {:ok, picture_id, rest}
  defp parse_picture_id(1, <<1::1, picture_id::15, rest::binary>>), do: {:ok, picture_id, rest}
  defp parse_picture_id(_, _), do: {:error, :invalid_picture_id}

  defp parse_tl0picidx(0, rest), do: {:ok, nil, rest}
  defp parse_tl0picidx(1, <<tl0picidx, rest::binary>>), do: {:ok, tl0picidx, rest}
  defp parse_tl0picidx(_, _), do: {:error, :invalid_tl0picidx}

  defp parse_tidykeyidx(0, 0, rest), do: {:ok, nil, nil, nil, rest}

  defp parse_tidykeyidx(1, 0, <<tid::2, y::1, _keyidx::5, rest::binary>>),
    do: {:ok, tid, y, nil, rest}

  # note that both pion and web browser always set y bit to 0 in this case
  # but RFC explicitly states that y bit can be set when t is 0 and k is 1
  defp parse_tidykeyidx(0, 1, <<_tid::2, y::1, keyidx::5, rest::binary>>),
    do: {:ok, nil, y, keyidx, rest}

  defp parse_tidykeyidx(1, 1, <<tid::2, y::1, keyidx::5, rest::binary>>),
    do: {:ok, tid, y, keyidx, rest}

  defp parse_tidykeyidx(_, _, _), do: {:error, :invalid_tidykeyidx}
end
