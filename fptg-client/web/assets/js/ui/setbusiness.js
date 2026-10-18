import { el } from '../core/dom.js';
import { copyText } from '../util/clipboard.js';
import { openBox, section, note, linkRow, toggleRow, textField, radioGroup } from './tgbox.js';
import {
  load, one, td, kept, failed, refresh, group, navRow, intro, isPremium, myId, report,
} from './setkit.js';
import { peerCards, peerLine, chatPicker } from './setpeers.js';

// "Telegram Business" — as in Telegram Desktop: the location, opening
// hours, quick replies, the greeting, the "away" auto-reply, chatbots, chat
// links, the intro page (Intro). Without Premium everything is inactive.
//
// The greeting and the auto-reply are quick replies with the reserved
// names hello and away (that is how Telegram keeps them): the text is edited
// with the same editor as quick replies. TDLib gives no method for
// shortcuts — only load* and updates; the server keeps them (td.kept, "type:id").

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const GREETING = 'hello';
const AWAY = 'away';
const RESERVED = new Set([GREETING, AWAY]);

const DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const minutes = (hhmm) => {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
};
const hhmm = (min) => `${String(Math.floor(min / 60) % 24).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}`;

const formatted = (text) => ({ '@type': 'formattedText', text, entities: [] });
const textContent = (text) => ({
  '@type': 'inputMessageText', text: formatted(text), link_preview_options: null, clear_draft: false,
});

/** The content's caption as one line. */
function contentText(c) {
  if (!c) return '';
  const text = c.text?.text ?? c.caption?.text ?? '';
  const kind = {
    messagePhoto: 'Photo', messageVideo: 'Video', messageDocument: 'File', messageAudio: 'Audio',
    messageVoiceNote: 'Voice message', messageVideoNote: 'Video message', messageSticker: 'Sticker',
    messageAnimation: 'GIF',
  }[c['@type']];
  if (kind && text) return `${kind}, ${text}`;
  return text || kind || 'Message';
}

// ---------------------------------------------------------- shortcuts

/** All shortcuts: Map name -> { id, name, first_message, message_count }. */
async function loadShortcuts() {
  await one('loadQuickReplyShortcuts');
  // TDLib updates come before the answer; the margin is for the server to process them.
  await wait(150);
  const k = await kept(['updateQuickReplyShortcuts', 'updateQuickReplyShortcut:']);
  const order = k.updateQuickReplyShortcuts?.shortcut_ids ?? [];
  const all = (k['updateQuickReplyShortcut:'] ?? []).map((u) => u.shortcut).filter(Boolean)
    .filter((s) => !order.length || order.includes(s.id));
  all.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
  return new Map(all.map((s) => [s.name, s]));
}

async function loadMessages(shortcutId) {
  await one('loadQuickReplyShortcutMessages', { shortcut_id: shortcutId });
  await wait(150);
  const key = `updateQuickReplyShortcutMessages:${shortcutId}`;
  const k = await kept([key]);
  return k[key]?.messages ?? [];
}

function messagePage(shortcut, msg) {
  const field = textField('Message', msg ? contentText(msg.content) : '', { multiline: true, max: 4096 });
  return {
    title: msg ? 'Edit message' : 'New message',
    render: () => [field.node],
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const text = field.input.value.trim();
          if (!text) throw new Error('Enter the message text.');
          if (msg) {
            await one('editQuickReplyMessage', { shortcut_id: shortcut.id, message_id: msg.id, input_message_content: textContent(text) });
          } else {
            await one('addQuickReplyShortcutMessage', { shortcut_name: shortcut.name, reply_to_message_id: 0, input_message_content: textContent(text) });
          }
          box.pop();
        },
      },
    ],
  };
}

/**
 * A shortcut's messages: a list with "Edit" and "Delete", "Add a message".
 * name — the shortcut's name (a new one appears with its first message).
 */
