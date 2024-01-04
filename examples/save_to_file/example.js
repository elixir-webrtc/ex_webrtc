const pcConfig = { 'iceServers': [{ 'urls': 'stun:stun.l.google.com:19302' }] };

const start_connection = async (ws) => {
    const pc = new RTCPeerConnection(pcConfig);

    pc.onconnectionstatechange = _ => console.log("Connection state changed:", pc.connectionState);
    pc.onicecandidateerror = event => console.log("ICE candidate error:", event);
    pc.oniceconnectionstatechange = _ => console.log("ICE connection state changed:", pc.iceConnectionState);
    pc.onicegatheringstatechange = _ => console.log("ICE gathering state changed:", pc.iceGatheringState);
    pc.onsignalingstatechange = _ => console.log("Signaling state changed:", pc.signalingState);
    pc.onicecandidate = event => {
        console.log("New local ICE candidate:", event.candidate);

        if (event.candidate !== null) {
            ws.send(JSON.stringify({ type: "ice", data: event.candidate }));
        }
    };

    const localStream = await navigator.mediaDevices.getUserMedia({
        audio: true,
        video: {
            width: { ideal: 640 },
            height: { ideal: 480 },
            frameRate: { ideal: 15 }
        }
    });
    const localVideoPlayer = document.getElementById("videoPlayer");
    localVideoPlayer.srcObject = localStream;
    for (const track of localStream.getTracks()) {
        pc.addTrack(track, localStream);
    }

    ws.onmessage = async event => {
        const msg = JSON.parse(event.data);

        if (msg.type === "answer") {
            console.log("Recieved SDP answer:", msg);
            pc.setRemoteDescription(msg);
        } else if (msg.type === "ice") {
            console.log("Recieved remote ICE candidate:", msg.data);
            pc.addIceCandidate(msg.data);
        } else {
            console.log("Received unexpected message:", msg);
        }
    };

    const desc = await pc.createOffer();
    console.log("Generated SDP offer:", desc);
    await pc.setLocalDescription(desc);
    ws.send(JSON.stringify(desc))
};

const ws = new WebSocket("ws://127.0.0.1:4000/websocket");
ws.onclose = event => console.log("WebSocket was closed", event);
ws.onopen = _ => start_connection(ws);
