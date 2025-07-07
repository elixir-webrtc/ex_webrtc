# WebRTC SDP

WebRTC uses SDP offer/answer to negotiate session parameters (numer of audio/video tracks, their directions, codecs, etc.).
The way they are exchanged between both sides is not standardized. 
Very often it is a websocket.
WebRTC was standardized by (among others) Google, Cisco and Mozilla.
Cisco and Mozilla insisted on compatibility with SIP and telephone industry, hence a lot of strange things in WebRTC are present to allow for WebRTC <-> SIP interoperability (e.g. SDP, DTMF).

## General information

* an mline starts with `m=` and continues until the next mline or the end of the SDP
* an mline represents a transceiver or data channel
* audio/video mlines have direction - sendrecv, recvonly, sendonly, inactive
* an mline can be rejected - in such case, its direction is set to inactive
* when transceiver is stopped, port number in mline is set to 0
* port number in mline set to 9 means that connection address will be set dynamically via ICE
* SDP can include ICE candidates but it doesn't have to.
In particular, when you create the first offer it won't have any ICE candidates, but if you wait a couple of seconds and read peerconnection.localDescription it will contain ICE candidates that were gatherd throughout this time.
* offerer can offer to both send and receive
* mline includes a list of supported codecs.
They are sorted in preference order
* sender can switch between negotiated codecs without informing receiver about this fact.
Receiver has to be prepared for receiving any payload type accepted in SDP answer.
This is e.g. used to switch between audio from microphone and DTMF.
* each codec has its payload type - a number that identifies it and is included in RTP packet header
* fmtp stands for format parameters and denotes additional codec parameters e.g. profile level, minimal packetization length, etc.
* a lot of identifiers are obsolete (ssrc, cname, trackid in msid) but some implementations still rely on them (e.g. pion requries SSRC to be present in SDP to correctly demux incoming RTP streams). See RFC 8843, 9.2 for correct RTP demuxer algorithm. 
* rtcp-fb is RTCP feedback supported by offerer/answerer. 
Example feedbacks are used to request keyframes, retransmissions or to allow for congestion control implementation.

## Rules

1. Number of mlines in SDP answer MUST be the same as in the offer.
1. Number of mlines MUST NOT decrease between subsequent offer/answers.
1. SDP answer can exclude codecs, rtp header extensions, and rtcp feedbacks that were offered but are not supported by the answerer


## Dictionary

* SDP munging - manual SDP string modification to enable/disable some of the WebRTC features. 
It happens inbetween createOffer/createAnswer and setLocalDescription. 
E.g. when experimental support for a new codec was introduced, it could be enabled via SDP munging.


## Negotiating bidirectional P2P connection

See also [Mastering Transceivers](../advanced/mastering_transceivers.md) guide.

When the other side is a casual peer, in most cases we want to both send and receive a single audio and video.
This is the most common case.
Hence, when we add audio or video track via addTrack, and create offer via createOffer,
this offer will have mlines with directions set to sendrecv to allow for immediate, bidirectional session establishment.

When the other side is an SFU, we have at least 3 options:
* server sends, via signaling channel, information to the client on how many audio and video tracks there already are in the room.
Client sends SDP offer including both its own tracks and server's tracks.
This requires a single negotiation.
* client sends SDP offer only including its own tracks. 
After this is negotiated succsessfully, server sends its SDP offer.
This requries two negotiations.
* we use two separate peer connections, one for sending and one for receiving.
This way client and server can send their offers in parallel.
This was used e.g. by LiveKit.
