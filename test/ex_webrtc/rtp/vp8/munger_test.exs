defmodule ExWebRTC.RTP.VP8.MungerTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ExWebRTC.RTP.VP8

  test "handles encoding switch properly" do
    vp8_munger = VP8.Munger.new()

    rtp_payload =
      %VP8.Payload{
        keyidx: 28,
        n: 0,
        pid: 0,
        picture_id: 14_617,
        s: 0,
        tid: 0,
        tl0picidx: 19,
        y: 1,
        payload: <<0, 1, 2, 3>>
      }
      |> VP8.Payload.serialize()

    rtp_payload2 =
      %VP8.Payload{
        keyidx: 10,
        n: 0,
        pid: 0,
        picture_id: 11_942,
        s: 1,
        tid: 0,
        tl0picidx: 4,
        y: 1,
        payload: <<4, 5, 6, 7>>
      }
      |> VP8.Payload.serialize()

    vp8_munger = VP8.Munger.init(vp8_munger, rtp_payload)
    {vp8_munger, munged_rtp_payload} = VP8.Munger.munge(vp8_munger, rtp_payload)

    # nothing should change
    assert rtp_payload == munged_rtp_payload

    vp8_munger = VP8.Munger.update(vp8_munger, rtp_payload2)
    {_vp8_munger, munged_rtp_payload2} = VP8.Munger.munge(vp8_munger, rtp_payload2)

    assert {:ok,
            %VP8.Payload{
              keyidx: 29,
              n: 0,
              pid: 0,
              picture_id: 14_618,
              s: 1,
              tid: 0,
              tl0picidx: 20,
              y: 1
            }} = VP8.Payload.parse(munged_rtp_payload2)
  end

  test "handles rollovers properly" do
    vp8_munger = VP8.Munger.new()

    rtp_payload =
      %VP8.Payload{
        # max keyidx
        keyidx: (1 <<< 5) - 1,
        n: 0,
        pid: 0,
        # max picture id
        picture_id: (1 <<< 15) - 1,
        s: 0,
        tid: 0,
        # max tl0picidx
        tl0picidx: (1 <<< 8) - 1,
        y: 1,
        payload: <<0, 1, 2, 3>>
      }
      |> VP8.Payload.serialize()

    rtp_payload2 =
      %VP8.Payload{
        keyidx: 30,
        n: 0,
        pid: 0,
        picture_id: 11_942,
        s: 1,
        tid: 0,
        tl0picidx: 4,
        y: 1,
        payload: <<4, 5, 6, 7>>
      }
      |> VP8.Payload.serialize()

    vp8_munger = VP8.Munger.init(vp8_munger, rtp_payload)
    {vp8_munger, munged_rtp_payload} = VP8.Munger.munge(vp8_munger, rtp_payload)

    # nothing should change
    assert rtp_payload == munged_rtp_payload

    vp8_munger = VP8.Munger.update(vp8_munger, rtp_payload2)
    {_vp8_munger, munged_rtp_payload2} = VP8.Munger.munge(vp8_munger, rtp_payload2)

    assert {:ok,
            %VP8.Payload{
              keyidx: 0,
              n: 0,
              pid: 0,
              picture_id: 0,
              s: 1,
              tid: 0,
              tl0picidx: 0,
              y: 1
            }} = VP8.Payload.parse(munged_rtp_payload2)
  end

  test "doesn't create negative numbers after rollovers" do
    vp8_munger = VP8.Munger.new()

    rtp_payload =
      %VP8.Payload{
        keyidx: 20,
        n: 0,
        pid: 0,
        picture_id: 11_942,
        s: 1,
        tid: 0,
        tl0picidx: 4,
        y: 1,
        payload: <<0, 1, 2, 3>>
      }
      |> VP8.Payload.serialize()

    rtp_payload2 =
      %VP8.Payload{
        # max keyidx
        keyidx: (1 <<< 5) - 1,
        n: 0,
        pid: 0,
        # max picture id
        picture_id: (1 <<< 15) - 1,
        s: 0,
        tid: 0,
        # max tl0picidx
        tl0picidx: (1 <<< 8) - 1,
        y: 1,
        payload: <<4, 5, 6, 7>>
      }
      |> VP8.Payload.serialize()

    rtp_payload3 =
      %VP8.Payload{
        keyidx: 0,
        n: 0,
        pid: 0,
        picture_id: 0,
        s: 0,
        tid: 0,
        tl0picidx: 0,
        y: 1,
        payload: <<8, 9, 10, 11>>
      }
      |> VP8.Payload.serialize()

    vp8_munger = VP8.Munger.init(vp8_munger, rtp_payload)
    {vp8_munger, munged_rtp_payload} = VP8.Munger.munge(vp8_munger, rtp_payload)

    # nothing should change
    assert rtp_payload == munged_rtp_payload

    vp8_munger = VP8.Munger.update(vp8_munger, rtp_payload2)
    {vp8_munger, munged_rtp_payload2} = VP8.Munger.munge(vp8_munger, rtp_payload2)

    assert {:ok,
            %VP8.Payload{
              keyidx: 21,
              n: 0,
              pid: 0,
              picture_id: 11_943,
              s: 0,
              tid: 0,
              tl0picidx: 5,
              y: 1
            }} = VP8.Payload.parse(munged_rtp_payload2)

    {_vp8_munger, munged_rtp_payload3} = VP8.Munger.munge(vp8_munger, rtp_payload3)

    # check if picture_id, tl0picidx and keyidx are not negative
    assert {:ok,
            %VP8.Payload{
              keyidx: 22,
              n: 0,
              pid: 0,
              picture_id: 11_944,
              s: 0,
              tid: 0,
              tl0picidx: 6,
              y: 1
            }} = VP8.Payload.parse(munged_rtp_payload3)
  end
end
