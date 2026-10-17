import { el } from '../core/dom.js';
import { store, setActiveChat } from '../core/store.js';
import { openBox, section, note, toggleRow } from './tgbox.js';
import { one, td, failed, saving, refresh, group, navRow, switchRow } from './setkit.js';
import { peerCards, peerLine } from './setpeers.js';

// «Notifications and sounds» — часть аккаунта, как у Telegram Desktop:
// уведомления для личных чатов, групп и каналов (getScopeNotificationSettings;
// у каждого — показ текста, закреплённые, упоминания и исключения),
// события («контакт в Telegram»), сброс всех настроек уведомлений.
// Всплывающие карточки этого окна (угол, число, шрифт) — ниже, из
// settings.js: это уже настройки сервера, не TDLib.

const SCOPES = [
  { type: 'notificationSettingsScopePrivateChats', label: 'Private chats', title: 'Private chats' },
  { type: 'notificationSettingsScopeGroupChats', label: 'Groups', title: 'Groups' },
  { type: 'notificationSettingsScopeChannelChats', label: 'Channels', title: 'Channels' },
];
// «Выключено» у TDLib — mute_for на годы вперёд; Desktop ставит так же.
const MUTE_FOREVER = 366 * 86400 * 10;

const scope = (type) => ({ '@type': type });
const isOn = (s) => !s.mute_for;

function saveScope(type, s) {
  return one('setScopeNotificationSettings', {
    scope: scope(type),
    notification_settings: { ...s, '@type': 'scopeNotificationSettings' },
  });
}

function scopePage(def, settings, exceptions) {
  const s = { ...settings };
  return {
    title: def.title,
    async render(body, box) {
      const ids = (exceptions?.chat_ids ?? []).map(String);
      const cards = await peerCards({ chats: ids });
      const toggle = (label, value, apply, sub = '') => toggleRow(label, value, {
        sub,
        onChange: (v) => {
          apply(v);
          saving(() => saveScope(def.type, s));
        },
      }).node;
      return [
        toggle('Notifications', isOn(s), (v) => { s.mute_for = v ? 0 : MUTE_FOREVER; }),
        toggle('Message preview', s.show_preview, (v) => { s.show_preview = v; },
          'Show the message text in notifications.'),
        toggle('Pinned messages', !s.disable_pinned_message_notifications,
          (v) => { s.disable_pinned_message_notifications = !v; }),
        toggle('Mentions and replies', !s.disable_mention_notifications,
          (v) => { s.disable_mention_notifications = !v; },
          'Notify about mentions and replies even when the chat is muted.'),
        section(`Exceptions${ids.length ? ` (${ids.length})` : ''}`),
        ids.length
          ? el('div', { class: 'tgbox__list' }, ...ids.map((id) => {
            const chat = store.chats.find((c) => String(c.id) === id);
            const line = peerLine(cards.get(`c${id}`), { sub: chat?.muted ? 'Muted' : 'Custom' });
            line.classList.add('is-clickable');
            line.addEventListener('click', () => {
              box.close();
              setActiveChat(Number(id));
            });
            return line;
          }))
          : note('Chats with their own notification settings are listed here. '
            + 'Change them from the chat’s menu.'),
      ];
    },
    buttons: [{ label: 'Close', run: (box) => box.close() }],
  };
}

export async function renderNotifyScopes() {
  const steps = [];
  for (const d of SCOPES) {
    steps.push({ key: d.type, method: 'getScopeNotificationSettings', params: { scope: scope(d.type) }, soft: true });
    steps.push({
      key: `${d.type}.x`, method: 'getChatNotificationSettingsExceptions',
      params: { scope: scope(d.type), compare_sound: false }, soft: true,
    });
  }
  steps.push({ key: 'contactJoined', method: 'getOption', params: { name: 'disable_contact_registered_notifications' }, soft: true });
  const a = await td(steps);
  const chats = group('Notifications for chats',
    ...SCOPES.map((d) => {
      const s = a[d.type];
      const x = a[`${d.type}.x`];
      const count = failed(x) ? 0 : (x.chat_ids?.length ?? 0);
      return navRow({
        label: d.label,
        hint: count ? `${count} exception${count === 1 ? '' : 's'}` : '',
        value: failed(s) ? '' : (isOn(s) ? 'On' : 'Off'),
        onClick: failed(s) ? null : () => openBox().push(scopePage(d, s, failed(x) ? null : x)),
      });
    }));
  const joinedOff = !failed(a.contactJoined) && a.contactJoined.value === true;
  const pinnedOn = SCOPES.some((d) => !failed(a[d.type]) && !a[d.type].disable_pinned_message_notifications);
  const events = group('Events',
    switchRow('Contact joined Telegram', null, !joinedOff, (on) => saving(() => one('setOption', {
      name: 'disable_contact_registered_notifications', value: { '@type': 'optionValueBoolean', value: !on },
    }))),
    switchRow('Pinned messages', null, pinnedOn, (on) => saving(async () => {
      for (const d of SCOPES) {
        if (failed(a[d.type])) continue;
        await saveScope(d.type, { ...a[d.type], disable_pinned_message_notifications: !on });
      }
    })));
  const reset = group(null,
    navRow({
      label: 'Reset all notifications', danger: true,
      hint: 'Undo all custom notification settings for all your contacts, groups and channels.',
      onClick: () => openBox().push({
        title: 'Reset all notifications',
        render: () => [note('Are you sure you want to reset all notification settings to default?')],
        buttons: [
          { label: 'Cancel', run: (box) => box.close() },
          {
            label: 'Reset', danger: true,
            async run(box) {
              await one('resetAllNotificationSettings');
              box.close();
              refresh();
            },
          },
        ],
      }),
    }));
  return [chats, events, reset];
}

/** «Accept calls on this device» (Speakers and camera у Desktop). */
export async function renderAcceptCalls() {
  let sessions = null;
  try {
    sessions = await one('getActiveSessions');
  } catch {
    return [];
  }
  const current = sessions.sessions?.find((s) => s.is_current);
  if (!current) return [];
  return [group('Calls',
    switchRow('Accept calls on this device', null, current.can_accept_calls,
      (on) => saving(() => one('toggleSessionCanAcceptCalls', { session_id: current.id, can_accept_calls: on }))))];
}

