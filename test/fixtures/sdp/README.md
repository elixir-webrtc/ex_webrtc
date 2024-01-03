# SDP Fixtures

All files were generated with the following code:

```js
pc = new RTCPeerConnection();
pc.addTransceiver("audio");
pc.addTransceiver("video");
await pc.createOffer();
```

* chromium_audio_video_sdp.txt - SDP generated in Chromium 120
* firefox_audio_video_sdp.txt - SDP generated in Firefox 121