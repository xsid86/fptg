// OGG-контейнер для пакетов Opus — голосовые сообщения Telegram (OGG/Opus,
// один канал; td_api.tl, inputVoiceNote). MediaRecorder в WebView2 пишет
// Opus только в WebM, поэтому пакеты даёт AudioEncoder (WebCodecs), а
// контейнер собирается здесь: RFC 3533 (страницы OGG) и RFC 7845
// (OpusHead, OpusTags, granule в отсчётах 48 кГц с учётом pre-skip).

const CRC = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i += 1) {
    let r = i << 24;
    for (let j = 0; j < 8; j += 1) r = (r & 0x80000000) ? ((r << 1) ^ 0x04C11DB7) : (r << 1);
    t[i] = r >>> 0;
  }
  return t;
})();

function crc32(bytes) {
  let c = 0;
  for (let i = 0; i < bytes.length; i += 1) c = ((c << 8) ^ CRC[((c >>> 24) ^ bytes[i]) & 0xff]) >>> 0;
  return c;
}

const ascii = (s) => Uint8Array.from(s, (ch) => ch.charCodeAt(0));

/** Одна страница OGG из целых пакетов. */
function page(serial, seq, granule, flags, packets) {
  const lacing = [];
  for (const p of packets) {
    let n = p.length;
    while (n >= 255) {
      lacing.push(255);
      n -= 255;
    }
    lacing.push(n);
  }
  const bodyLen = packets.reduce((sum, p) => sum + p.length, 0);
  const out = new Uint8Array(27 + lacing.length + bodyLen);
  const v = new DataView(out.buffer);
  out.set(ascii('OggS'), 0);
  v.setUint8(4, 0);                     // версия
  v.setUint8(5, flags);                 // 2 — начало потока, 4 — конец
  v.setBigInt64(6, BigInt(granule), true);
  v.setUint32(14, serial, true);
  v.setUint32(18, seq, true);
  v.setUint32(22, 0, true);             // CRC — ниже, по всей странице
  v.setUint8(26, lacing.length);
  out.set(lacing, 27);
  let at = 27 + lacing.length;
  for (const p of packets) {
    out.set(p, at);
    at += p.length;
  }
  v.setUint32(22, crc32(out), true);
  return out;
}

/** Сколько сегментов займут пакеты (на странице не больше 255). */
const segmentsOf = (p) => Math.floor(p.length / 255) + 1;

/**
 * Пакеты Opus -> файл OGG (Blob audio/ogg).
 * packets: [{ data: Uint8Array, samples: отсчётов 48 кГц }];
 * preSkip — задержка кодировщика в отсчётах 48 кГц.
 */
export function oggOpus(packets, { preSkip = 312, channels = 1, inputRate = 48000 } = {}) {
  const serial = (Math.random() * 0xffffffff) >>> 0;
  const head = new Uint8Array(19);
  const hv = new DataView(head.buffer);
  head.set(ascii('OpusHead'), 0);
  hv.setUint8(8, 1);                    // версия
  hv.setUint8(9, channels);
  hv.setUint16(10, preSkip, true);
  hv.setUint32(12, inputRate, true);
  hv.setInt16(16, 0, true);             // усиление
  hv.setUint8(18, 0);                   // раскладка каналов: моно/стерео
  const vendor = ascii('fptg');
  const tags = new Uint8Array(8 + 4 + vendor.length + 4);
  const tv = new DataView(tags.buffer);
  tags.set(ascii('OpusTags'), 0);
  tv.setUint32(8, vendor.length, true);
  tags.set(vendor, 12);
  tv.setUint32(12 + vendor.length, 0, true);

  const pages = [page(serial, 0, 0, 2, [head]), page(serial, 1, 0, 0, [tags])];
  let seq = 2;
  let granule = preSkip;
  let batch = [];
  let segs = 0;
  const flush = (last) => {
    if (!batch.length && !last) return;
    pages.push(page(serial, seq, granule, last ? 4 : 0, batch.map((p) => p.data)));
    seq += 1;
    batch = [];
    segs = 0;
  };
  packets.forEach((p, i) => {
    if (segs + segmentsOf(p.data) > 255 || batch.length >= 50) flush(false);
    batch.push(p);
    segs += segmentsOf(p.data);
    granule += p.samples;
    if (i === packets.length - 1) flush(true);
  });
  if (!packets.length) flush(true);
  return new Blob(pages, { type: 'audio/ogg' });
}

/**
 * Пики громкости -> waveform Telegram: 100 значений по 5 бит (0..31),
 * упакованных подряд от младших битов, в base64 (поле bytes в JSON TDLib).
 */
export function waveform5bit(peaks, count = 100) {
  const values = new Array(count).fill(0);
  if (peaks.length) {
    for (let i = 0; i < count; i += 1) {
      const from = Math.floor((i * peaks.length) / count);
      const to = Math.max(from + 1, Math.floor(((i + 1) * peaks.length) / count));
      let m = 0;
      for (let j = from; j < to && j < peaks.length; j += 1) m = Math.max(m, peaks[j]);
      values[i] = m;
    }
    const max = Math.max(...values) || 1;
    for (let i = 0; i < count; i += 1) values[i] = Math.min(31, Math.round((values[i] / max) * 31));
  }
  const bytes = new Uint8Array(Math.ceil((count * 5) / 8));
  values.forEach((v, i) => {
    const bit = i * 5;
    const idx = bit >> 3;
    const shift = bit & 7;
    bytes[idx] |= (v << shift) & 0xff;
    if (shift > 3 && idx + 1 < bytes.length) bytes[idx + 1] |= v >> (8 - shift);
  });
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return { values, base64: btoa(bin) };
}
