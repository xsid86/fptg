// Видеочат (групповой звонок чата) поверх WebRTC браузера.
//
// Сервер звонка — SFU Telegram, ICE-lite. TDLib только передаёт
// описания: joinVideoChat(join_parameters.payload) -> join_payload.
// Остальное — здесь, по описанию tgcalls (GroupJoinPayloadInternal,
// GroupInstanceReferenceImpl):
//
//  1. Свой offer: микрофон, видео (пока камера выключена — чёрный кадр,
//     чтобы SSRC видео были известны серверу с самого входа), канал
//     данных. Из него в join-payload уходят ufrag, pwd, отпечаток DTLS,
//     SSRC звука и группы SSRC видео:
//       {ufrag, pwd, fingerprints:[{hash, setup, fingerprint}],
//        ssrc, "ssrc-groups":[{semantics, sources}]}
//  2. Ответ сервера (transport: ufrag, pwd, fingerprints, candidates;
//     video/audio: payload-types, rtp-hdrexts) превращается в удалённый
//     answer на наш offer.
//  3. Участники (TDLib: audio_source_id, video_info.source_groups,
//     endpoint_id) — удалённый offer, где каждому чужому потоку своя
//     m-строка (sendonly, с его SSRC), mid по порядку с 3; ответ на него
//     создаёт браузер. Строки не удаляются — ушедшие становятся inactive.
//  4. Чьё видео присылать — сообщение ReceiverVideoConstraints по
//     каналу данных (colibriClass).

import { micConstraints, cameraConstraints, openMic } from './devices.js';

const OPUS = {
  id: 111, name: 'opus', clockrate: 48000, channels: 2,
  parameters: { minptime: '10', useinbandfec: '1' }, 'rtcp-fbs': [{ type: 'transport-cc' }],
};
const AUDIO_EXT_KEEP = [
  'urn:ietf:params:rtp-hdrext:ssrc-audio-level',
  'http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time',
  'http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01',
];
const RENEGOTIATE_MS = 200;
const VIDEO_MAX_HEIGHT = 720;
const VIDEO_MAX_HEIGHT_MANY = 360;
const VIDEO_MANY = 4;
const BLACK_FPS = 1;

// ------------------------------------------------------------ SDP
function sections(sdp) {
  const lines = sdp.split(/\r?\n/).filter(Boolean);
  const out = [];
  let cur = null;
  for (const line of lines) {
    if (line.startsWith('m=')) {
      cur = { m: line, lines: [] };
      out.push(cur);
    } else if (cur) {
      cur.lines.push(line);
    }
  }
  return out;
}

const attr = (sec, name) => sec.lines.find((l) => l.startsWith(`a=${name}:`))?.slice(name.length + 3) ?? '';

/** Что нужно из своего offer: транспорт, mids, SSRC, свои кодеки звука. */
export function parseLocal(sdp) {
  const secs = sections(sdp);
  const res = { mids: [], audioSsrc: 0, videoGroups: [], audioPT: [], audioExt: [] };
  for (const sec of secs) {
    const kind = sec.m.slice(2).split(' ')[0];
    const mid = attr(sec, 'mid');
    res.mids.push({ kind, mid });
    if (!res.ufrag) {
      res.ufrag = attr(sec, 'ice-ufrag');
      res.pwd = attr(sec, 'ice-pwd');
      const fp = attr(sec, 'fingerprint').split(' ');
      res.fingerprint = { hash: fp[0], fingerprint: fp[1], setup: attr(sec, 'setup') || 'actpass' };
    }
    const ssrcs = [...new Set(sec.lines.filter((l) => l.startsWith('a=ssrc:'))
      .map((l) => Number(l.slice(7).split(' ')[0])))];
    if (kind === 'audio' && !res.audioSsrc) {
      res.audioSsrc = ssrcs[0] ?? 0;
      for (const l of sec.lines) {
        const m = /^a=rtpmap:(\d+) opus\/48000\/2/i.exec(l);
        if (m) {
          res.audioPT = [{ ...OPUS, id: Number(m[1]), parameters: fmtpParams(sec, m[1]) || OPUS.parameters }];
        }
        const e = /^a=extmap:(\d+)(?:\/\S+)? (\S+)/.exec(l);
        if (e && AUDIO_EXT_KEEP.includes(e[2])) res.audioExt.push({ id: Number(e[1]), uri: e[2] });
      }
    }
    if (kind === 'video' && !res.videoGroups.length) {
      const groups = sec.lines.filter((l) => l.startsWith('a=ssrc-group:')).map((l) => {
        const [semantics, ...src] = l.slice(13).split(' ');
        return { semantics, sources: src.map(Number) };
      });
      res.videoGroups = groups.length ? groups : (ssrcs.length ? [{ semantics: 'SIM', sources: [ssrcs[0]] }] : []);
    }
  }
  return res;
}

