// Tiny DOM helpers. Not a framework and not the beginning of one: four
// functions that remove the repetitive parts of building elements by
// hand, and nothing that owns state or a render loop.

/**
 * el('div', {class: 'x', onclick: fn}, child, 'text')
 *
 * Everything that ends up as visible text goes through textContent,
 * never innerHTML. That is not style: chat titles, previews and message
 * bodies are written by strangers, and a channel is free to call itself
 * <img onerror=...>. There is exactly one place in this codebase that
 * parses markup (icons.js, on a file we ship ourselves), and it stays
 * that way.
 */
export function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') node.className = value;
    else if (key === 'dataset') Object.assign(node.dataset, value);
    else if (key.startsWith('on') && typeof value === 'function') {
      node.addEventListener(key.slice(2).toLowerCase(), value);
    } else if (key in node) node[key] = value;
    else node.setAttribute(key, value);
  }
  append(node, children);
  return node;
}

export function append(node, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

export function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
  return node;
}

export const qs = (selector, scope = document) => scope.querySelector(selector);
export const qsa = (selector, scope = document) => [...scope.querySelectorAll(selector)];

// NOTE: there is deliberately no setStyle/cssVar helper here. Nothing in
// this app writes the style attribute from JavaScript - appearance is
// changed by adding or removing a class, and anything that needs a value
// the stylesheet cannot know (the per-chat accent) gets it as a class
// out of a fixed palette. See scss/base/_accent.scss.
