defmodule ExWebRTC.SCTPTransport.DCEP do
  @moduledoc false
  # based on RFC 8832

  defmodule DataChannelAck do
    @moduledoc false

    defstruct []

    def decode(<<>>), do: {:ok, %__MODULE__{}}
    # Some implementations (e.g. Pion) seems to pad DataChannelAck to 4 bytes. Accept them.
    def decode(<<_, _, _>>), do: {:ok, %__MODULE__{}}
    def decode(_other), do: :error

    def encode(%__MODULE__{}), do: <<0x02>>
  end

  defmodule DataChannelOpen do
    @moduledoc false

    @enforce_keys [:reliability, :order, :label, :protocol, :priority, :param]
    defstruct @enforce_keys

    def decode(
          <<ch_type::8, priority::16, param::32, label_len::16, proto_len::16, rest::binary>>
        ) do
      with {:ok, reliability, order} <- to_channel_type(ch_type),
           <<label::binary-size(label_len), rest::binary>> <- rest,
           <<protocol::binary-size(proto_len)>> <- rest do
        dca =
          %__MODULE__{
            reliability: reliability,
            order: order,
            param: param,
            label: label,
            protocol: protocol,
            priority: priority
          }

        {:ok, dca}
      else
        _other -> :error
      end
    end

    def encode(%__MODULE__{} = dco) do
      ch_type = from_channel_type(dco.reliability, dco.order)
      label_len = byte_size(dco.label)
      proto_len = byte_size(dco.protocol)

      <<0x03::8, ch_type::8, dco.priority::16, dco.param::32, label_len::16, proto_len::16,
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
  end

  def decode(<<0x03::8, rest::binary>>), do: DataChannelOpen.decode(rest)
  def decode(<<0x02::8, rest::binary>>), do: DataChannelAck.decode(rest)
  def decode(_other), do: :error

  def encode(%mod{} = dcep), do: mod.encode(dcep)
end
