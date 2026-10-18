// The call's signalling channel: encryption and frames of the tgcalls 10.0.0 protocol.
//
// TDLib only forwards the bytes (sendCallSignalingData /
// updateNewCallSignalingData); what is in them is the clients' business.
// Here is what tgcalls does (EncryptedConnection, the Signaling type),
// written anew from its description:
//
//   a packet on the wire: msg_key(16) | AES-256-CTR(plaintext)
//   plaintext:            one or several messages in a row
//   a message:            seq(4, BE) | type(1) | body
//     type 0x7F — data:  length(4, BE) | bytes (the signalling JSON)
//     type 0xFF — an acknowledgement of the message with this seq (not first in the packet)
//     type 0xFE — empty (opens a service packet of acknowledgements only)
//   seq: the low 30 bits — a counter, bit 30 — "needs acknowledgement",
//        bit 31 — "one message in the packet".
//
// Keys (the call key — 256 bytes from TDLib, encryption_key):
//   x = 128 + (8 if the packet comes FROM the call's receiving side)
//   msg_key   = SHA256(key[88+x .. +32] | text)[8..24]
//   a = SHA256(msg_key | key[x .. +36]),  b = SHA256(key[40+x .. +36] | msg_key)
//   aes_key   = a[0..8] | b[8..24] | a[24..32]
//   iv        = b[0..4] | a[8..16] | b[24..28]   (the CTR counter — all 128 bits)
//
// Data needs acknowledgement and is repeated until it comes (tgcalls: not
// earlier than 3 s after the previous send). Repeats come with the same seq
// — what was delivered already is acknowledged again but not passed up.

const SEQ_SINGLE = 0x80000000;
const SEQ_NEEDS_ACK = 0x40000000;
const SEQ_COUNTER = 0x3fffffff;
const T_DATA = 0x7f;
const T_ACK = 0xff;
const T_EMPTY = 0xfe;

const RESEND_MS = 3000;          // minDelayBeforeMessageResend (Signaling)
const RESEND_TICK_MS = 500;
const ACK_FLUSH_MS = 50;         // acknowledgements without a passing packet
const REPLAY_WINDOW = 64;        // kKeepIncomingCountersCount
const DELIVERED_KEEP = 512;
const MIN_PACKET = 21;           // 16 msg_key + 4 seq + 1 type
const MAX_PACKET = 128 * 1024;   // kMaxIncomingPacketSize
const MAX_SIGNALING_PACKET = 16 * 1024;

