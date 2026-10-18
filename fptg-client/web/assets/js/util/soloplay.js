// One playback with sound at a time.
//
// Videos in the history, in the viewer, voice messages and music — each
// has its own player, and they used to be able to play at once. The rule
// is one for the whole document: as soon as something starts playing with
// sound, everything else with sound pauses.
//
// Muted ones (GIFs, video stickers, animated avatars) are not touched and
// stop nobody themselves: they are looped "pictures", util/offscreen.js
// handles starting and stopping them.
//
// `play` does not bubble — hence a listener in the capture phase on the document.

const audible = (media) => !media.muted && media.volume > 0;

function onPlay(event) {
  const started = event.target;
  if (!(started instanceof HTMLMediaElement) || !audible(started)) return;
  for (const other of document.querySelectorAll('video, audio')) {
    if (other !== started && !other.paused && audible(other)) other.pause();
  }
}

/** Turn the rule on — once at the page start (main.js). */
export function mountSoloPlay() {
  document.addEventListener('play', onPlay, true);
  // Sound turned on for an already playing video — also a "start with sound".
  document.addEventListener('volumechange', (event) => {
    const media = event.target;
    if (media instanceof HTMLMediaElement && !media.paused) onPlay(event);
  }, true);
}
