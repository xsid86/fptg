// The smallest pub/sub that does the job. UI modules talk through this
// rather than reaching into each other, so the chat list does not need
// to know that a header and a history exist.

const handlers = new Map();

export function on(event, fn) {
  if (!handlers.has(event)) handlers.set(event, new Set());
  handlers.get(event).add(fn);
  return () => off(event, fn);
}

export function off(event, fn) {
  handlers.get(event)?.delete(fn);
}

export function emit(event, payload) {
  // Copied before iterating: a handler is allowed to unsubscribe itself,
  // and mutating the set mid-iteration would skip its neighbour.
  for (const fn of [...(handlers.get(event) ?? [])]) {
    try {
      fn(payload);
    } catch (err) {
      console.error(`handler for "${event}" threw`, err);
    }
  }
}
