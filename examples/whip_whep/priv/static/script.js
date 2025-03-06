const pcConfig = { iceServers: [{ urls: "stun:stun.l.google.com:19302" }] };
const videoPlayer = document.getElementById("videoPlayer");
const candidates = [];
let patchEndpoint;

async function sendCandidate(candidate) {
  const response = await fetch(patchEndpoint, {
    method: "PATCH",
    cache: "no-cache",
    headers: {
      "Content-Type": "application/trickle-ice-sdpfrag"
    },
    body: candidate
  });

  if (response.status === 204) {
    console.log("Successfully sent ICE candidate:", candidate);
  } else {
    console.error(`Failed to send ICE, status: ${response.status}, candidate:`, candidate)
  }
}

async function connect() {
  const pc = new RTCPeerConnection(pcConfig);
  // expose pc for easier debugging and experiments
  window.pc = pc;

  pc.ontrack = event => videoPlayer.srcObject = event.streams[0];
  pc.onicegatheringstatechange = () => console.log("Gathering state change: " + pc.iceGatheringState);
  pc.onconnectionstatechange = () => console.log("Connection state change: " + pc.connectionState);
  pc.onicecandidate = event => {
    if (event.candidate == null) {
      return;
    }

    const candidate = JSON.stringify(event.candidate);
    if (patchEndpoint === undefined) {
      candidates.push(candidate);
    } else {
      sendCandidate(candidate);
    }
  }

  pc.addTransceiver("video", { direction: "recvonly" });
  pc.addTransceiver("audio", { direction: "recvonly" });

  const offer = await pc.createOffer()
  await pc.setLocalDescription(offer);

  const response = await fetch(`${window.location.origin}/whep`, {
    method: "POST",
    cache: "no-cache",
    headers: {
      "Accept": "application/sdp",
      "Content-Type": "application/sdp"
    },
    body: pc.localDescription.sdp
  });

  if (response.status === 201) {
    patchEndpoint = response.headers.get("location");
    console.log("Successfully initialized WHEP connection")

  } else {
    console.error(`Failed to initialize WHEP connection, status: ${response.status}`);
    return;
  }

  for (const candidate of candidates) {
    sendCandidate(candidate);
  }

  let sdp = await response.text();
  await pc.setRemoteDescription({ type: "answer", sdp: sdp });
}

connect();