function shortcutPage(name, { title, about, quick = false } = {}) {
  return {
    title: title ?? `/${name}`,
    async render(body, box) {
      const shortcut = (await loadShortcuts()).get(name) ?? { id: 0, name };
      const msgs = shortcut.id ? await loadMessages(shortcut.id) : [];
      const act = (label, fn, danger = false) => el('button', {
        class: `btn tgbox__act${danger ? ' is-danger' : ''}`, type: 'button',
        onclick: async () => {
          try {
            await fn();
          } catch (error) {
            report(error);
          }
          box.refresh();
        },
      }, label);
      return [
        about ? note(about) : null,
        linkRow({ iconName: 'plus', label: 'Add a message', onClick: () => box.push(messagePage(shortcut, null)) }),
        msgs.length ? el('div', { class: 'tgbox__list' }, ...msgs.map((m) => el('div', { class: 'tgbox__scheduled' },
          el('p', { class: 'tgbox__scheduled-text' }, contentText(m.content)),
          el('div', { class: 'tgbox__scheduled-foot' },
            el('span', {}),
            el('span', { class: 'tgbox__actions' },
              m.content?.['@type'] === 'messageText' ? act('Edit', () => box.push(messagePage(shortcut, m))) : null,
              act('Delete', () => one('deleteQuickReplyShortcutMessages', { shortcut_id: shortcut.id, message_ids: [m.id] }), true))))))
          : note('No messages yet.'),
        quick && shortcut.id ? linkRow({ label: 'Rename shortcut', onClick: () => box.push(renamePage(shortcut)) }) : null,
        quick && shortcut.id ? linkRow({
          label: 'Delete quick reply', danger: true,
          onClick: async () => {
            await one('deleteQuickReplyShortcut', { shortcut_id: shortcut.id });
            box.pop();
          },
        }) : null,
      ];
    },
    buttons: [{ label: 'Done', primary: true, run: (box) => (box.depth > 1 ? box.pop() : box.close()) }],
  };
}

function renamePage(shortcut) {
  const field = textField('Shortcut', shortcut.name, { prefix: '/', max: 32 });
  return {
    title: 'Rename shortcut',
    render: () => [field.node],
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const name = field.input.value.trim().replace(/^\//, '');
          await one('checkQuickReplyShortcutName', { name });
          await one('setQuickReplyShortcutName', { shortcut_id: shortcut.id, name });
          box.pop();
          box.pop();
        },
      },
    ],
  };
}

function newQuickReplyPage() {
  const name = textField('Shortcut', '', { prefix: '/', max: 32 });
  const text = textField('Message', '', { multiline: true, max: 4096 });
  return {
    title: 'New quick reply',
    render: () => [
      note('Type “/” and the shortcut in a private chat to send these messages.'),
      name.node, text.node,
    ],
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Create', primary: true,
        async run(box) {
          const n = name.input.value.trim().replace(/^\//, '');
          const t = text.input.value.trim();
          if (!n || !t) throw new Error('Enter a shortcut and a message.');
          if (RESERVED.has(n)) throw new Error('This shortcut is reserved.');
          await one('checkQuickReplyShortcutName', { name: n });
          await one('addQuickReplyShortcutMessage', { shortcut_name: n, reply_to_message_id: 0, input_message_content: textContent(t) });
          box.pop();
        },
      },
    ],
  };
}

function openQuickReplies() {
  openBox().push({
    title: 'Quick replies',
    async render(body, box) {
      const all = [...(await loadShortcuts()).values()].filter((s) => !RESERVED.has(s.name));
      return [
        note('Set up shortcuts with rapid responses to your customers’ most frequent questions. '
          + 'Type “/” and the shortcut in a private chat to send them.'),
        linkRow({ iconName: 'plus', label: 'Add quick reply', onClick: () => box.push(newQuickReplyPage()) }),
        all.length ? el('div', { class: 'tgbox__list' }, ...all.map((s) => el('button', {
          class: 'tgbox__peer', type: 'button',
          onclick: () => box.push(shortcutPage(s.name, { quick: true })),
        },
        el('span', { class: 'tgbox__toggle-text' },
          el('span', { class: 'tgbox__row-label' }, `/${s.name}`),
          el('span', { class: 'tgbox__row-sub' }, contentText(s.first_message?.content))),
        el('span', { class: 'tgbox__row-value' }, s.message_count > 1 ? `${s.message_count} messages` : ''))))
          : note('No quick replies yet.'),
      ];
    },
    buttons: [{ label: 'Close', run: (box) => box.close() }],
  });
}

