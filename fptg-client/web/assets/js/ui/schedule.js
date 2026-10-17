import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { call } from '../core/net.js';
import { store } from '../core/store.js';
import { icon } from '../util/icons.js';
import { openMenu } from '../util/menu.js';
import { openBox, note, section } from './tgbox.js';
import { notice } from './notices.js';

// Отложенная отправка — как у Telegram Desktop: «Schedule message» (дата
// и время), «Send when online» (в личке) и список запланированных
// («Scheduled messages»: отправить сейчас, перенести, удалить).
//
// Кнопка — слева от кнопки записи голосовых; точка на ней — в чате есть
// запланированные (chat.scheduled, updateChatHasScheduledMessages).
// Отправка — тем же message.send* с полем schedule (webapi.pas: дата
// unix или -1 — «когда будет в сети»); в историю такое сообщение не
// попадает, пока не отправится (tdmessages.ApplyMessage).

const WHEN_ONLINE = -1;
// Ближайшее, на что можно запланировать: Telegram не берёт «прямо сейчас».
const MIN_AHEAD_SEC = 60;

let button = null;
let hooks = null;   // { canSend(): boolean, hasText(): boolean, send(schedule) }

const chatId = () => store.activeChatId;
const admin = (steps) => call('admin', { steps });
const one = async (method, params) => (await admin([{ key: 'r', method, params }])).r;

function pad(n) {
  return String(n).padStart(2, '0');
}

/** Значение для <input type="datetime-local"> из даты. */
function localValue(d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** «Today at 14:05», «Tomorrow at 9:00», «Oct 21 at 18:30». */
export function scheduleLabel(state) {
  if (!state || state['@type'] === 'messageSchedulingStateSendWhenOnline') return 'When online';
  const d = new Date((state.send_date ?? 0) * 1000);
  const time = d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  const today = new Date();
  const tomorrow = new Date(today);
  tomorrow.setDate(today.getDate() + 1);
  if (d.toDateString() === today.toDateString()) return `Today at ${time}`;
  if (d.toDateString() === tomorrow.toDateString()) return `Tomorrow at ${time}`;
  const opts = { month: 'short', day: 'numeric' };
  if (d.getFullYear() !== today.getFullYear()) opts.year = 'numeric';
  return `${d.toLocaleDateString('en-US', opts)} at ${time}`;
}

/**
 * Окно выбора даты и времени, как «Schedule message» у Desktop.
 * onPick(unix) — по кнопке; title и кнопка — свои у переноса.
 */
function pickDate({ title = 'Schedule message', action = 'Schedule', initial = null, onPick }) {
  const start = initial ? new Date(initial * 1000) : new Date(Date.now() + 60 * 60 * 1000);
  start.setSeconds(0, 0);
  const input = el('input', {
    class: 'tgbox__input', type: 'datetime-local',
    value: localValue(start), min: localValue(new Date(Date.now() + MIN_AHEAD_SEC * 1000)),
  });
  const presets = [
    ['In 1 hour', 60 * 60], ['In 3 hours', 3 * 60 * 60], ['Tomorrow', 24 * 60 * 60],
  ];
  openBox().push({
    title,
    render: () => [
      el('label', { class: 'tgbox__field' }, input),
      el('div', { class: 'tgbox__chips' }, ...presets.map(([label, sec]) => el('button', {
        class: 'tgbox__chip', type: 'button',
        onclick: () => { input.value = localValue(new Date(Date.now() + sec * 1000)); },
      }, label))),
      note('The message will be sent automatically at this time, even if this app is closed.'),
    ],
    buttons: [
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: action, primary: true,
        async run(box) {
          const at = Math.floor(new Date(input.value).getTime() / 1000);
          if (!Number.isFinite(at)) throw new Error('Choose a date and time.');
          if (at < Date.now() / 1000 + MIN_AHEAD_SEC) throw new Error('Choose a time in the future.');
          await onPick(at);
          box.close();
        },
      },
    ],
  });
}

// ------------------------------------------------- список запланированных

/** Подпись содержимого сообщения TDLib одной строкой. */
function contentText(c) {
  if (!c) return '';
  const text = c.text?.text ?? c.caption?.text ?? '';
  const kind = {
    messagePhoto: 'Photo', messageVideo: 'Video', messageDocument: 'File', messageAudio: 'Audio',
    messageVoiceNote: 'Voice message', messageVideoNote: 'Video message', messageSticker: 'Sticker',
    messageAnimation: 'GIF', messagePoll: 'Poll', messageLocation: 'Location', messageContact: 'Contact',
    messageRichMessage: 'Rich message',
  }[c['@type']];
  if (c['@type'] === 'messageSticker') return `${c.sticker?.emoji ?? ''} Sticker`.trim();
  if (kind && text) return `${kind}, ${text}`;
  return text || kind || 'Message';
}

