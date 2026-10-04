// Одно воспроизведение со звуком за раз.
//
// Видео в истории, в просмотрщике, голосовые и музыка — у каждого свой
// плеер, и раньше они могли играть одновременно. Правило одно на весь
// документ: как только что-то начинает играть со звуком, всё остальное
// со звуком становится на паузу.
//
// Немые (GIF, видео-стикеры, анимированные аватарки) не трогаются и сами
// никого не останавливают: они зацикленные «картинки», их запуском и
// остановкой ведает util/offscreen.js.
//
// `play` не всплывает — поэтому слушатель в фазе перехвата на документе.

const audible = (media) => !media.muted && media.volume > 0;

function onPlay(event) {
  const started = event.target;
  if (!(started instanceof HTMLMediaElement) || !audible(started)) return;
  for (const other of document.querySelectorAll('video, audio')) {
    if (other !== started && !other.paused && audible(other)) other.pause();
  }
}

/** Включить правило — один раз при старте страницы (main.js). */
export function mountSoloPlay() {
  document.addEventListener('play', onPlay, true);
  // Включили звук у уже играющего видео — тоже «начало со звуком».
  document.addEventListener('volumechange', (event) => {
    const media = event.target;
    if (media instanceof HTMLMediaElement && !media.paused) onPlay(event);
  }, true);
}
