// A file's address on the server (/media/…) for SAVING, not showing.
//
// The browser ignores the download attribute on a link to a foreign
// origin: the server is a different origin from the window's page
// (https://fptg.example/), and a PDF via such a link opened right in the
// window, with no way back. So the name travels as the save parameter: the
// server sends the file as an attachment (Content-Disposition: attachment,
// localserver.ServeMedia), and that is a download in any browser.
//
// open — also open it with an external app: in the fptg window the shell
// takes such a download (webui.ViewDownloadStart) and opens the finished
// file with the system; in an ordinary browser — just a download.

// Without a name (photos, videos) — '*': the server takes the file's name on
// disk, with the extension.
export function downloadUrl(url, name, open = false) {
  const u = new URL(url, window.location.href);
  u.searchParams.set('save', name || '*');
  if (open) u.searchParams.set('open', '1');
  return u.href;
}