// --------------------------------------------------------- recipients

const RECIPIENT_TYPES = [
  ['select_existing_chats', 'Existing chats'],
  ['select_new_chats', 'New chats'],
  ['select_contacts', 'Contacts'],
  ['select_non_contacts', 'Non-contacts'],
];

function fromRecipients(b) {
  const r = { except: true, chats: [] };
  for (const [k] of RECIPIENT_TYPES) r[k] = false;
  if (!b) return r;
  r.except = !!b.exclude_selected;
  r.chats = (b.chat_ids ?? []).map(String);
  for (const [k] of RECIPIENT_TYPES) r[k] = !!b[k];
  return r;
}

function toRecipients(r) {
  const b = {
    '@type': 'businessRecipients', chat_ids: r.chats.map(Number), excluded_chat_ids: [],
    exclude_selected: r.except,
  };
  for (const [k] of RECIPIENT_TYPES) b[k] = !!r[k];
  return b;
}

function recipientsSummary(r) {
  const parts = [...RECIPIENT_TYPES.filter(([k]) => r[k]).map(([, l]) => l)];
  if (r.chats.length) parts.push(`${r.chats.length} chats`);
  return parts.join(', ') || 'None';
}

/** The "Recipients" section: everyone except…, or only the chosen ones. */
function recipientsNodes(r, box, word) {
  return [
    section('Recipients'),
    radioGroup(`recipients-${word}`, [
      { value: 'except', label: 'All 1-to-1 chats except…' },
      { value: 'only', label: 'Only selected chats' },
    ], r.except ? 'except' : 'only', (v) => { r.except = v === 'except'; box.refresh(); }).node,
    linkRow({
      iconName: r.except ? 'close' : 'plus', label: r.except ? 'Exclude chats' : 'Select chats',
      value: recipientsSummary(r), onClick: () => box.push(recipientsPage(r)),
    }),
    note(r.except
      ? `The ${word} will be sent to all private chats except the ones chosen here.`
      : `The ${word} will be sent only to the chats chosen here.`),
  ];
}

function recipientsPage(r) {
  return {
    title: r.except ? 'Exclude chats' : 'Select chats',
    async render(body, box) {
      const cards = await peerCards({ users: r.chats });
      return [
        section('Chat types'),
        ...RECIPIENT_TYPES.map(([k, label]) => toggleRow(label, r[k], { onChange: (v) => { r[k] = v; } }).node),
        section('Chats'),
        linkRow({ iconName: 'plus', label: 'Add chats', onClick: () => box.push(pickChatsPage(r)) }),
        r.chats.length ? el('div', { class: 'tgbox__list' }, ...r.chats.map((id) => peerLine(cards.get(`u${id}`), {
          right: el('button', {
            class: 'btn tgbox__act', type: 'button',
            onclick: () => { r.chats = r.chats.filter((x) => x !== id); box.refresh(); },
          }, 'Remove'),
        }))) : note('No chats chosen one by one.'),
      ];
    },
    buttons: [{ label: 'Done', primary: true, run: (box) => box.pop() }],
  };
}

function pickChatsPage(r) {
  let picker = null;
  return {
    title: 'Add chats',
    render() {
      picker = chatPicker({ kinds: ['user', 'bot'], exclude: new Set(r.chats) });
      return picker.nodes;
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      { label: 'Add', primary: true, run: (box) => { r.chats.push(...picker.chosen()); box.pop(); } },
    ],
  };
}

// ---------------------------------------------- greeting, auto-reply

async function messageRow(name, box, label) {
  const shortcut = (await loadShortcuts()).get(name);
  return linkRow({
    label,
    value: shortcut ? contentText(shortcut.first_message?.content).slice(0, 40) : 'Create',
    onClick: () => box.push(shortcutPage(name, { title: label })),
  });
}

async function shortcutId(name) {
  return (await loadShortcuts()).get(name)?.id ?? 0;
}