function fmtpParams(sec, pt) {
  const line = sec.lines.find((l) => l.startsWith(`a=fmtp:${pt} `));
  if (!line) return null;
  const out = {};
  for (const kv of line.slice(`a=fmtp:${pt} `.length).split(';')) {
    const [k, v] = kv.split('=');
    if (k) out[k.trim()] = (v ?? '').trim();
  }
  return out;
}

const signed32 = (v) => v | 0;
const unsigned32 = (v) => v >>> 0;

/** join-payload для joinVideoChat. */
export function joinPayload(local) {
  const p = {
    ufrag: local.ufrag,
    pwd: local.pwd,
    fingerprints: [local.fingerprint],
    ssrc: unsigned32(local.audioSsrc),
  };
  if (local.videoGroups.length) p['ssrc-groups'] = local.videoGroups;
  return p;
}

function ptLines(types) {
  const out = [];
  for (const t of types ?? []) {
    out.push(`a=rtpmap:${t.id} ${t.name}/${t.clockrate}${t.channels > 1 ? `/${t.channels}` : ''}`);
    let params = t.parameters;
    if (Array.isArray(params)) params = Object.fromEntries(params);
    const fmtp = Object.entries(params ?? {}).map(([k, v]) => `${k}=${v}`).join(';');
    if (fmtp) out.push(`a=fmtp:${t.id} ${fmtp}`);
    for (const fb of t['rtcp-fbs'] ?? []) {
      out.push(`a=rtcp-fb:${t.id} ${fb.type}${fb.subtype ? ` ${fb.subtype}` : ''}`);
    }
  }
  return out;
}

function candidateLine(c) {
  let s = `a=candidate:${c.foundation} ${c.component} ${c.protocol} ${c.priority} ${c.ip} ${c.port} typ ${c.type}`;
  if (c['rel-addr']) s += ` raddr ${c['rel-addr']} rport ${c['rel-port']}`;
  if (c.tcptype) s += ` tcptype ${c.tcptype}`;
  s += ` generation ${c.generation ?? 0}`;
  return s;
}

/**
 * Удалённое описание целиком. answer — ответ на наш первый offer
 * (только наши m-строки); offer — с m-строками участников.
 */
export function buildRemote(conf, type) {
  const t = conf.transport;
  const fp = t.fingerprints?.[0] ?? {};
  // Роль DTLS не меняется между переговорами: в answer — что сказал
  // сервер (если сказал active/passive, иначе passive), в последующих
  // offer — та же.
  const setup = fp.setup === 'active' || fp.setup === 'passive' ? fp.setup : 'passive';
  const transport = [
    `a=ice-ufrag:${t.ufrag}`,
    `a=ice-pwd:${t.pwd}`,
    `a=fingerprint:${fp.hash} ${fp.fingerprint}`,
    `a=setup:${setup}`,
    ...(t.candidates ?? []).map(candidateLine),
  ];
  const media = (kind, mid, dir, extra = []) => {
    const pts = kind === 'audio' ? conf.audioPT : conf.videoPT;
    const ext = kind === 'audio' ? conf.audioExt : conf.videoExt;
    return [
      `m=${kind} 9 UDP/TLS/RTP/SAVPF ${pts.map((p) => p.id).join(' ')}`,
      'c=IN IP4 0.0.0.0',
      'a=rtcp:9 IN IP4 0.0.0.0',
      ...transport,
      `a=mid:${mid}`,
      'a=rtcp-mux',
      ...(kind === 'video' ? ['a=rtcp-rsize'] : []),
      ...ptLines(pts),
      ...(ext ?? []).map((e) => `a=extmap:${e.id} ${e.uri}`),
      `a=${dir}`,
      ...extra,
    ];
  };
  const out = [];
  const mids = [];
  for (const own of conf.local.mids) {
    mids.push(own.mid);
    if (own.kind === 'application') {
      out.push(
        'm=application 9 UDP/DTLS/SCTP webrtc-datachannel',
        'c=IN IP4 0.0.0.0',
        ...transport,
        `a=mid:${own.mid}`,
        'a=sctp-port:5000',
        'a=max-message-size:262144',
      );
    } else {
      out.push(...media(own.kind, own.mid, type === 'answer' ? 'recvonly' : 'sendrecv'));
    }
  }
  if (type === 'offer') {
    for (const r of conf.remote) {
      mids.push(r.mid);
      if (r.removed) {
        out.push(...media(r.kind, r.mid, 'inactive'));
        continue;
      }
      const stream = `p${r.key}`;
      const ssrcLines = [];
      for (const g of r.groups) {
        if (g.sources.length > 1) ssrcLines.push(`a=ssrc-group:${g.semantics} ${g.sources.map(unsigned32).join(' ')}`);
      }
      const all = [...new Set(r.groups.flatMap((g) => g.sources.map(unsigned32)))];
      ssrcLines.push(`a=msid:${stream} ${r.kind}${r.mid}`);
      for (const s of all) {
        ssrcLines.push(`a=ssrc:${s} cname:${stream}`, `a=ssrc:${s} msid:${stream} ${r.kind}${r.mid}`);
      }
      out.push(...media(r.kind, r.mid, 'sendonly', ssrcLines));
    }
  }
  const head = [
    'v=0',
    `o=- ${conf.sessionId} ${conf.version} IN IP4 0.0.0.0`,
    's=-',
    't=0 0',
    `a=group:BUNDLE ${mids.join(' ')}`,
    'a=ice-lite',
    'a=msid-semantic:WMS *',
  ];
  return `${[...head, ...out].join('\r\n')}\r\n`;
}

