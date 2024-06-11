const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' },] };
// we set the resolution manually in order to give simulcast enough bitrate to create 3 encodings
const mediaConstraints = {video: {width: {ideal: 1280}, height: {ideal: 720}, frameRate: {ideal: 24}}, audio: true}

const proto = window.location.protocol === "https:" ? "wss:" : "ws:"
const ws = new WebSocket(`${proto}//${window.location.host}/ws`);
ws.onopen = _ => start_connection(ws);
ws.onclose = event => console.log("WebSocket connection was terminated:", event);

const start_connection = async (ws) => {
  const videoPlayer = document.getElementById("videoPlayer");
  videoPlayer.srcObject = new MediaStream();

  const pc = new RTCPeerConnection(pcConfig);
  pc.ontrack = event => videoPlayer.srcObject.addTrack(event.track);
  pc.onicecandidate = event => {
    if (event.candidate === null) return;

    console.log("Sent ICE candidate:", event.candidate);
    ws.send(JSON.stringify({ type: "ice", data: event.candidate }));
  };

  const localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
  pc.addTransceiver(localStream.getVideoTracks()[0], {
    direction: "sendrecv",
    streams: [localStream],
    sendEncodings: [
      { rid: "h", maxBitrate: 1200 * 1024},
      { rid: "m", scaleResolutionDownBy: 2, maxBitrate: 600 * 1024},
      { rid: "l", scaleResolutionDownBy: 4, maxBitrate: 300 * 1024 },
    ],
  });
  // replace the call above with this to disable simulcast
  // pc.addTrack(localStream.getVideoTracks()[0]);
  pc.addTrack(localStream.getAudioTracks()[0]);

  ws.onmessage = async event => {
    const {type, data} = JSON.parse(event.data);

    switch (type) {
      case "answer":
        console.log("Received SDP answer:", data);
        await pc.setRemoteDescription(data)
        break;
      case "ice":
        console.log("Recieved ICE candidate:", data);
        await pc.addIceCandidate(data);
    }
  };

  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  console.log("Sent SDP offer:", offer)
  ws.send(JSON.stringify({type: "offer", data: offer}));
};
