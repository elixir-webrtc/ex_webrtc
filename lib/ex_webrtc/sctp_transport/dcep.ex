defmodule ExWebRTC.SCTPTransport.DCEP do
  @moduledoc false
  # based on RFC 8832

  defmodule DataChannelAck do
    @moduledoc false

    defstruct []

    def decode(<<>>), do: {:ok, %__MODULE__{}}
    def decode(_other), do: :error

    def encode(%__MODULE__{}), do: <<0x02>>
  end

  defmodule DataChannelOpen do
    @moduledoc false

    @enforce_keys [:reliability, :order, :label, :protocol, :priority]
    defstruct @enforce_keys ++ [:max_rtx, :lifetime]

    def decode(
          <<ch_type::8, priority::16, param::32, label_len::16, proto_len::16, rest::binary>>
        ) do
      with {:ok, reliability, order} <- to_channel_type(ch_type),
           params <- %{reliability: reliability, order: order},
           params <- to_reliability_param(params, param),
           <<label::binary-size(label_len), rest::binary>> <- rest,
           <<protocol::binary-size(proto_len)>> <- rest do
        params
        |> Map.merge(%{label: label, protocol: protocol, priority: priority})
        |> then(&{:ok, struct!(__MODULE__, &1)})
      else
        _other -> :error
      end
    end

    def encode(%__MODULE__{} = dco) do
      ch_type = from_channel_type(dco.reliability, dco.order)
      param = from_reliability_param(dco)
      label_len = byte_size(dco.label)
      proto_len = byte_size(dco.protocol)

      <<0x03::8, ch_type::8, dco.priority::16, param::32, label_len::16, proto_len::16,
        dco.label::binary-size(label_len), dco.protocol::binary-size(proto_len)>>
    end

    # most significant bit determines order,
    # least significant 2 bits determine reliability
    defp to_channel_type(0x00), do: {:ok, :reliable, :ordered}
    defp to_channel_type(0x80), do: {:ok, :reliable, :unordered}
    defp to_channel_type(0x01), do: {:ok, :rexmit, :ordered}
    defp to_channel_type(0x81), do: {:ok, :rexmit, :unordered}
    defp to_channel_type(0x02), do: {:ok, :timed, :ordered}
    defp to_channel_type(0x82), do: {:ok, :timed, :unordered}
    defp to_channel_type(_other), do: :error

    defp from_channel_type(:reliable, :ordered), do: 0x00
    defp from_channel_type(:reliable, :unordered), do: 0x80
    defp from_channel_type(:rexmit, :ordered), do: 0x01
    defp from_channel_type(:rexmit, :unordered), do: 0x81
    defp from_channel_type(:timed, :ordered), do: 0x02
    defp from_channel_type(:timed, :unordered), do: 0x82

    defp to_reliability_param(%{reliability: :reliable} = params, _param), do: params

    defp to_reliability_param(%{reliability: :rexmit} = params, param),
      do: Map.put(params, :max_rtx, param)

    defp to_reliability_param(%{reliability: :timed} = params, param),
      do: Map.put(params, :lifetime, param)

    defp from_reliability_param(%__MODULE__{reliability: :rexmit, max_rtx: val}), do: val
    defp from_reliability_param(%__MODULE__{reliability: :timed, lifetime: val}), do: val
    defp from_reliability_param(%__MODULE__{reliability: :reliable}), do: 0
  end

  def decode(<<0x03::8, rest::binary>>), do: DataChannelOpen.decode(rest)
  def decode(<<0x02::8, rest::binary>>), do: DataChannelAck.decode(rest)
  def decode(_other), do: :error

  def encode(%mod{} = dcep), do: mod.encode(dcep)
end