// ------------------------------------------------------------ сессия
function blackTrack() {
  const cv = document.createElement('canvas');
  cv.width = 16;
  cv.height = 16;
  const g = cv.getContext('2d');
  g.fillStyle = '#000';
  g.fillRect(0, 0, 16, 16);
  const stream = cv.captureStream(BLACK_FPS);
  // Без перерисовки captureStream не отдаёт кадров вовсе.
  const tick = setInterval(() => g.fillRect(0, 0, 16, 16), 1000 / BLACK_FPS);
  const track = stream.getVideoTracks()[0];
  track.addEventListener('ended', () => clearInterval(tick));
  return track;
}

/**
 * Сессия видеочата.
 *   join(payload) -> Promise<ответ сервера (строка)> — vchat.join;
 *   on: track({key, kind, stream}), untrack({key, kind}), log.
 */
export class GroupSession {
  constructor({ join, on }) {
    this.join = join;
    this.on = on;
    this.remote = [];          // {mid, kind, key, groups, removed, endpoint}
    this.nextMid = 3;
    this.queue = Promise.resolve();
    this.timer = 0;
    this.closed = false;
    this.wanted = new Map();   // key|kind -> {kind, key, groups, endpoint}
  }

  log(...m) {
    this.on.log?.(...m);
  }

  async start({ muted, video }) {
    this.pc = new RTCPeerConnection({ bundlePolicy: 'max-bundle', rtcpMuxPolicy: 'require' });
    const pc = this.pc;
    pc.ontrack = ({ transceiver, track, streams }) => {
      const r = this.remote.find((x) => x.mid === transceiver.mid);
      if (!r) return;
      this.on.track?.({ key: r.key, kind: r.kind, stream: streams[0] ?? new MediaStream([track]) });
    };
    pc.onconnectionstatechange = () => this.on.state?.(pc.connectionState);

    this.mic = await openMic(micConstraints({ echoCancellation: true, noiseSuppression: true, autoGainControl: true }));
    this.mic.getAudioTracks()[0].enabled = !muted;
    this.black = blackTrack();
    this.local = new MediaStream([this.mic.getAudioTracks()[0]]);
    this.audioSender = pc.addTrack(this.mic.getAudioTracks()[0], this.local);
    this.videoSender = pc.addTrack(this.black, this.local);
    this.dc = pc.createDataChannel('data');
    this.dc.onopen = () => this.sendConstraints();
    this.dc.onmessage = ({ data }) => this.log('dc', String(data).slice(0, 200));

    await pc.setLocalDescription(await pc.createOffer());
    const local = parseLocal(pc.localDescription.sdp);
    this.localInfo = local;
    const answerText = await this.join({
      ssrc: signed32(local.audioSsrc), payload: JSON.stringify(joinPayload(local)), muted, video,
    });
    const resp = JSON.parse(answerText);
    this.conf = {
      local,
      transport: resp.transport,
      audioPT: resp.audio?.['payload-types']?.length ? resp.audio['payload-types'] : (local.audioPT.length ? local.audioPT : [OPUS]),
      audioExt: resp.audio?.['rtp-hdrexts'] ?? local.audioExt,
      videoPT: resp.video?.['payload-types'] ?? [],
      videoExt: resp.video?.['rtp-hdrexts'] ?? [],
      remote: this.remote,
      sessionId: Date.now(),
      version: 2,
    };
    await pc.setRemoteDescription({ type: 'answer', sdp: buildRemote(this.conf, 'answer') });
    if (video) await this.setVideo(true);
    this.schedule();
  }

