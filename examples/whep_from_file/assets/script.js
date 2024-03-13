const pcConfig = { 
  // iceServers: [
  //   { 'urls': 'stun:stun.l.google.com:19302' },
  // ] 
};
const whepEndpoint = `${window.location.protocol}//${window.location.host}/api/whep`;

const start_connection = async () => {
  const videoPlayer = document.getElementById("videoPlayer");

  let pc = new RTCPeerConnection(pcConfig);
  // Instruct the WHEP Endpoint that we'd like both audio and video if available
  pc.addTransceiver('video', { direction: 'recvonly' });
  pc.addTransceiver('audio', { direction: 'recvonly' });

  // Whenever a track does come in, add it to the existing video player
  pc.ontrack = event => videoPlayer.srcObject = event.streams[0];

  // Create our offer, will basically just be the codecs we support
  let offer = await pc.createOffer();
  await pc.setLocalDescription(offer);

  // Send our offer SDP to the WHEP endpoint, and expect an answer SDP in return
  const answerResponse = await fetch(whepEndpoint, {
    method: 'POST',
    cache: 'no-cache',
    headers: {
      'Accept': 'application/sdp',
      'Content-Type': 'application/sdp'
    },
    body: offer.sdp
  });
  if (answerResponse.status !== 201) {
    console.error(`Expected 201 from answerResponse, got ${answerResponse.status}`);
    return;
  }

  // Grab the answer and set it as the remote description
  // This should be enough to get the WebRTC stream negotiated
  let answer = await answerResponse.text();
  await pc.setRemoteDescription(new RTCSessionDescription({
    type: "answer", 
    sdp: answer
  }));
};

start_connection();