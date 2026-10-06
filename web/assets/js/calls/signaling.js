// Сигнальный канал звонка: шифрование и кадры протокола tgcalls 10.0.0.
//
// TDLib только пересылает байты (sendCallSignalingData /
// updateNewCallSignalingData); что в них — дело клиентов. Здесь — то,
// что делает tgcalls (EncryptedConnection, тип Signaling), написанное по
// его описанию заново:
//
//   пакет на проводе:  msg_key(16) | AES-256-CTR(открытый текст)
//   открытый текст:    одно или несколько сообщений подряд
//   сообщение:         seq(4, BE) | тип(1) | тело
//     тип 0x7F — данные:  длина(4, BE) | байты (JSON сигналинга)
//     тип 0xFF — подтверждение сообщения с этим seq (не первым в пакете)
//     тип 0xFE — пустое (открывает служебный пакет из одних подтверждений)
//   seq: младшие 30 бит — счётчик, бит 30 — «нужно подтверждение»,
//        бит 31 — «в пакете одно сообщение».
//
// Ключи (ключ звонка — 256 байт от TDLib, encryption_key):
//   x = 128 + (8, если пакет идёт ОТ принимающей стороны звонка)
//   msg_key   = SHA256(key[88+x .. +32] | текст)[8..24]
//   a = SHA256(msg_key | key[x .. +36]),  b = SHA256(key[40+x .. +36] | msg_key)
//   aes_key   = a[0..8] | b[8..24] | a[24..32]
//   iv        = b[0..4] | a[8..16] | b[24..28]   (счётчик CTR — все 128 бит)
//
// Данные требуют подтверждения и повторяются, пока его нет (tgcalls:
// не раньше 3 с после прошлой отправки). Повторы приходят с прежним seq —
// уже доставленное подтверждается снова, но наверх не отдаётся.

const SEQ_SINGLE = 0x80000000;
const SEQ_NEEDS_ACK = 0x40000000;
const SEQ_COUNTER = 0x3fffffff;
const T_DATA = 0x7f;
const T_ACK = 0xff;
const T_EMPTY = 0xfe;

const RESEND_MS = 3000;          // minDelayBeforeMessageResend (Signaling)
const RESEND_TICK_MS = 500;
const ACK_FLUSH_MS = 50;         // подтверждения без попутного пакета
const REPLAY_WINDOW = 64;        // kKeepIncomingCountersCount
const DELIVERED_KEEP = 512;
const MIN_PACKET = 21;           // 16 msg_key + 4 seq + 1 тип
const MAX_PACKET = 128 * 1024;   // kMaxIncomingPacketSize
const MAX_SIGNALING_PACKET = 16 * 1024;

// ------------------------------------------------------------ байты
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

// ------------------------------------------------------------ шифр
/** Шифрование пакетов одного звонка. outgoing — call.is_outgoing. */
export class SignalingCipher {
  constructor(key, outgoing) {
    if (key.length !== 256) throw new Error('call key must be 256 bytes');
    this.key = key;
    this.outgoing = outgoing;
  }

  // x — смещение в ключе по направлению: свои пакеты и пакеты
  // собеседника шифруются разными частями ключа.
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

  /** Открытый текст или null (чужой, битый, подделанный пакет). */
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

// ------------------------------------------------------------ канал
/**
 * Канал сигналинга поверх шифра: send(строка) уходит пакетом через
 * emit(base64); receive(base64) отдаёт пришедшие строки в onMessage.
 */
export class SignalingChannel {
  constructor(cipher, { emit, onMessage, log = () => {} }) {
    this.cipher = cipher;
    this.emit = emit;
    this.onMessage = onMessage;
    this.log = log;
    this.counter = 0;
    this.unacked = [];          // { seq, bytes, sent }
    this.acks = [];             // seq сообщений собеседника к подтверждению
    this.seen = [];             // счётчики пришедших пакетов (окно повторов)
    this.delivered = new Set(); // счётчики отданных наверх сообщений
    this.ackTimer = 0;
    this.resendTimer = setInterval(() => this.resendDue(), RESEND_TICK_MS);
    this.closed = false;
    // Пакеты шифруются асинхронно — очередь держит их порядок.
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

  // Подтверждения и сообщения, которым пора повториться, — в хвост пакета.
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

  // Служебный пакет: пустое сообщение и следом подтверждения/повторы.
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

  // Окно повторов по счётчику пакета (registerIncomingCounter).
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
        // Пакет, начатый уже виденным сообщением, — повтор целиком,
        // но если это данные с просьбой подтвердить, подтверждение
        // могло потеряться: ответить ещё раз.
        if (!this.registerCounter(counter)) {
          if (type === T_DATA && (seq & SEQ_NEEDS_ACK)) this.queueAck(seq);
          return;
        }
      }
      if (type === T_EMPTY) {
        // ничего
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
