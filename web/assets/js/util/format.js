// Formatting helpers. Anything that turns a number from the server into
// something a person reads lives here, so the same value never gets
// formatted two different ways in two different blocks.

const DAY_MS = 86400000;

/** Time for today, day/month for anything older - what a chat list shows. */
export function listTime(unix) {
  if (!unix) return '';
  const date = new Date(unix * 1000);
  const now = new Date();
  const sameDay = date.toDateString() === now.toDateString();
  if (sameDay) return date.toTimeString().slice(0, 5);
  if (now - date < 7 * DAY_MS) {
    return date.toLocaleDateString(undefined, { weekday: 'short' });
  }
  return date.toLocaleDateString(undefined, { day: '2-digit', month: '2-digit' });
}

export function clockTime(unix) {
  return unix ? new Date(unix * 1000).toTimeString().slice(0, 5) : '';
}

/** Badges stop being useful past a point and start stretching the row. */
export function countLabel(n) {
  if (n > 999) return '999+';
  return String(n);
}

/**
 * First visible character of a title, for the avatar placeholder.
 * Split by code point, not by index: an emoji or any astral character
 * is two UTF-16 units, and title[0] would hand back half of one.
 */
export function initial(title) {
  const trimmed = (title ?? '').trim();
  if (!trimmed) return '?';
  return [...trimmed][0].toUpperCase();
}

export function dateLabel(unix) {
  const date = new Date(unix * 1000);
  const now = new Date();
  if (date.toDateString() === now.toDateString()) return 'Today';
  const yesterday = new Date(now - DAY_MS);
  if (date.toDateString() === yesterday.toDateString()) return 'Yesterday';
  return date.toLocaleDateString(undefined, { day: 'numeric', month: 'long' });
}