function openGreeting(info) {
  const cur = info?.greeting_message_settings;
  let on = !!cur;
  let days = String(cur?.inactivity_days ?? 7);
  const r = fromRecipients(cur?.recipients);
  openBox().push({
    title: 'Greeting message',
    async render(body, box) {
      const nodes = [
        note('Greet customers when they message you the first time or after a period of no activity.'),
        toggleRow('Send greeting message', on, { onChange: (v) => { on = v; box.refresh(); } }).node,
      ];
      if (!on) return nodes;
      return [...nodes,
        await messageRow(GREETING, box, 'Greeting message'),
        ...recipientsNodes(r, box, 'greeting message'),
        section('Send if no activity for'),
        radioGroup('greeting-days', [7, 14, 21, 28].map((d) => ({ value: String(d), label: `${d} days` })), days,
          (v) => { days = v; }).node,
        note('Choose how many days should pass after your last interaction with a recipient to send them the greeting.'),
      ];
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          let settings = null;
          if (on) {
            const id = await shortcutId(GREETING);
            if (!id) throw new Error('Create the greeting message first.');
            settings = {
              '@type': 'businessGreetingMessageSettings', shortcut_id: id,
              recipients: toRecipients(r), inactivity_days: Number(days),
            };
          }
          await one('setBusinessGreetingMessageSettings', { greeting_message_settings: settings });
          box.close();
          refresh();
        },
      },
    ],
  });
}

function localValue(unix) {
  const d = new Date(unix * 1000);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

function openAway(info) {
  const cur = info?.away_message_settings;
  let on = !!cur;
  const sch = cur?.schedule?.['@type'];
  let schedule = sch === 'businessAwayMessageScheduleOutsideOfOpeningHours' ? 'hours'
    : sch === 'businessAwayMessageScheduleCustom' ? 'custom' : 'always';
  let offline = !!cur?.offline_only;
  const now = Math.floor(Date.now() / 1000);
  const start = el('input', { class: 'tgbox__input', type: 'datetime-local', value: localValue(cur?.schedule?.start_date ?? now) });
  const end = el('input', { class: 'tgbox__input', type: 'datetime-local', value: localValue(cur?.schedule?.end_date ?? now + 7 * 86400) });
  const r = fromRecipients(cur?.recipients);
  openBox().push({
    title: 'Away message',
    async render(body, box) {
      const nodes = [
        note('Automatically reply with a message when you are away.'),
        toggleRow('Send away message', on, { onChange: (v) => { on = v; box.refresh(); } }).node,
      ];
      if (!on) return nodes;
      return [...nodes,
        await messageRow(AWAY, box, 'Away message'),
        section('Schedule'),
        radioGroup('away-schedule', [
          { value: 'always', label: 'Always send' },
          { value: 'hours', label: 'Outside of business hours' },
          { value: 'custom', label: 'Custom schedule' },
        ], schedule, (v) => { schedule = v; box.refresh(); }).node,
        schedule === 'custom' ? el('div', { class: 'tgbox__times' },
          el('label', { class: 'tgbox__field' }, start), el('span', {}, '–'), el('label', { class: 'tgbox__field' }, end)) : null,
        toggleRow('Only if offline', offline, {
          sub: 'Don’t send away messages while you are online.',
          onChange: (v) => { offline = v; },
        }).node,
        ...recipientsNodes(r, box, 'away message'),
      ];
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          let settings = null;
          if (on) {
            const id = await shortcutId(AWAY);
            if (!id) throw new Error('Create the away message first.');
            let s = { '@type': 'businessAwayMessageScheduleAlways' };
            if (schedule === 'hours') s = { '@type': 'businessAwayMessageScheduleOutsideOfOpeningHours' };
            if (schedule === 'custom') {
              const a = Math.floor(new Date(start.value).getTime() / 1000);
              const b = Math.floor(new Date(end.value).getTime() / 1000);
              if (!(a < b)) throw new Error('The end must be after the start.');
              s = { '@type': 'businessAwayMessageScheduleCustom', start_date: a, end_date: b };
            }
            settings = {
              '@type': 'businessAwayMessageSettings', shortcut_id: id,
              recipients: toRecipients(r), schedule: s, offline_only: offline,
            };
          }
          await one('setBusinessAwayMessageSettings', { away_message_settings: settings });
          box.close();
          refresh();
        },
      },
    ],
  });
}

