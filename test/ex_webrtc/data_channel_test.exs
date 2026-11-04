defmodule ExWebRTC.DataChannelTest do
  use ExUnit.Case, async: true

  import ExWebRTC.Support.TestUtils

  alias ExWebRTC.{DataChannel, PeerConnection, MediaStreamTrack}

  test "establishing channels" do
    {:ok, pc1} = PeerConnection.start_link()
    {:ok, pc2} = PeerConnection.start_link()

    label1 = "my label 1"
    {:ok, %DataChannel{ref: ref1, id: nil}} = PeerConnection.create_data_channel(pc1, label1)
    assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}

    :ok = negotiate(pc1, pc2)

    refute_receive {:ex_webrtc, ^pc2, {:data_channel, _}}

    :ok = connect(pc1, pc2)

    assert_receive {:ex_webrtc, ^pc2, {:data_channel, chan1}}
    assert %DataChannel{ref: rem_ref1, id: 1, label: ^label1, ordered: true} = chan1
    assert_receive {:ex_webrtc, ^pc2, {:data_channel_state_change, ^rem_ref1, :open}}
    assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^ref1, :open}}

    assert %DataChannel{id: 1} = PeerConnection.get_data_channel(pc1, ref1)

    label2 = "my label 2"
    protocol = "my proto"

    {:ok, %DataChannel{ref: ref2}} =
      PeerConnection.create_data_channel(pc1, label2, protocol: protocol, ordered: false)

    refute_receive {:ex_webrtc, ^pc1, :negotiation_needed}

    assert_receive {:ex_webrtc, ^pc2, {:data_channel, chan2}}

    assert %DataChannel{ref: rem_ref2, id: 3, label: ^label2, protocol: ^protocol, ordered: false} =
             chan2

    assert_receive {:ex_webrtc, ^pc2, {:data_channel_state_change, ^rem_ref2, :open}}
    assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^ref2, :open}}

    label3 = "my label 3"
    {:ok, %DataChannel{ref: ref3}} = PeerConnection.create_data_channel(pc2, label3)

    refute_receive {:ex_webrtc, ^pc2, :negotiation_needed}

    assert_receive {:ex_webrtc, ^pc1, {:data_channel, chan3}}
    assert %DataChannel{ref: rem_ref3, id: 4, label: ^label3} = chan3
    assert_receive {:ex_webrtc, ^pc2, {:data_channel_state_change, ^ref3, :open}}
    assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^rem_ref3, :open}}
  end

  describe "closing the channel" do
    setup do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, %DataChannel{ref: ref1}} = PeerConnection.create_data_channel(pc1, "label")

      :ok = negotiate(pc1, pc2)
      :ok = connect(pc1, pc2)

      assert_receive {:ex_webrtc, ^pc2, {:data_channel, %DataChannel{ref: ref2}}}
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^ref1, :open}}

      %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2}
    end

    test "by initiating peer", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      assert :ok = PeerConnection.close_data_channel(pc1, ref1)
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^ref1, :closed}}
      assert_receive {:ex_webrtc, ^pc2, {:data_channel_state_change, ^ref2, :closed}}
    end

    test "by receiving peer", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      assert :ok = PeerConnection.close_data_channel(pc2, ref2)
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^ref1, :closed}}
      assert_receive {:ex_webrtc, ^pc2, {:data_channel_state_change, ^ref2, :closed}}
    end
  end

  describe "negotiating" do
    test "with only channel added" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()

      label = "my label"
      {:ok, %DataChannel{ref: ref1}} = PeerConnection.create_data_channel(pc1, label)

      :ok = negotiate(pc1, pc2)
      :ok = connect(pc1, pc2)

      assert_receive {:ex_webrtc, ^pc2, {:data_channel, %DataChannel{label: ^label}}}
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^ref1, :open}}
    end

    test "with channel mixed with transceivers" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()

      {:ok, _sender} = PeerConnection.add_track(pc1, MediaStreamTrack.new(:audio))
      label1 = "my label"
      {:ok, %DataChannel{ref: ref1}} = PeerConnection.create_data_channel(pc1, label1)
      {:ok, _sender} = PeerConnection.add_track(pc1, MediaStreamTrack.new(:video))

      :ok = negotiate(pc1, pc2)
      :ok = connect(pc1, pc2)

      assert_receive {:ex_webrtc, ^pc2, {:data_channel, %DataChannel{label: ^label1}}}
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^ref1, :open}}

      # add more tracks and channels and renegotiate
      {:ok, _sender} = PeerConnection.add_track(pc1, MediaStreamTrack.new(:video))
      :ok = negotiate(pc1, pc2)

      label2 = "my label 2"
      {:ok, %DataChannel{ref: ref2}} = PeerConnection.create_data_channel(pc2, label2)
      assert_receive {:ex_webrtc, ^pc1, {:data_channel, %DataChannel{label: ^label2}}}
      assert_receive {:ex_webrtc, ^pc2, {:data_channel_state_change, ^ref2, :open}}
    end

    test "with channel added only in renegotiation" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, _sender} = PeerConnection.add_track(pc1, MediaStreamTrack.new(:audio))
      {:ok, _sender} = PeerConnection.add_track(pc1, MediaStreamTrack.new(:video))

      :ok = negotiate(pc1, pc2)
      :ok = connect(pc1, pc2)

      label = "my label"
      {:ok, %DataChannel{ref: ref}} = PeerConnection.create_data_channel(pc2, label)

      refute_receive {:ex_webrtc, ^pc1, {:data_channel, _}}

      :ok = negotiate(pc2, pc1)

      assert_receive {:ex_webrtc, ^pc1, {:data_channel, %DataChannel{label: ^label}}}
      assert_receive {:ex_webrtc, ^pc2, {:data_channel_state_change, ^ref, :open}}
    end
  end

  describe "negotiating max message size" do
    test "advertises max-message-size in offer and answer" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, _channel} = PeerConnection.create_data_channel(pc1, "label")

      {:ok, offer} = PeerConnection.create_offer(pc1)
      assert offer.sdp =~ "a=max-message-size:65536"

      :ok = PeerConnection.set_local_description(pc1, offer)
      :ok = PeerConnection.set_remote_description(pc2, offer)

      {:ok, answer} = PeerConnection.create_answer(pc2)
      assert answer.sdp =~ "a=max-message-size:65536"
    end

    test "respects max-message-size of the remote peer" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, %DataChannel{ref: ref1}} = PeerConnection.create_data_channel(pc1, "label")

      {:ok, offer} = PeerConnection.create_offer(pc1)
      :ok = PeerConnection.set_local_description(pc1, offer)
      :ok = PeerConnection.set_remote_description(pc2, offer)
      {:ok, answer} = PeerConnection.create_answer(pc2)
      :ok = PeerConnection.set_local_description(pc2, answer)

      assert answer.sdp =~ "a=max-message-size:65536"
      sdp = String.replace(answer.sdp, "a=max-message-size:65536", "a=max-message-size:1024")
      :ok = PeerConnection.set_remote_description(pc1, %{answer | sdp: sdp})

      :ok = connect(pc1, pc2)

      assert_receive {:ex_webrtc, ^pc2, {:data_channel, %DataChannel{ref: ref2}}}
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^ref1, :open}}

      :ok = PeerConnection.send_data(pc1, ref1, :binary.copy(<<1>>, 1025))
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_error, ^ref1, :message_too_large}}

      data = :binary.copy(<<1>>, 1024)
      :ok = PeerConnection.send_data(pc1, ref1, data)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, ^data}}

      # pc2 did not get a lower limit
      data = :binary.copy(<<2>>, 1025)
      :ok = PeerConnection.send_data(pc2, ref2, data)
      assert_receive {:ex_webrtc, ^pc1, {:data, ^ref1, ^data}}
    end
  end

  describe "sending data" do
    setup do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, %DataChannel{ref: ref1}} = PeerConnection.create_data_channel(pc1, "label")

      :ok = negotiate(pc1, pc2)
      :ok = connect(pc1, pc2)

      assert_receive {:ex_webrtc, ^pc2, {:data_channel, %DataChannel{ref: ref2}}}
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_state_change, ^ref1, :open}}

      %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2}
    end

    test "from initiating peer", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      data1 = <<1, 2, 3>>
      :ok = PeerConnection.send_data(pc1, ref1, data1)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, ^data1}}

      data2 = for i <- 1..2000, into: <<>>, do: <<i>>
      :ok = PeerConnection.send_data(pc1, ref1, data2)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, ^data2}}

      :ok = PeerConnection.send_data(pc1, ref1, <<>>)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, <<>>}}
    end

    test "from other peer", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      data1 = <<1, 2, 3>>
      :ok = PeerConnection.send_data(pc2, ref2, data1)
      assert_receive {:ex_webrtc, ^pc1, {:data, ^ref1, ^data1}}

      data2 = <<>>
      :ok = PeerConnection.send_data(pc2, ref2, data2)
      assert_receive {:ex_webrtc, ^pc1, {:data, ^ref1, ^data2}}
    end

    test "as binary", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      data1 = <<1, 2, 3>>
      :ok = PeerConnection.send_data(pc1, ref1, data1, :binary)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, ^data1}}

      data2 = for i <- 1..2000, into: <<>>, do: <<i>>
      :ok = PeerConnection.send_data(pc1, ref1, data2, :binary)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, ^data2}}

      :ok = PeerConnection.send_data(pc1, ref1, <<>>, :binary)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, <<>>}}
    end

    test "back and forth", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      data = for i <- 1..1024, into: <<>>, do: <<i>>
      :ok = PeerConnection.send_data(pc2, ref2, data)
      assert_receive {:ex_webrtc, ^pc1, {:data, ^ref1, msg}}
      :ok = PeerConnection.send_data(pc1, ref1, msg)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, next_msg}}
      :ok = PeerConnection.send_data(pc2, ref2, next_msg)
      assert_receive {:ex_webrtc, ^pc1, {:data, ^ref1, ^data}}
    end

    test "over distinct channels", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      {:ok, %DataChannel{ref: ref3}} = PeerConnection.create_data_channel(pc2, "next label")
      assert_receive {:ex_webrtc, ^pc1, {:data_channel, %DataChannel{ref: ref4}}}

      data = for i <- 1..1024, into: <<>>, do: <<i>>
      :ok = PeerConnection.send_data(pc1, ref4, data)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref3, msg}}
      :ok = PeerConnection.send_data(pc2, ref2, msg)
      assert_receive {:ex_webrtc, ^pc1, {:data, ^ref1, ^data}}
    end

    test "larger than max message size", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      :ok = PeerConnection.send_data(pc1, ref1, :binary.copy(<<1>>, 65_537))
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_error, ^ref1, :message_too_large}}
      refute_receive {:ex_webrtc, ^pc2, {:data, ^ref2, _data}}

      # peer connection and channel are still usable
      :ok = PeerConnection.send_data(pc1, ref1, <<1, 2, 3>>)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, <<1, 2, 3>>}}
    end

    test "equal to max message size", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      data = :binary.copy(<<1>>, 65_536)
      :ok = PeerConnection.send_data(pc1, ref1, data, :binary)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, ^data}}
      refute_receive {:ex_webrtc, ^pc1, {:data_channel_error, _ref, _reason}}
    end

    test "does not count failed sends in stats", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      :ok = PeerConnection.send_data(pc1, ref1, :binary.copy(<<1>>, 65_537))
      assert_receive {:ex_webrtc, ^pc1, {:data_channel_error, ^ref1, :message_too_large}}

      :ok = PeerConnection.send_data(pc1, ref1, <<1, 2, 3>>)
      assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, <<1, 2, 3>>}}

      stats = PeerConnection.get_stats(pc1)
      assert {_ref, channel_stats} = Enum.find(stats, fn {_, v} -> v.type == :data_channel end)
      assert channel_stats.messages_sent == 1
      assert channel_stats.bytes_sent == 3
    end

    test "and collecting stats about it", %{pc1: pc1, pc2: pc2, ref1: ref1, ref2: ref2} do
      for _ <- 1..10 do
        :ok = PeerConnection.send_data(pc1, ref1, <<1, 2, 3>>)
      end

      for _ <- 1..10 do
        assert_receive {:ex_webrtc, ^pc2, {:data, ^ref2, <<1, 2, 3>>}}
      end

      stats1 = PeerConnection.get_stats(pc1)
      assert {_ref, channel_stats1} = Enum.find(stats1, fn {_, v} -> v.type == :data_channel end)
      assert channel_stats1.bytes_sent == 30
      assert channel_stats1.messages_sent == 10

      stats2 = PeerConnection.get_stats(pc2)
      assert {_ref, channel_stats2} = Enum.find(stats2, fn {_, v} -> v.type == :data_channel end)
      assert channel_stats2.bytes_received == 30
      assert channel_stats2.messages_received == 10
    end
  end
end