  /** Участники звонка (полный список от страницы). */
  setParticipants(list) {
    this.wanted.clear();
    for (const p of list) {
      if (p.self || p.left) continue;
      if (p.audioSource) {
        this.wanted.set(`${p.key}|audio`, { kind: 'audio', key: p.key, groups: [{ semantics: '', sources: [p.audioSource] }] });
      }
      for (const [field, suffix] of [['video', ''], ['screen', '#screen']]) {
        const v = p[field];
        if (v && v.groups?.length && this.conf?.videoPT.length) {
          this.wanted.set(`${p.key}${suffix}|video`, {
            kind: 'video', key: `${p.key}${suffix}`, groups: v.groups, endpoint: v.endpoint,
          });
        }
      }
      if (p.screenAudioSource) {
        this.wanted.set(`${p.key}#screen|audio`, {
          kind: 'audio', key: `${p.key}#screen`, groups: [{ semantics: '', sources: [p.screenAudioSource] }],
        });
      }
    }
    this.schedule();
  }

  schedule() {
    if (this.closed || !this.conf) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.queue = this.queue.then(() => this.renegotiate()).catch((e) => this.log('renegotiate', e));
    }, RENEGOTIATE_MS);
  }

  async renegotiate() {
    if (this.closed) return;
    let changed = false;
    const sig = (g) => JSON.stringify(g);
    for (const r of this.remote) {
      const w = this.wanted.get(`${r.key}|${r.kind}`);
      if (!r.removed && (!w || sig(w.groups) !== sig(r.groups))) {
        r.removed = true;
        changed = true;
        this.on.untrack?.({ key: r.key, kind: r.kind });
      }
    }
    for (const [id, w] of this.wanted) {
      if (this.remote.some((r) => !r.removed && `${r.key}|${r.kind}` === id)) continue;
      // Свободную (ушедшего) строку того же вида — переиспользовать.
      const free = this.remote.find((r) => r.removed && r.kind === w.kind);
      if (free) {
        Object.assign(free, { key: w.key, groups: w.groups, endpoint: w.endpoint, removed: false });
      } else {
        this.remote.push({ mid: String(this.nextMid++), ...w, removed: false });
      }
      changed = true;
    }
    if (!changed) return;
    this.conf.version += 1;
    const pc = this.pc;
    await pc.setRemoteDescription({ type: 'offer', sdp: buildRemote(this.conf, 'offer') });
    await pc.setLocalDescription(await pc.createAnswer());
    this.sendConstraints();
  }

  sendConstraints() {
    if (this.dc?.readyState !== 'open') return;
    const eps = this.remote.filter((r) => !r.removed && r.kind === 'video' && r.endpoint).map((r) => r.endpoint);
    const maxHeight = eps.length > VIDEO_MANY ? VIDEO_MAX_HEIGHT_MANY : VIDEO_MAX_HEIGHT;
    const constraints = {};
    for (const ep of eps) constraints[ep] = { minHeight: 0, maxHeight };
    this.dc.send(JSON.stringify({
      colibriClass: 'ReceiverVideoConstraints',
      defaultConstraints: { maxHeight: 0 },
      constraints,
      onStageEndpoints: [],
    }));
  }

  setMuted(muted) {
    const t = this.mic?.getAudioTracks()[0];
    if (t) t.enabled = !muted;
  }

  async setVideo(on) {
    if (on) {
      this.cam = await navigator.mediaDevices.getUserMedia({ video: cameraConstraints({ width: 1280, height: 720 }) });
      await this.videoSender.replaceTrack(this.cam.getVideoTracks()[0]);
    } else {
      await this.videoSender.replaceTrack(this.black);
      for (const t of this.cam?.getTracks() ?? []) t.stop();
      this.cam = null;
    }
  }

  async switchMic() {
    if (this.closed || !this.mic) return;
    const fresh = await openMic(micConstraints({ echoCancellation: true, noiseSuppression: true, autoGainControl: true }));
    const track = fresh.getAudioTracks()[0];
    track.enabled = this.mic.getAudioTracks()[0]?.enabled ?? false;
    await this.audioSender.replaceTrack(track);
    for (const old of this.mic.getTracks()) old.stop();
    this.mic = fresh;
  }

  async switchCamera() {
    if (this.closed || !this.cam) return;
    const cam = await navigator.mediaDevices.getUserMedia({ video: cameraConstraints({ width: 1280, height: 720 }) });
    await this.videoSender.replaceTrack(cam.getVideoTracks()[0]);
    for (const old of this.cam.getTracks()) old.stop();
    this.cam = cam;
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.timer);
    try { this.dc?.close(); } catch { /* закрыт */ }
    try { this.pc?.close(); } catch { /* закрыт */ }
    for (const t of [...(this.mic?.getTracks() ?? []), ...(this.cam?.getTracks() ?? [])]) t.stop();
    this.black?.stop();
  }
}