// ----------------------------------------------------------- chatbots

const BOT_RIGHTS = [
  ['can_reply', 'Reply to messages'],
  ['can_read_messages', 'Mark messages as read'],
  ['can_delete_sent_messages', 'Delete sent messages'],
  ['can_delete_all_messages', 'Delete received messages'],
  ['can_edit_name', 'Edit name'],
  ['can_edit_bio', 'Edit bio'],
  ['can_edit_profile_photo', 'Edit profile picture'],
  ['can_edit_username', 'Edit username'],
  ['can_view_gifts_and_stars', 'View gifts and Stars'],
  ['can_sell_gifts', 'Sell gifts'],
  ['can_change_gift_settings', 'Change gift settings'],
  ['can_transfer_and_upgrade_gifts', 'Transfer and upgrade gifts'],
  ['can_transfer_stars', 'Transfer Stars'],
  ['can_manage_stories', 'Manage stories'],
];

async function openChatbots() {
  let current = null;
  try {
    current = (await one('getBusinessConnectedBot')).bot;
  } catch {
    current = null;
  }
  let username = '';
  if (current) {
    try {
      const c = await load('users.cards', { ids: [String(current.bot_user_id)] });
      username = c?.items?.[0]?.username ?? '';
    } catch {
      username = '';
    }
  }
  const field = textField('Bot username', username, { prefix: '@', max: 64 });
  const rights = { ...(current?.rights ?? { can_reply: true }) };
  const r = fromRecipients(current?.recipients);
  openBox().push({
    title: 'Chatbots',
    render: (body, box) => [
      note('Add a bot to your account to help you automatically process and respond to the messages you receive.'),
      field.node,
      note('Enter the username or link of any eligible bot.'),
      ...recipientsNodes(r, box, 'bot'),
      section('Bot permissions'),
      ...BOT_RIGHTS.map(([k, label]) => toggleRow(label, !!rights[k], { onChange: (v) => { rights[k] = v; } }).node),
    ],
    buttons: [
      ...(current ? [{
        label: 'Remove bot', danger: true,
        async run(box) {
          await one('deleteBusinessConnectedBot', { bot_user_id: current.bot_user_id });
          box.close();
          refresh();
        },
      }] : []),
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const name = field.input.value.trim().replace(/^@/, '').replace(/^https?:\/\/t\.me\//, '');
          if (!name) throw new Error('Enter the bot’s username.');
          const chat = await one('searchPublicChat', { username: name });
          const userId = chat?.type?.['@type'] === 'chatTypePrivate' ? chat.type.user_id : 0;
          if (!userId) throw new Error('This is not a bot.');
          const botRights = { '@type': 'businessBotRights' };
          for (const [k] of BOT_RIGHTS) botRights[k] = !!rights[k];
          await one('setBusinessConnectedBot', {
            bot: { '@type': 'businessConnectedBot', bot_user_id: userId, recipients: toRecipients(r), rights: botRights },
          });
          box.close();
          refresh();
        },
      },
    ],
  });
}

// ------------------------------------------------------- chat links

function linkPage(link) {
  const title = textField('Link name (optional)', link?.title ?? '', { max: 32 });
  const text = textField('Pre-filled message', link?.text?.text ?? '', { multiline: true, max: 4096 });
  return {
    title: link ? 'Edit link' : 'New link',
    render: () => [
      note('People who open the link get a chat with you with this message already typed.'),
      title.node, text.node,
    ],
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const info = { '@type': 'inputBusinessChatLink', text: formatted(text.input.value.trim()), title: title.input.value.trim() };
          if (link) await one('editBusinessChatLink', { link: link.link, link_info: info });
          else await one('createBusinessChatLink', { link_info: info });
          box.pop();
        },
      },
    ],
  };
}

