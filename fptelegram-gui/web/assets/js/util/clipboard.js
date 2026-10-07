// Copying, in the one place that knows how awkward it is here.
//
// navigator.clipboard.writeText answers "NotAllowedError: Write
// permission denied" inside the WebView2 pane even with the document
// focused - measured, not assumed. document.execCommand('copy') over a
// selection still works, so both are tried and the caller is told
// which, if either, succeeded: saying nothing looks exactly like
// success.

/** Copies a string. Answers whether it got there. */
export async function copyText(text) {
  if (!text) return false;
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch { /* fall through to the old way */ }

  // A textarea rather than a hidden div: execCommand copies a
  // SELECTION, and only a form control can be selected without
  // disturbing what the page already had selected in its own text.
  const holder = document.createElement('textarea');
  holder.value = text;
  holder.setAttribute('readonly', '');
  holder.className = 'u-sr-only';
  document.body.append(holder);
  try {
    holder.select();
    return document.execCommand('copy');
  } catch {
    return false;
  } finally {
    holder.remove();
  }
}

/**
 * Copies an element's contents, keeping whatever the page had selected.
 * For a block already on screen - a code block - where the text is the
 * element rather than a string somebody is holding.
 */
export function copyNode(node) {
  const selection = getSelection();
  const saved = selection.rangeCount ? selection.getRangeAt(0) : null;
  try {
    const range = document.createRange();
    range.selectNodeContents(node);
    selection.removeAllRanges();
    selection.addRange(range);
    return document.execCommand('copy');
  } catch {
    return false;
  } finally {
    selection.removeAllRanges();
    if (saved) selection.addRange(saved);
  }
}
