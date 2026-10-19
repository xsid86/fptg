// A call on top of the browser's WebRTC — the tgcalls 10.0.0 protocol
// (InstanceV2ReferenceImpl): the signalling is ordinary SDP and ICE candidates.
//
//   {"@type":"offer"|"answer", "sdp": "..."}
//   {"@type":"candidate", "sdp": "candidate:...", "mid": "0", "mline": 0}
//
// The caller (call.is_outgoing) offers as soon as the call is ready; the
// receiver answers the offer. New tracks (the camera turned on) — a new
// offer from either side; a collision of two offers is resolved as in
// tgcalls: the receiver yields (rolls back its own), the caller skips the
// other side's offer meanwhile.
//
// The "data" data channel is created by the caller; MediaState travels
// over it — whether the microphone is off, whether video is on.
//
// ICE: only servers of the WebRTC kind (STUN/TURN) — Telegram's reflectors
// speak their own protocol the browser cannot use. Without allowP2p — only
// TURN (iceTransportPolicy: relay), as in tgcalls.

import { SignalingCipher, SignalingChannel, b64ToBytes } from './signaling.js';
import { micConstraints, cameraConstraints, openMic } from './devices.js';
import { relayIceServer } from './relay.js';

export const CALL_VERSION = '10.0.0';

function iceServers(servers, allowP2p) {
  const out = [];
  for (const s of servers ?? []) {
    if (s.type !== 'webrtc') continue;
    const hosts = [s.ip, s.ipv6 ? `[${s.ipv6}]` : ''].filter(Boolean);
    for (const host of hosts) {
      if (s.stun && allowP2p) out.push({ urls: `stun:${host}:${s.port}` });
      if (s.turn) {
        out.push({ urls: `turn:${host}:${s.port}`, username: s.username, credential: s.password });
      }
    }
  }
  return out;
}

/**
 * One session per call in the ready state.
 *   call — the call object from the server (ready: key, servers, version...);
 *   send(b64) — send a signalling packet (call.signal);
 *   on — callbacks: state(string), remoteStream(MediaStream),
 *        localStream(MediaStream), remoteMedia({muted, video}), log.
 */
export class CallSession {
  constructor(call, { send, on }) {
    this.call = call;
    this.on = on;
    this.outgoing = !!call.outgoing;
    this.makingOffer = false;
    this.pendingCandidates = [];
    this.muted = false;
    this.videoOn = false;
    this.closed = false;
    this.channel = new SignalingChannel(
      new SignalingCipher(b64ToBytes(call.key), this.outgoing), {
        emit: send,
        onMessage: (text) => this.onSignal(text),
        log: (...m) => this.log(...m),
      });
  }

  log(...m) {
    this.on.log?.(...m);
  }

  async start(withVideo) {
    const servers = iceServers(this.call.servers, this.call.allowP2p);
    // The server's own relay (calls/relay.js) goes first: one more path,
    // or the only one in the "Always" mode.
    const relay = await relayIceServer();
    if (relay) servers.unshift(relay.server);
    this.log('ice servers', servers.length, relay ? `with the server relay${relay.only ? ' only' : ''}` : '');
    this.pc = new RTCPeerConnection({
      iceServers: servers,
      iceTransportPolicy: this.call.allowP2p && !relay?.only ? 'all' : 'relay',
      bundlePolicy: 'max-bundle',
      rtcpMuxPolicy: 'require',
    });
    const pc = this.pc;
    pc.onicecandidate = ({ candidate }) => {
      if (!candidate || !candidate.candidate) return;
      this.signal({
        '@type': 'candidate', sdp: candidate.candidate,
        mid: candidate.sdpMid ?? '', mline: candidate.sdpMLineIndex ?? 0,
      });
    };
    pc.onconnectionstatechange = () => this.on.state?.(pc.connectionState);
    pc.ontrack = ({ streams, track }) => {
      const stream = streams[0] ?? new MediaStream([track]);
      this.on.remoteStream?.(stream);
    };
    pc.ondatachannel = ({ channel }) => this.attachData(channel);
    // The receiver stays silent until the caller's first offer: its
    // microphone, added in advance, would otherwise cause a counter-offer itself.
    pc.onnegotiationneeded = () => {
      if (!this.outgoing && !this.negotiated) return;
      this.offer();
    };

    // The microphone is required — a call cannot start without it; the
    // camera is optional, its refusal does not bring the call down.
    this.local = await openMic(micConstraints());
    // addTrack, not addTransceiver: a track added this way the browser binds
    // to the line of the same kind from the incoming offer.
    pc.addTrack(this.local.getAudioTracks()[0], this.local);
    if (withVideo) await this.setVideo(true);
    this.on.localStream?.(this.local);

    if (this.outgoing) {
      this.attachData(pc.createDataChannel('data'));
      // onnegotiationneeded will send the offer after addTransceiver.
    }
  }