// ------------------------------------------------------------ bytes
export function b64ToBytes(s) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64(bytes) {
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

const u32 = (v) => new Uint8Array([(v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff]);
const readU32 = (b, at) => ((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]) >>> 0;

const sha256 = async (data) => new Uint8Array(await crypto.subtle.digest('SHA-256', data));

// ------------------------------------------------------------ cipher
/** Encryption of one call's packets. outgoing — call.is_outgoing. */
export class SignalingCipher {
  constructor(key, outgoing) {
    if (key.length !== 256) throw new Error('call key must be 256 bytes');
    this.key = key;
    this.outgoing = outgoing;
  }

  // x — the offset in the key by direction: own packets and the other
  // side's packets are encrypted with different parts of the key.
  x(mine) {
    const fromCallee = mine ? !this.outgoing : this.outgoing;
    return 128 + (fromCallee ? 8 : 0);
  }

  async aes(msgKey, x) {
    const a = await sha256(concat(msgKey, this.key.subarray(x, x + 36)));
    const b = await sha256(concat(this.key.subarray(40 + x, 40 + x + 36), msgKey));
    const aesKey = concat(a.subarray(0, 8), b.subarray(8, 24), a.subarray(24, 32));
    const iv = concat(b.subarray(0, 4), a.subarray(8, 16), b.subarray(24, 28));
    const k = await crypto.subtle.importKey('raw', aesKey, 'AES-CTR', false, ['encrypt', 'decrypt']);
    return { k, iv };
  }

  async msgKey(plain, x) {
    const large = await sha256(concat(this.key.subarray(88 + x, 88 + x + 32), plain));
    return large.subarray(8, 24);
  }

  async encrypt(plain) {
    const x = this.x(true);
    const msgKey = await this.msgKey(plain, x);
    const { k, iv } = await this.aes(msgKey, x);
    const body = new Uint8Array(await crypto.subtle.encrypt(
      { name: 'AES-CTR', counter: iv, length: 128 }, k, plain));
    return concat(msgKey, body);
  }

  /** The plaintext or null (someone else's, broken or forged packet). */
  async decrypt(packet) {
    if (packet.length < MIN_PACKET || packet.length > MAX_PACKET) return null;
    const x = this.x(false);
    const msgKey = packet.subarray(0, 16);
    const { k, iv } = await this.aes(msgKey, x);
    const plain = new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-CTR', counter: iv, length: 128 }, k, packet.subarray(16)));
    const check = await this.msgKey(plain, x);
    let diff = 0;
    for (let i = 0; i < 16; i += 1) diff |= check[i] ^ msgKey[i];
    return diff === 0 ? plain : null;
  }
}

// ------------------------------------------------------------ channel
/**
 * The signalling channel on top of the cipher: send(string) goes out as a
 * packet through emit(base64); receive(base64) passes incoming strings to onMessage.
 */
export class SignalingChannel {
  constructor(cipher, { emit, onMessage, log = () => {} }) {
    this.cipher = cipher;
    this.emit = emit;
    this.onMessage = onMessage;
    this.log = log;
    this.counter = 0;
    this.unacked = [];          // { seq, bytes, sent }
    this.acks = [];             // seq of the other side's messages to acknowledge
    this.seen = [];             // counters of incoming packets (the replay window)
    this.delivered = new Set(); // counters of messages passed up
    this.ackTimer = 0;
    this.resendTimer = setInterval(() => this.resendDue(), RESEND_TICK_MS);
    this.closed = false;
    // Packets are encrypted asynchronously — the queue keeps their order.
    this.chain = Promise.resolve();
  }

  close() {
    this.closed = true;
    clearInterval(this.resendTimer);
    clearTimeout(this.ackTimer);
  }

  nextSeq(needsAck, single) {
    this.counter = (this.counter + 1) & SEQ_COUNTER;
    return (this.counter | (needsAck ? SEQ_NEEDS_ACK : 0) | (single ? SEQ_SINGLE : 0)) >>> 0;
  }

  send(text) {
    if (this.closed) return;
    const data = new TextEncoder().encode(text);
    const seq = this.nextSeq(true, false);
    const bytes = concat(u32(seq), new Uint8Array([T_DATA]), u32(data.length), data);
    const item = { seq, bytes, sent: Date.now() };
    this.unacked.push(item);
    this.flush([bytes], item);
  }

  // Acknowledgements and messages due for a repeat — into the packet's tail.
  extras(size, except = null) {
    const out = [];
    let total = size;
    while (this.acks.length && total + 5 <= MAX_SIGNALING_PACKET) {
      out.push(concat(u32(this.acks.shift()), new Uint8Array([T_ACK])));
      total += 5;
    }
    const now = Date.now();
    for (const item of this.unacked) {
      if (item === except || now - item.sent < RESEND_MS) continue;
      if (total + item.bytes.length > MAX_SIGNALING_PACKET) break;
      item.sent = now;
      out.push(item.bytes);
      total += item.bytes.length;
    }
    return out;
  }

  flush(head, except = null) {
    clearTimeout(this.ackTimer);
    this.ackTimer = 0;
    const size = head.reduce((n, p) => n + p.length, 0);
    const plain = concat(...head, ...this.extras(size, except));
    this.chain = this.chain
      .then(() => this.cipher.encrypt(plain))
      .then((packet) => { if (!this.closed) this.emit(bytesToB64(packet)); })
      .catch((error) => this.log('signaling encrypt failed', error));
  }

  // A service packet: an empty message followed by acknowledgements/repeats.
  service() {
    const seq = this.nextSeq(false, false);
    this.flush([concat(u32(seq), new Uint8Array([T_EMPTY]))]);
  }

  resendDue() {
    if (this.closed) return;
    const now = Date.now();
    if (this.unacked.some((item) => now - item.sent >= RESEND_MS)) this.service();
  }

  queueAck(seq) {
    this.acks.push(seq);
    if (!this.ackTimer) this.ackTimer = setTimeout(() => this.service(), ACK_FLUSH_MS);
  }

  // The replay window by the packet counter (registerIncomingCounter).
  registerCounter(counter) {
    if (this.seen.includes(counter)) return false;
    const largest = this.seen.length ? Math.max(...this.seen) : 0;
    if (counter + REPLAY_WINDOW <= largest) return false;
    this.seen.push(counter);
    const floor = Math.max(counter, largest) - REPLAY_WINDOW;
    this.seen = this.seen.filter((c) => c > floor);
    return true;
  }

  receive(b64) {
    if (this.closed) return;
    const packet = b64ToBytes(b64);
    this.chain = this.chain
      .then(() => this.cipher.decrypt(packet))
      .then((plain) => {
        if (!plain) {
          this.log('signaling packet rejected (bad msg_key)');
          return;
        }
        this.parse(plain);
      })
      .catch((error) => this.log('signaling decrypt failed', error));
  }

  parse(plain) {
    if (plain.length < 5) return;
    let at = 0;
    let first = true;
    let single = false;
    while (at < plain.length) {
      if (!first && single) {
        this.log('signaling: data after a single-message packet');
        return;
      }
      if (at + 5 > plain.length) return;
      const seq = readU32(plain, at);
      const type = plain[at + 4];
      at += 5;
      const counter = seq & SEQ_COUNTER;
      if (first) {
        single = (seq & SEQ_SINGLE) !== 0;
        // A packet starting with an already seen message is a repeat whole,
        // but if it is data asking for acknowledgement, the acknowledgement
        // may have been lost: answer once more.
        if (!this.registerCounter(counter)) {
          if (type === T_DATA && (seq & SEQ_NEEDS_ACK)) this.queueAck(seq);
          return;
        }
      }
      if (type === T_EMPTY) {
        // nothing
      } else if (type === T_ACK) {
        if (first) return;
        this.unacked = this.unacked.filter((item) => (item.seq & SEQ_COUNTER) !== counter);
      } else if (type === T_DATA) {
        if (at + 4 > plain.length) return;
        const len = readU32(plain, at);
        at += 4;
        if (at + len > plain.length) return;
        const data = plain.subarray(at, at + len);
        at += len;
        let fresh = true;
        if (seq & SEQ_NEEDS_ACK) {
          this.queueAck(seq);
          fresh = !this.delivered.has(counter);
        } else if (!first) {
          fresh = this.registerCounter(counter);
        }
        if (fresh) {
          this.delivered.add(counter);
          if (this.delivered.size > DELIVERED_KEEP) {
            this.delivered.delete(this.delivered.values().next().value);
          }
          try {
            this.onMessage(new TextDecoder().decode(data));
          } catch (error) {
            this.log('signaling message handler failed', error);
          }
        }
      } else {
        this.log(`signaling: unknown message type ${type}`);
        return;
      }
      first = false;
    }
  }
}