function openChatLinks() {
  openBox().push({
    title: 'Links to chat',
    async render(body, box) {
      const links = (await one('getBusinessChatLinks')).links ?? [];
      const act = (label, fn, danger = false) => el('button', {
        class: `btn tgbox__act${danger ? ' is-danger' : ''}`, type: 'button',
        onclick: async () => {
          try {
            await fn();
          } catch (error) {
            report(error);
          }
        },
      }, label);
      return [
        note('Give your customers short links that start a chat with you, with a message already typed.'),
        linkRow({ iconName: 'plus', label: 'Create a link to chat', onClick: () => box.push(linkPage(null)) }),
        links.length ? el('div', { class: 'tgbox__list' }, ...links.map((l) => el('div', { class: 'tgbox__scheduled' },
          el('p', { class: 'tgbox__scheduled-text' }, l.title || l.link.replace(/^https?:\/\//, '')),
          el('span', { class: 'tgbox__row-sub' }, l.text?.text || 'No message'),
          el('div', { class: 'tgbox__scheduled-foot' },
            el('span', { class: 'tgbox__row-sub' }, `${l.view_count} clicks`),
            el('span', { class: 'tgbox__actions' },
              act('Copy', () => copyText(l.link)),
              act('Edit', () => box.push(linkPage(l))),
              act('Delete', async () => { await one('deleteBusinessChatLink', { link: l.link }); box.refresh(); }, true))))))
          : note('No links yet.'),
      ];
    },
    buttons: [{ label: 'Close', run: (box) => box.close() }],
  });
}

// ------------------------------------------------- location, hours, Intro

function openLocation(info) {
  const address = textField('Enter address', info?.location?.address ?? '', { multiline: true, max: 96 });
  openBox().push({
    title: 'Location',
    render: () => [note('Display the location of your business on your account.'), address.node],
    buttons: [
      ...(info?.location ? [{
        label: 'Remove', danger: true,
        async run(box) {
          await one('setBusinessLocation', { location: null });
          box.close();
          refresh();
        },
      }] : []),
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const text = address.input.value.trim();
          await one('setBusinessLocation', {
            location: text ? { '@type': 'businessLocation', location: null, address: text } : null,
          });
          box.close();
          refresh();
        },
      },
    ],
  });
}

async function openHours(info) {
  let zones = [];
  try {
    zones = (await one('getTimeZones')).time_zones ?? [];
  } catch {
    zones = [];
  }
  const hours = info?.opening_hours;
  const zone = hours?.time_zone_id || Intl.DateTimeFormat().resolvedOptions().timeZone;
  // Per day — the first interval (as Desktop's default: one shift).
  const days = DAYS.map((name, d) => {
    const iv = (hours?.opening_hours ?? []).find((x) => Math.floor(x.start_minute / 1440) === d);
    return { name, open: !!iv, from: iv ? hhmm(iv.start_minute % 1440) : '09:00', to: iv ? hhmm(iv.end_minute - d * 1440) : '18:00' };
  });
  const zoneSelect = el('select', { class: 'tgbox__input' },
    ...(zones.length ? zones : [{ id: zone, name: zone, utc_time_offset: 0 }]).map((z) => el('option', {
      value: z.id, selected: z.id === zone,
    }, zones.length
      ? `${z.name} (UTC${z.utc_time_offset >= 0 ? '+' : '−'}${hhmm(Math.abs(z.utc_time_offset) / 60)})` : z.name)));
  openBox().push({
    title: 'Opening hours',
    render: (body, box) => [
      note('Turn this on to show your opening hours schedule to your customers.'),
      section('Time zone'),
      el('label', { class: 'tgbox__field' }, zoneSelect),
      section('Business hours'),
      ...days.map((d) => {
        const t = toggleRow(d.name, d.open, { sub: d.open ? `${d.from} – ${d.to}` : 'Closed', onChange: (v) => { d.open = v; box.refresh(); } });
        if (!d.open) return t.node;
        const from = el('input', { class: 'tgbox__input tgbox__time', type: 'time', value: d.from, onchange: (e) => { d.from = e.target.value; } });
        const to = el('input', { class: 'tgbox__input tgbox__time', type: 'time', value: d.to, onchange: (e) => { d.to = e.target.value; } });
        return el('div', { class: 'tgbox__day' }, t.node, el('div', { class: 'tgbox__times' }, from, el('span', {}, '–'), to));
      }),
    ],
    buttons: [
      ...(hours ? [{
        label: 'Remove', danger: true,
        async run(box) {
          await one('setBusinessOpeningHours', { opening_hours: null });
          box.close();
          refresh();
        },
      }] : []),
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const intervals = days.map((d, i) => {
            if (!d.open) return null;
            const start = minutes(d.from);
            let end = minutes(d.to);
            if (end <= start) end += 1440;   // until midnight and past it
            return { '@type': 'businessOpeningHoursInterval', start_minute: i * 1440 + start, end_minute: i * 1440 + end };
          }).filter(Boolean);
          await one('setBusinessOpeningHours', {
            opening_hours: intervals.length
              ? { '@type': 'businessOpeningHours', time_zone_id: zoneSelect.value, opening_hours: intervals }
              : null,
          });
          box.close();
          refresh();
        },
      },
    ],
  });
}