  attachData(dc) {
    this.dc = dc;
    dc.onopen = () => this.sendMediaState();
    dc.onmessage = async ({ data }) => {
      try {
        const text = typeof data === 'string' ? data : new TextDecoder().decode(
          data instanceof ArrayBuffer ? data : await data.arrayBuffer());
        const m = JSON.parse(text);
        if (m['@type'] === 'MediaState') {
          this.on.remoteMedia?.({ muted: !!m.muted, video: m.videoState === 'active' });
        }
      } catch (error) {
        this.log('data channel message', error);
      }
    };
  }

  sendMediaState() {
    if (this.dc?.readyState !== 'open') return;
    this.dc.send(JSON.stringify({
      '@type': 'MediaState',
      muted: this.muted,
      lowBattery: false,
      videoState: this.videoOn ? 'active' : 'inactive',
      videoRotation: 0,
      screencastState: 'inactive',
    }));
  }

  signal(obj) {
    if (!this.closed) this.channel.send(JSON.stringify(obj));
  }

  receive(b64) {
    if (!this.closed) this.channel.receive(b64);
  }

  async offer() {
    if (this.closed) return;
    try {
      this.makingOffer = true;
      await this.pc.setLocalDescription();
      const d = this.pc.localDescription;
      this.signal({ '@type': d.type, sdp: d.sdp });
    } catch (error) {
      this.log('offer failed', error);
    } finally {
      this.makingOffer = false;
    }
  }

  async onSignal(text) {
    let m;
    try {
      m = JSON.parse(text);
    } catch {
      this.log('signaling: not JSON', text.slice(0, 80));
      return;
    }
    const pc = this.pc;
    if (!pc) return;
    const type = m['@type'];
    try {
      if (type === 'offer' || type === 'answer') {
        const collision = type === 'offer' && (this.makingOffer || pc.signalingState !== 'stable');
        // The caller is the "impolite" side: it skips the other side's offer
        // while it has its own; the receiver rolls back its own (implicit rollback).
        if (collision && this.outgoing) return;
        await pc.setRemoteDescription({ type, sdp: m.sdp });
        this.negotiated = true;
        for (const c of this.pendingCandidates.splice(0)) await this.addCandidate(c);
        if (type === 'offer') {
          await pc.setLocalDescription();
          const d = pc.localDescription;
          this.signal({ '@type': d.type, sdp: d.sdp });
        }
      } else if (type === 'candidate') {
        if (!pc.remoteDescription) this.pendingCandidates.push(m);
        else await this.addCandidate(m);
      } else {
        this.log('signaling: unknown', type);
      }
    } catch (error) {
      this.log(`signaling ${type} failed`, error);
    }
  }

  async addCandidate(m) {
    try {
      await this.pc.addIceCandidate({ candidate: m.sdp, sdpMid: m.mid, sdpMLineIndex: m.mline });
    } catch (error) {
      this.log('bad candidate', error);
    }
  }

  setMuted(muted) {
    this.muted = muted;
    for (const t of this.local?.getAudioTracks() ?? []) t.enabled = !muted;
    this.sendMediaState();
  }

  async setVideo(on) {
    if (on === this.videoOn) return;
    if (on) {
      const cam = await navigator.mediaDevices.getUserMedia({ video: cameraConstraints() });
      const track = cam.getVideoTracks()[0];
      this.local.addTrack(track);
      if (this.videoSender) {
        await this.videoSender.replaceTrack(track);
        this.videoTransceiver.direction = 'sendrecv';
      } else {
        this.videoSender = this.pc.addTrack(track, this.local);
        this.videoTransceiver = this.pc.getTransceivers().find((t) => t.sender === this.videoSender);
      }
    } else {
      for (const t of this.local.getVideoTracks()) {
        t.stop();
        this.local.removeTrack(t);
      }
      await this.videoSender?.replaceTrack(null);
    }
    this.videoOn = on;
    this.on.localStream?.(this.local);
    this.sendMediaState();
  }

  /** Another microphone chosen — replace the track without negotiation. */
  async switchMic() {
    if (this.closed || !this.local) return;
    const fresh = await openMic(micConstraints());
    const track = fresh.getAudioTracks()[0];
    track.enabled = !this.muted;
    const sender = this.pc.getSenders().find((s) => s.track?.kind === 'audio');
    await sender?.replaceTrack(track);
    for (const old of this.local.getAudioTracks()) {
      this.local.removeTrack(old);
      old.stop();
    }
    this.local.addTrack(track);
  }

  /** Another camera chosen — if video is on, replace the track. */
  async switchCamera() {
    if (this.closed || !this.videoOn || !this.videoSender) return;
    const cam = await navigator.mediaDevices.getUserMedia({ video: cameraConstraints() });
    const track = cam.getVideoTracks()[0];
    await this.videoSender.replaceTrack(track);
    for (const old of this.local.getVideoTracks()) {
      this.local.removeTrack(old);
      old.stop();
    }
    this.local.addTrack(track);
    this.on.localStream?.(this.local);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.channel.close();
    try { this.dc?.close(); } catch { /* already closed */ }
    try { this.pc?.close(); } catch { /* already closed */ }
    for (const t of this.local?.getTracks() ?? []) t.stop();
  }
}
