// The fptg server's call relay (TURN, fptg-server/turnrelay.pas).
//
// The browser sends WebRTC media either directly or through a TURN server.
// When the fptg server runs elsewhere (a VPS) and this network cannot reach
// Telegram, direct media goes nowhere, so the server itself relays it: TURN
// over TCP on the same port as HTTPS. The media stays end-to-end encrypted
// (DTLS-SRTP); the server only forwards packets.
//
// Settings → Speakers and camera → "Route calls through the server":
// auto (default) — when the server is not on this computer; on; off.

import { call } from '../core/net.js';
import { serverBase } from '../core/session.js';
import { getPref } from '../util/prefs.js';

const LOOPBACK = /^(localhost|127(?:\.\d{1,3}){3}|\[::1\])$/i;

/** Whether calls should go through the server's relay right now. */
export function relayWanted() {
  const mode = getPref('callRelay');
  if (mode === 'on') return true;
  if (mode === 'off') return false;
  try {
    return !LOOPBACK.test(new URL(serverBase).hostname);
  } catch {
    return false;
  }
}

/**
 * The relay as an RTCIceServer, or null — not wanted or not available.
 * The address is the one this page reaches the server by: the server
 * cannot know its own public name or a port forwarding in front of it.
 */
export async function relayIceServer() {
  if (!relayWanted()) return null;
  let r;
  try {
    r = await call('relay.get');
  } catch {
    return null;
  }
  if (!r?.enabled) return null;
  const u = new URL(serverBase);
  const port = u.port || (u.protocol === 'http:' ? '80' : '443');
  return { urls: `turn:${u.hostname}:${port}?transport=tcp`, username: r.username, credential: r.credential };
}