function scheduledPage() {
  return {
    title: 'Scheduled messages',
    async render(body, box) {
      const id = chatId();
      const answer = await one('getChatScheduledMessages', { chat_id: id });
      const list = (answer.messages ?? []).slice().sort((a, b) =>
        (a.scheduling_state?.send_date ?? 0) - (b.scheduling_state?.send_date ?? 0));
      if (!list.length) return [note('No scheduled messages in this chat.')];
      const act = (label, fn, danger = false) => el('button', {
        class: `btn tgbox__act${danger ? ' is-danger' : ''}`, type: 'button',
        onclick: async () => {
          try {
            await fn();
          } catch (error) {
            hooks.report?.(error);
          }
          box.refresh();
        },
      }, label);
      const nodes = [];
      let day = '';
      for (const m of list) {
        const label = scheduleLabel(m.scheduling_state);
        const head = label.replace(/ at .*$/, '');
        if (head !== day) {
          day = head;
          nodes.push(section(head));
        }
        // Текст — целиком сверху (до трёх строк), под ним время и кнопки.
        nodes.push(el('div', { class: 'tgbox__scheduled' },
          el('p', { class: 'tgbox__scheduled-text', title: contentText(m.content) }, contentText(m.content)),
          el('div', { class: 'tgbox__scheduled-foot' },
            el('span', { class: 'tgbox__row-sub' }, icon('send-later', 'icon--sm'), label.replace(/^.* at /, '')),
            el('span', { class: 'tgbox__actions' },
            act('Send now', () => one('editMessageSchedulingState', { chat_id: id, message_id: m.id, scheduling_state: null })),
            act('Reschedule', () => new Promise((resolve) => {
              pickDate({
                title: 'Reschedule', action: 'Reschedule', initial: m.scheduling_state?.send_date,
                onPick: async (at) => {
                  await one('editMessageSchedulingState', {
                    chat_id: id, message_id: m.id,
                    scheduling_state: { '@type': 'messageSchedulingStateSendAtDate', send_date: at, repeat_period: 0 },
                  });
                  resolve();
                  box.refresh();
                },
              });
            })),
            act('Delete', () => one('deleteMessages', { chat_id: id, message_ids: [m.id], revoke: true }), true)))));
      }
      return nodes;
    },
    buttons: [{ label: 'Close', run: (box) => box.close() }],
  };
}

export function openScheduled() {
  if (!chatId()) return;
  openBox().push(scheduledPage());
}

// --------------------------------------------------------------- кнопка

function sendScheduled(at) {
  hooks.send(at);
}

function openScheduleMenu() {
  const chat = openChat();
  const hasText = hooks.hasText();
  const items = [
    {
      // В «Избранном» Desktop называет это напоминанием.
      label: chat?.kind === 'self' ? 'Set a reminder' : 'Schedule message', disabled: !hasText,
      onSelect: () => pickDate({ onPick: (at) => sendScheduled(at) }),
    },
  ];
  if (chat?.kind === 'user') {
    items.push({ label: 'Send when online', disabled: !hasText, onSelect: () => sendScheduled(WHEN_ONLINE) });
  }
  items.push('-', { label: 'Scheduled messages', onSelect: openScheduled });
  openMenu(button, items);
}

/** Строка открытого чата — свежая, из списка (activeChat может отстать). */
const openChat = () => store.chats.find((c) => c.id === store.activeChatId) ?? store.activeChat;

function refresh() {
  if (!button) return;
  const chat = openChat();
  const can = !!chat && hooks.canSend();
  button.hidden = !chat;
  button.disabled = !can && !chat?.scheduled;
  button.classList.toggle('has-scheduled', !!chat?.scheduled);
  button.title = chat?.scheduled ? 'Scheduled messages and send later' : 'Send later';
}

/**
 * row — .composer__row; встаёт слева от кнопки записи. options:
 * { canSend(), hasText(), send(schedule), report(error) }.
 */
export function mountSchedule(row, options) {
  hooks = options;
  button = el('button', {
    class: 'btn btn--icon composer__schedule', type: 'button', title: 'Send later',
    onclick: openScheduleMenu,
  }, icon('send-later'), el('span', { class: 'composer__schedule-dot', 'aria-hidden': 'true' }));
  const record = row.querySelector('.composer__record-box');
  if (record) record.before(button);
  else row.append(button);
  // После обработчиков поля ввода: canSend оно пересчитывает на те же события.
  const later = () => setTimeout(refresh, 0);
  on('store:active', later);
  on('store:chats', later);
  // Отправили на потом — подтверждение, как плашка у Desktop.
  on('ui:scheduled', (at) => {
    notice(at === WHEN_ONLINE
      ? 'The message will be sent when they come online.'
      : `Message scheduled for ${scheduleLabel({ send_date: at })}.`);
  });
  refresh();
}