function openIntro(info) {
  const page = info?.start_page;
  const title = textField('Title', page?.title ?? '', { max: 32 });
  const message = textField('Message', page?.message ?? '', { multiline: true, max: 70 });
  openBox().push({
    title: 'Intro',
    render: () => [
      note('Customize the message people see before they start a chat with you.'),
      title.node, message.node,
    ],
    buttons: [
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const t = title.input.value.trim();
          const m = message.input.value.trim();
          await one('setBusinessStartPage', {
            start_page: t || m ? { '@type': 'inputBusinessStartPage', title: t, message: m, sticker: null } : null,
          });
          box.close();
          refresh();
        },
      },
    ],
  });
}

// ----------------------------------------------------------- section

export async function renderBusiness() {
  let info = null;
  let links = [];
  let bot = null;
  let quick = 0;
  if (isPremium()) {
    const a = await td([
      { key: 'full', method: 'getUserFullInfo', params: { user_id: Number(myId()) }, soft: true },
      { key: 'links', method: 'getBusinessChatLinks', soft: true },
      { key: 'bot', method: 'getBusinessConnectedBot', soft: true },
    ]);
    info = failed(a.full) ? null : a.full.business_info;
    links = failed(a.links) ? [] : (a.links.links ?? []);
    bot = failed(a.bot) ? null : a.bot.bot;
    try {
      quick = [...(await loadShortcuts()).keys()].filter((n) => !RESERVED.has(n)).length;
    } catch {
      quick = 0;
    }
  }
  const onOff = (x) => (x ? 'On' : 'Off');
  return [
    intro('Turn your account into a business page with these features. They need Telegram Premium.'),
    group(null,
      navRow({ iconName: 'pin', label: 'Location', premium: true, hint: 'Display the location of your business.',
        value: info?.location?.address ?? '', onClick: () => openLocation(info) }),
      navRow({ iconName: 'clock', label: 'Opening hours', premium: true, hint: 'Show to your customers when you are open.',
        value: onOff(info?.opening_hours), onClick: () => openHours(info).catch(report) }),
      navRow({ iconName: 'reply', label: 'Quick replies', premium: true, hint: 'Set up shortcuts with rapid responses.',
        value: quick ? String(quick) : '', onClick: openQuickReplies }),
      navRow({ iconName: 'smile', label: 'Greeting messages', premium: true, hint: 'Greet customers who message you the first time.',
        value: onOff(info?.greeting_message_settings), onClick: () => openGreeting(info) }),
      navRow({ iconName: 'moon', label: 'Away messages', premium: true, hint: 'Reply automatically when you are away.',
        value: onOff(info?.away_message_settings), onClick: () => openAway(info) }),
      navRow({ iconName: 'bot', label: 'Chatbots', premium: true, hint: 'Add a bot that answers for you.',
        value: bot ? 'On' : 'Off', onClick: () => openChatbots().catch(report) }),
      navRow({ iconName: 'link', label: 'Links to chat', premium: true, hint: 'Short links that open a chat with you.',
        value: links.length ? String(links.length) : '', onClick: openChatLinks }),
      navRow({ iconName: 'chat', label: 'Intro', premium: true, hint: 'Customize the message people see before they start a chat.',
        value: onOff(info?.start_page), onClick: () => openIntro(info) })),
  ];
}
