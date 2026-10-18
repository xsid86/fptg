import { el } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { openBox, section, note, linkRow, radioGroup, textField } from './tgbox.js';
import { one, saving } from './setkit.js';

// "Connection type" (Advanced in Telegram Desktop): the proxies the fptg
// server uses to reach Telegram. The list, enabling one or "no proxy",
// checking the response, adding and removing — getProxies,
// enableProxy, disableProxy, pingProxy, addProxy, removeProxy (TDLib).

const TYPES = [
  { value: 'proxyTypeSocks5', label: 'SOCKS5' },
  { value: 'proxyTypeHttp', label: 'HTTP' },
  { value: 'proxyTypeMtproto', label: 'MTProto' },
];
const typeLabel = (t) => TYPES.find((x) => x.value === t?.['@type'])?.label ?? 'Proxy';

function proxyLine(p, box, pings) {
  const status = p.is_enabled ? 'connected' : (pings.get(p.id) ?? '');
  return el('div', { class: 'tgbox__peer' },
    el('span', { class: 'avatar tgbox__avatar tgbox__device' }, icon('globe')),
    el('span', { class: 'tgbox__toggle-text' },
      el('span', { class: 'tgbox__row-label' }, `${p.proxy.server}:${p.proxy.port}`),
      el('span', { class: `tgbox__row-sub${p.is_enabled ? ' is-online' : ''}` },
        [typeLabel(p.proxy.type), status, p.comment].filter(Boolean).join(' · '))),
    el('span', { class: 'tgbox__actions' },
      el('button', {
        class: 'btn tgbox__act', type: 'button',
        onclick: async () => {
          pings.set(p.id, 'checking…');
          box.refresh();
          try {
            const r = await one('pingProxy', { proxy: p.proxy });
            pings.set(p.id, `available, ${Math.round((r.seconds ?? 0) * 1000)} ms`);
          } catch (error) {
            pings.set(p.id, `unavailable: ${error?.message ?? error}`);
          }
          box.refresh();
        },
      }, 'Check'),
      el('button', {
        class: 'btn tgbox__act is-danger', type: 'button',
        onclick: async () => {
          await one('removeProxy', { proxy_id: p.id });
          box.refresh();
        },
      }, 'Delete')));
}

function addPage() {
  let type = TYPES[0].value;
  const server = textField('Hostname');
  const port = textField('Port');
  const user = textField('Username (optional)');
  const pass = textField('Password (optional)');
  const secret = textField('Secret');
  pass.input.type = 'password';
  port.input.inputMode = 'numeric';
  return {
    title: 'Add proxy',
    render: (body, box) => [
      radioGroup('proxy-type', TYPES, type, (v) => { type = v; box.refresh(); }).node,
      section('Connection'),
      server.node, port.node,
      ...(type === 'proxyTypeMtproto' ? [section('Credentials'), secret.node] : [section('Credentials'), user.node, pass.node]),
    ],
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const host = server.input.value.trim();
          const n = Number(port.input.value);
          if (!host || !Number.isInteger(n) || n <= 0 || n > 65535) throw new Error('Enter a hostname and a port.');
          const t = { '@type': type };
          if (type === 'proxyTypeMtproto') t.secret = secret.input.value.trim();
          else {
            t.username = user.input.value;
            t.password = pass.input.value;
            if (type === 'proxyTypeHttp') t.http_only = false;
          }
          await one('addProxy', { proxy: { '@type': 'proxy', server: host, port: n, type: t }, enable: true, comment: '' });
          box.pop();
        },
      },
    ],
  };
}

export function openProxies() {
  const pings = new Map();
  openBox().push({
    title: 'Proxy settings',
    async render(body, box) {
      const answer = await one('getProxies');
      const list = answer.proxies ?? [];
      const active = list.find((p) => p.is_enabled);
      return [
        note('The fptg server connects to Telegram through the proxy chosen here. '
          + 'If the proxy stops working, the app goes offline until you switch back.'),
        radioGroup('proxy-use', [
          { value: '0', label: 'Don’t use proxy' },
          ...list.map((p) => ({ value: String(p.id), label: `Use ${p.proxy.server}:${p.proxy.port}` })),
        ], String(active?.id ?? 0), (v) => saving(async () => {
          if (v === '0') await one('disableProxy');
          else await one('enableProxy', { proxy_id: Number(v) });
          box.refresh();
        }, { redraw: false })).node,
        section('Proxies'),
        linkRow({ iconName: 'plus', label: 'Add proxy', onClick: () => box.push(addPage()) }),
        list.length ? el('div', { class: 'tgbox__list' }, ...list.map((p) => proxyLine(p, box, pings))) : note('No proxies yet.'),
      ];
    },
    buttons: [{ label: 'Close', run: (box) => box.close() }],
  });
}
