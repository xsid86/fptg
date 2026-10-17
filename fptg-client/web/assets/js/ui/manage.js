import { el } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { copyText } from '../util/clipboard.js';
import { openMenu } from '../util/menu.js';
import {
  openBox, showError, section, note, linkRow, toggleRow, radioGroup, textField,
  peerRow, photoPicker, contactPicker,
} from './tgbox.js';

// Управление группой и каналом — как «Manage group / Manage channel» у
// Telegram Desktop: фото, название, описание; тип (публичный/частный),
// история для новых участников, права участников и медленный режим,
// администраторы и их права, участники (повысить, ограничить, удалить),
// удалённые, ссылки-приглашения, недавние действия, удаление.
//
// Данные — ответы TDLib как есть (команда admin, webapi.pas; поля —
// td_api.tl коммита d1085f9), карточки людей — users.cards.

let call = null;

const admin = (steps) => call('admin', { steps });
const one = async (method, params) => (await admin([{ key: 'r', method, params }])).r;
const sender = (userId) => ({ '@type': 'messageSenderUser', user_id: Number(userId) });
const myId = () => store.chats.find((c) => c.kind === 'self')?.id ?? 0;

/** Карточки людей по id (users.cards) — Map id -> карточка. */
async function cards(ids) {
  const uniq = [...new Set(ids.filter(Boolean).map(String))];
  if (!uniq.length) return new Map();
  const answer = await call('users.cards', { ids: uniq });
  return new Map((answer?.items ?? []).map((c) => [String(c.userId), c]));
}

// ------------------------------------------------------------ данные

// Обычная группа, переведённая в супергруппу (тип, история): старый id
// -> новый. Страницы держат id, с которым открылись.
const migrated = new Map();

/**
 * Обычную группу — в супергруппу, как Desktop делает сам, когда для
 * изменения нужна супергруппа (тип, история). ctx обновляется на месте,
 * открытый чат переключается на новый.
 */
async function ensureSuper(ctx) {
  if (ctx.isSuper) return ctx;
  const chat = await one('upgradeBasicGroupChatToSupergroupChat', { chat_id: ctx.chatId });
  migrated.set(ctx.chatId, chat.id);
  Object.assign(ctx, await load(chat.id));
  setActiveChat(chat.id);
  return ctx;
}

/** Чат, группа, полные сведения и мои права. */
async function load(requestedId) {
  const chatId = migrated.get(requestedId) ?? requestedId;
  const { chat } = await admin([{ key: 'chat', method: 'getChat', params: { chat_id: chatId } }]);
  const t = chat.type ?? {};
  const ctx = { chatId, chat, isChannel: false, isSuper: false, sgId: 0, bgId: 0 };
  if (t['@type'] === 'chatTypeSupergroup') {
    ctx.isSuper = true;
    ctx.isChannel = !!t.is_channel;
    ctx.sgId = t.supergroup_id;
    Object.assign(ctx, await admin([
      { key: 'group', method: 'getSupergroup', params: { supergroup_id: t.supergroup_id } },
      { key: 'full', method: 'getSupergroupFullInfo', params: { supergroup_id: t.supergroup_id } },
    ]));
  } else if (t['@type'] === 'chatTypeBasicGroup') {
    ctx.bgId = t.basic_group_id;
    Object.assign(ctx, await admin([
      { key: 'group', method: 'getBasicGroup', params: { basic_group_id: t.basic_group_id } },
      { key: 'full', method: 'getBasicGroupFullInfo', params: { basic_group_id: t.basic_group_id } },
    ]));
  } else {
    throw new Error('Not a group or channel');
  }
  const status = ctx.group.status ?? {};
  ctx.isCreator = status['@type'] === 'chatMemberStatusCreator';
  ctx.rights = status.rights ?? {};
  ctx.can = (right) => ctx.isCreator || !!ctx.rights[right];
  ctx.word = ctx.isChannel ? 'channel' : 'group';
  ctx.username = ctx.group.usernames?.editable_username ?? '';
  return ctx;
}

// -------------------------------------------------------- права участников

// Права участников, как в «Permissions» у Desktop: основные и раскрытый
// список медиа под «Send media».
const MEDIA_RIGHTS = [
  ['can_send_photos', 'Photos'],
  ['can_send_videos', 'Video files'],
  ['can_send_other_messages', 'Stickers & GIFs'],
  ['can_send_audios', 'Music'],
  ['can_send_documents', 'Files'],
  ['can_send_voice_notes', 'Voice messages'],
  ['can_send_video_notes', 'Video messages'],
  ['can_add_link_previews', 'Embed links'],
  ['can_send_polls', 'Polls'],
];
const OTHER_RIGHTS = [
  ['can_invite_users', 'Add members'],
  ['can_pin_messages', 'Pin messages'],
  ['can_change_info', 'Change group info'],
];
const ALL_PERMISSIONS = ['can_send_basic_messages', ...MEDIA_RIGHTS.map((r) => r[0]), ...OTHER_RIGHTS.map((r) => r[0])];

function permissionsFrom(src = {}) {
  const p = { '@type': 'chatPermissions' };
  for (const k of [...ALL_PERMISSIONS, 'can_react_to_messages', 'can_edit_tag', 'can_create_topics']) p[k] = !!src[k];
  return p;
}

/** Переключатели прав; .read() — chatPermissions. */
function permissionsForm(current, { isForum = false } = {}) {
  const inputs = new Map();
  const add = (key, label) => {
    const t = toggleRow(label, !!current[key]);
    inputs.set(key, t.input);
    return t.node;
  };
  const basic = add('can_send_basic_messages', 'Send messages');
  const media = MEDIA_RIGHTS.map(([k, l]) => add(k, l));
  const mediaBox = el('div', { class: 'tgbox__sub', hidden: true }, ...media);
  const mediaOn = () => MEDIA_RIGHTS.filter(([k]) => inputs.get(k).checked).length;
  const mediaMaster = toggleRow('Send media', mediaOn() > 0, { sub: `${mediaOn()}/${MEDIA_RIGHTS.length}` });
  const mediaSub = mediaMaster.node.querySelector('.tgbox__row-sub');
  mediaMaster.input.addEventListener('change', () => {
    for (const [k] of MEDIA_RIGHTS) inputs.get(k).checked = mediaMaster.input.checked;
    mediaSub.textContent = `${mediaOn()}/${MEDIA_RIGHTS.length}`;
  });
  for (const [k] of MEDIA_RIGHTS) {
    inputs.get(k).addEventListener('change', () => {
      mediaMaster.input.checked = mediaOn() > 0;
      mediaSub.textContent = `${mediaOn()}/${MEDIA_RIGHTS.length}`;
    });
  }
  const expand = el('button', {
    class: 'tgbox__expand', type: 'button', title: 'Show media types',
    onclick: () => { mediaBox.hidden = !mediaBox.hidden; expand.classList.toggle('is-open', !mediaBox.hidden); },
  }, '›');
  mediaMaster.node.insertBefore(expand, mediaMaster.input);
  const others = OTHER_RIGHTS.map(([k, l]) => add(k, l));
  const topics = isForum ? add('can_create_topics', 'Manage topics') : null;
  return {
    nodes: [basic, mediaMaster.node, mediaBox, ...others, topics],
    read() {
      const p = permissionsFrom(current);
      for (const [k, input] of inputs) p[k] = input.checked;
      // Реакции и метки — как были (у Desktop их тут нет).
      return p;
    },
  };
}

const countOn = (perm) => ALL_PERMISSIONS.filter((k) => perm?.[k]).length;

// --------------------------------------------------------- права админа

const ADMIN_GROUP = [
  ['can_change_info', 'Change group info'],
  ['can_delete_messages', 'Delete messages'],
  ['can_restrict_members', 'Ban users'],
  ['can_invite_users', 'Invite users via link'],
  ['can_pin_messages', 'Pin messages'],
  ['can_manage_topics', 'Manage topics'],
  ['can_post_stories', 'Post stories'],
  ['can_edit_stories', 'Edit stories of others'],
  ['can_delete_stories', 'Delete stories of others'],
  ['can_manage_video_chats', 'Manage video chats'],
  ['is_anonymous', 'Remain anonymous'],
  ['can_promote_members', 'Add new admins'],
];
const ADMIN_CHANNEL = [
  ['can_change_info', 'Change channel info'],
  ['can_post_messages', 'Post messages'],
  ['can_edit_messages', 'Edit messages of others'],
  ['can_delete_messages', 'Delete messages of others'],
  ['can_post_stories', 'Post stories'],
  ['can_edit_stories', 'Edit stories of others'],
  ['can_delete_stories', 'Delete stories of others'],
  ['can_invite_users', 'Add subscribers'],
  ['can_manage_video_chats', 'Manage live streams'],
  ['can_manage_direct_messages', 'Manage direct messages'],
  ['can_promote_members', 'Add new admins'],
];
// Новому администратору — всё, кроме «добавлять админов» и анонимности,
// как у Desktop.
const NEW_ADMIN_OFF = new Set(['can_promote_members', 'is_anonymous']);

// ------------------------------------------------------------ страницы

/** Главная: фото, название, описание и разделы. */
function mainPage(chatId) {
  let ctx = null;
  let title = null;
  let about = null;
  let photo = null;
  return {
    title: 'Manage',
    async render(body, box) {
      ctx = await load(chatId);
      // Заголовок окна сменится вместе со страницей (tgbox, show).
      this.title = ctx.isChannel ? 'Manage channel' : 'Manage group';
      const canInfo = ctx.can('can_change_info');
      const rowCard = store.chats.find((c) => c.id === chatId) ?? { id: chatId, title: ctx.chat.title };
      photo = photoPicker(rowCard);
      if (!canInfo) photo.node.disabled = true;
      title = textField(ctx.isChannel ? 'Channel name' : 'Group name', ctx.chat.title ?? '', { max: 128 });
      title.input.disabled = !canInfo;
      about = textField('Description (optional)', ctx.full.description ?? '', { multiline: true, max: 255 });
      about.input.disabled = !canInfo;

      const rows = [];
      const word = ctx.word;
      // Тип — и у обычной группы: при смене она станет супергруппой.
      if (ctx.isCreator) {
        rows.push(linkRow({
          iconName: 'lock', label: ctx.isChannel ? 'Channel type' : 'Group type',
          value: ctx.username ? 'Public' : 'Private',
          onClick: () => box.push(typePage(ctx)),
        }));
      }
      if (!ctx.isChannel && canInfo) {
        rows.push(linkRow({
          iconName: 'chat', label: 'Chat history for new members',
          // У обычной группы история новым участникам видна всегда.
          value: !ctx.isSuper || ctx.full.is_all_history_available ? 'Visible' : 'Hidden',
          onClick: () => box.push(historyPage(ctx)),
        }));
      }
      if (!ctx.isChannel && ctx.can('can_restrict_members')) {
        rows.push(linkRow({
          iconName: 'lock', label: 'Permissions',
          value: `${countOn(ctx.chat.permissions)}/${ALL_PERMISSIONS.length}`,
          onClick: () => box.push(permissionsPage(ctx)),
        }));
      }
      if (ctx.isChannel && canInfo) {
        const sign = toggleRow('Sign messages', !!ctx.group.sign_messages, {
          sub: 'Add names of the admins to the messages they post.',
          onChange: async (on) => {
            try {
              await one('toggleSupergroupSignMessages', { supergroup_id: ctx.sgId, sign_messages: on, show_message_sender: false });
            } catch (error) {
              sign.input.checked = !on;
              showError(body, error);
            }
          },
        });
        rows.push(sign.node);
      }
      if (ctx.can('can_invite_users')) {
        rows.push(linkRow({ iconName: 'link', label: 'Invite links', onClick: () => box.push(linksPage(ctx)) }));
      }
      const admins = ctx.isSuper ? ctx.full.administrator_count
        : (ctx.full.members ?? []).filter((m) => /Creator|Administrator/.test(m.status?.['@type'] ?? '')).length;
      rows.push(linkRow({ iconName: 'crown', label: 'Administrators', value: admins ?? '', onClick: () => box.push(adminsPage(ctx)) }));
      const members = ctx.isSuper ? ctx.full.member_count : ctx.group.member_count;
      rows.push(linkRow({
        iconName: ctx.isChannel ? 'person' : 'group', label: ctx.isChannel ? 'Subscribers' : 'Members',
        value: members ?? '', onClick: () => box.push(membersPage(ctx)),
      }));
      if (ctx.isSuper && ctx.can('can_restrict_members')) {
        rows.push(linkRow({
          iconName: 'close', label: 'Removed users', value: ctx.full.banned_count ?? '',
          onClick: () => box.push(bannedPage(ctx)),
        }));
      }
      if (ctx.isSuper) {
        rows.push(linkRow({ iconName: 'clock', label: 'Recent actions', onClick: () => box.push(logPage(ctx)) }));
      }
      const danger = ctx.isCreator ? linkRow({
        label: ctx.isChannel ? 'Delete channel' : 'Delete group', danger: true,
        onClick: async () => {
          if (!window.confirm(`Delete this ${word} for everyone? This cannot be undone.`)) return;
          try {
            await one('deleteChat', { chat_id: chatId });
            box.close();
            setActiveChat(null);
          } catch (error) {
            showError(body, error);
          }
        },
      }) : null;

      return [
        el('div', { class: 'tgbox__info' }, photo.node, el('div', { class: 'tgbox__info-fields' }, title.node)),
        about.node,
        el('div', { class: 'tgbox__rows' }, ...rows),
        danger ? el('div', { class: 'tgbox__rows' }, danger) : null,
      ];
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          if (!ctx) return;
          const steps = [];
          const newTitle = title.input.value.trim();
          if (!newTitle) throw new Error(`Enter a ${ctx.word} name`);
          if (newTitle !== ctx.chat.title) steps.push({ key: 't', method: 'setChatTitle', params: { chat_id: chatId, title: newTitle } });
          if (about.input.value !== (ctx.full.description ?? '')) {
            steps.push({ key: 'd', method: 'setChatDescription', params: { chat_id: chatId, description: about.input.value } });
          }
          if (photo.changed()) {
            const id = await photo.upload();
            if (id) {
              steps.push({
                key: 'p', method: 'setChatPhoto',
                params: { chat_id: chatId, photo: { '@type': 'inputChatPhotoStatic', photo: { '@type': 'inputFileUpload', id } } },
              });
            }
          }
          if (steps.length) {
            for (const st of steps) st.params.chat_id = ctx.chatId;
            await admin(steps);
          }
          box.close();
        },
      },
    ],
  };
}

/** Тип: публичный (адрес t.me/…) или частный (ссылка-приглашение). */
export function typePage(ctx, { after } = {}) {
  let kind = ctx.username ? 'public' : 'private';
  let username = null;
  let protect = null;
  let approve = null;
  let checkTimer = 0;
  return {
    title: ctx.isChannel ? 'Channel type' : 'Group type',
    async render(body, box) {
      const what = ctx.isChannel ? 'channel' : 'group';
      const radios = radioGroup('chat-type', [
        { value: 'public', label: ctx.isChannel ? 'Public channel' : 'Public group', sub: `Anyone can find the ${what} in search and join.` },
        { value: 'private', label: ctx.isChannel ? 'Private channel' : 'Private group', sub: `Only people with a special invite link can join.` },
      ], kind, (v) => { kind = v; box.refresh(); });

      const parts = [radios.node];
      if (kind === 'public') {
        username = textField('link', ctx.username, { prefix: 't.me/', max: 32 });
        const status = note('');
        const check = async () => {
          const name = username.input.value.trim();
          if (!name || name === ctx.username) { status.textContent = ''; return; }
          try {
            const r = await one('checkChatUsername', { chat_id: ctx.chatId, username: name });
            status.textContent = {
              checkChatUsernameResultOk: `${name} is available.`,
              checkChatUsernameResultUsernameInvalid: 'This link is invalid.',
              checkChatUsernameResultUsernameOccupied: 'This link is already occupied.',
              checkChatUsernameResultUsernamePurchasable: 'This link is available for purchase.',
              checkChatUsernameResultPublicChatsTooMany: 'You have reserved too many public links.',
              checkChatUsernameResultPublicGroupsUnavailable: 'You can\'t make this group public.',
            }[r['@type']] ?? '';
            status.classList.toggle('is-ok', r['@type'] === 'checkChatUsernameResultOk');
          } catch (error) {
            status.textContent = error.message;
          }
        };
        username.input.addEventListener('input', () => {
          clearTimeout(checkTimer);
          checkTimer = setTimeout(check, 400);
        });
        parts.push(section('Public link'), username.node, status,
          note(`People can share this link with others and find your ${what} using Telegram search.`));
        if (!ctx.isChannel) {
          approve = toggleRow('Approve new members', !!ctx.group.join_by_request,
            { sub: 'Admins will have to approve new members before they can join.' });
          parts.push(approve.node);
        }
      } else {
        const link = ctx.full.invite_link?.invite_link ?? '';
        const linkBox = el('div', { class: 'tgbox__link' }, link || 'No link yet');
        parts.push(section('Invite link'), linkBox,
          el('div', { class: 'tgbox__link-actions' },
            el('button', {
              class: 'btn tgbox__btn', type: 'button', disabled: !link,
              onclick: async () => { await copyText(link); emit('ui:notice', 'Link copied to clipboard'); },
            }, 'Copy link'),
            el('button', {
              class: 'btn tgbox__btn', type: 'button',
              onclick: async () => {
                try {
                  const fresh = await one('replacePrimaryChatInviteLink', { chat_id: ctx.chatId });
                  ctx.full.invite_link = fresh;
                  linkBox.textContent = fresh.invite_link;
                } catch (error) {
                  showError(body, error);
                }
              },
            }, link ? 'Revoke link' : 'Create link')),
          note(`People can join your ${what} by following this link. You can revoke the link any time.`));
      }
      protect = toggleRow('Restrict saving content', !!ctx.chat.has_protected_content,
        { sub: `Members won't be able to forward messages from this ${what} or save media.` });
      parts.push(section('Saving content'), protect.node);
      return parts;
    },
    buttons: [
      { label: after ? 'Skip' : 'Cancel', run: (box) => (after ? after(box) : box.pop()) },
      {
        label: 'Save', primary: true,
        async run(box) {
          const steps = [];
          const name = kind === 'public' ? username.input.value.trim() : '';
          if (kind === 'public' && !name) throw new Error('Enter a link');
          const changes = name !== ctx.username
            || (approve && approve.input.checked !== !!ctx.group.join_by_request)
            || protect.input.checked !== !!ctx.chat.has_protected_content;
          // Публичной и прочим настройкам типа нужна супергруппа.
          if (changes && name !== ctx.username) await ensureSuper(ctx);
          if (name !== ctx.username) steps.push({ key: 'u', method: 'setSupergroupUsername', params: { supergroup_id: ctx.sgId, username: name } });
          if (approve && approve.input.checked !== !!ctx.group.join_by_request) {
            steps.push({ key: 'j', method: 'toggleSupergroupJoinByRequest', params: { supergroup_id: ctx.sgId, join_by_request: approve.input.checked, guard_bot_user_id: 0, apply_to_invite_links: false } });
          }
          if (protect.input.checked !== !!ctx.chat.has_protected_content) {
            steps.push({ key: 'p', method: 'toggleChatHasProtectedContent', params: { chat_id: ctx.chatId, has_protected_content: protect.input.checked } });
          }
          if (steps.length) await admin(steps);
          if (after) after(box);
          else box.pop();
        },
      },
    ],
  };
}

function historyPage(ctx) {
  let radios = null;
  return {
    title: 'Chat history for new members',
    render() {
      radios = radioGroup('history', [
        { value: 'visible', label: 'Visible', sub: 'New members will see messages that were sent before they joined.' },
        { value: 'hidden', label: 'Hidden', sub: 'New members won\'t see earlier messages.' },
      ], !ctx.isSuper || ctx.full.is_all_history_available ? 'visible' : 'hidden');
      return [radios.node];
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const on = radios.value() === 'visible';
          const was = !ctx.isSuper || !!ctx.full.is_all_history_available;
          if (on !== was) {
            await ensureSuper(ctx);
            await one('toggleSupergroupIsAllHistoryAvailable', { supergroup_id: ctx.sgId, is_all_history_available: on });
          }
          box.pop();
        },
      },
    ],
  };
}

// Медленный режим: значения Desktop.
const SLOW = [[0, 'Off'], [10, '10s'], [30, '30s'], [60, '1m'], [300, '5m'], [900, '15m'], [3600, '1h']];

function permissionsPage(ctx) {
  let form = null;
  let slow = ctx.full?.slow_mode_delay ?? 0;
  return {
    title: 'Permissions',
    async render(body, box) {
      form = permissionsForm(ctx.chat.permissions ?? {}, { isForum: !!ctx.group.is_forum });
      const parts = [section('What can members of this group do?'), ...form.nodes];
      if (ctx.isSuper) {
        const chips = el('div', { class: 'tgbox__chips' }, ...SLOW.map(([v, label]) => el('button', {
          class: `tgbox__chip${v === slow ? ' is-active' : ''}`, type: 'button',
          onclick: (event) => {
            slow = v;
            for (const c of chips.children) c.classList.toggle('is-active', c === event.currentTarget);
          },
        }, label)));
        parts.push(section('Slow mode'), chips,
          note('Choose how long each member must wait before sending their next message.'));
        // Исключения — ограниченные участники.
        const restricted = await one('getSupergroupMembers', {
          supergroup_id: ctx.sgId, filter: { '@type': 'supergroupMembersFilterRestricted', query: '' }, offset: 0, limit: 200,
        });
        const people = await cards(restricted.members.map((m) => m.member_id?.user_id));
        parts.push(section('Exceptions'),
          linkRow({ iconName: 'person', label: 'Add exception', onClick: () => box.push(pickMemberPage(ctx, 'Add exception', (m) => box.push(restrictPage(ctx, m)))) }),
          ...restricted.members.map((m) => {
            const card = people.get(String(m.member_id?.user_id));
            return card ? peerRow(card, { sub: 'Restricted', onClick: () => box.push(restrictPage(ctx, { card, status: m.status })) }) : null;
          }),
          linkRow({ iconName: 'close', label: 'Removed users', value: ctx.full.banned_count ?? '', onClick: () => box.push(bannedPage(ctx)) }));
      }
      return parts;
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const steps = [{ key: 'p', method: 'setChatPermissions', params: { chat_id: ctx.chatId, permissions: form.read() } }];
          if (ctx.isSuper && slow !== (ctx.full.slow_mode_delay ?? 0)) {
            steps.push({ key: 's', method: 'setChatSlowModeDelay', params: { chat_id: ctx.chatId, slow_mode_delay: slow } });
          }
          await admin(steps);
          ctx.chat.permissions = form.read();
          ctx.full.slow_mode_delay = slow;
          box.pop();
        },
      },
    ],
  };
}

/** Участники чата: { card, status, tag, isMe }. */
async function members(ctx, filter = 'recent', query = '') {
  let list;
  if (ctx.isSuper) {
    const f = {
      recent: { '@type': 'supergroupMembersFilterRecent' },
      admins: { '@type': 'supergroupMembersFilterAdministrators' },
      banned: { '@type': 'supergroupMembersFilterBanned', query },
      search: { '@type': 'supergroupMembersFilterSearch', query },
    }[filter];
    list = (await one('getSupergroupMembers', { supergroup_id: ctx.sgId, filter: f, offset: 0, limit: 200 })).members;
  } else {
    const full = await one('getBasicGroupFullInfo', { basic_group_id: ctx.bgId });
    list = full.members ?? [];
    if (filter === 'admins') list = list.filter((m) => /Creator|Administrator/.test(m.status?.['@type'] ?? ''));
    if (query) {
      const people = await cards(list.map((m) => m.member_id?.user_id));
      const q = query.toLowerCase();
      list = list.filter((m) => (people.get(String(m.member_id?.user_id))?.title ?? '').toLowerCase().includes(q));
    }
  }
  const users = list.filter((m) => m.member_id?.['@type'] === 'messageSenderUser');
  const people = await cards(users.map((m) => m.member_id.user_id));
  const me = String(myId());
  return users.map((m) => ({
    card: people.get(String(m.member_id.user_id)) ?? { userId: String(m.member_id.user_id), title: 'Deleted account' },
    status: m.status ?? {},
    tag: m.tag ?? '',
    isMe: String(m.member_id.user_id) === me,
  })).filter((m) => m.card);
}

const roleOf = (m) => {
  const t = m.status['@type'];
  if (t === 'chatMemberStatusCreator') return 'owner';
  if (t === 'chatMemberStatusAdministrator') return m.tag || 'admin';
  return m.tag || '';
};

function adminsPage(ctx) {
  return {
    title: 'Administrators',
    async render(body, box) {
      const list = await members(ctx, 'admins');
      const parts = [];
      if (ctx.can('can_promote_members')) {
        parts.push(linkRow({
          iconName: 'crown', label: 'Add admin',
          onClick: () => box.push(pickMemberPage(ctx, 'Add admin', (m) => box.push(rightsPage(ctx, m)))),
        }));
      }
      parts.push(section(`${list.length} administrators`),
        ...list.map((m) => peerRow(m.card, {
          sub: m.status['@type'] === 'chatMemberStatusCreator' ? 'Owner' : (m.tag || 'Admin'),
          onClick: (!m.isMe && m.status['@type'] === 'chatMemberStatusAdministrator'
            && (ctx.isCreator || m.status.can_be_edited)) ? () => box.push(rightsPage(ctx, m)) : null,
        })));
      if (ctx.isChannel) parts.push(note('You can add admins to help you manage your channel.'));
      else parts.push(note('You can add admins to help you manage your group.'));
      return parts;
    },
    buttons: [{ label: 'Close', run: (box) => box.pop() }],
  };
}

/** Права администратора (новый или существующий). */
function rightsPage(ctx, member) {
  const isNew = member.status?.['@type'] !== 'chatMemberStatusAdministrator';
  const current = isNew ? {} : (member.status.rights ?? {});
  const list = ctx.isChannel ? ADMIN_CHANNEL : ADMIN_GROUP.filter(([k]) => k !== 'can_manage_topics' || ctx.group.is_forum);
  const inputs = new Map();
  let title = null;
  return {
    title: isNew ? 'Add admin' : 'Admin rights',
    render() {
      const toggles = list.map(([k, label]) => {
        const on = isNew ? !NEW_ADMIN_OFF.has(k) && ctx.can(k) : !!current[k];
        // Дать можно только то, что есть у самого (кроме владельца).
        const t = toggleRow(label, on, { disabled: !ctx.isCreator && !ctx.rights[k] });
        inputs.set(k, t.input);
        return t.node;
      });
      const parts = [peerRow(member.card), section('What can this admin do?'), ...toggles];
      if (!ctx.isChannel) {
        title = textField('Custom title', member.tag ?? '', { max: 16 });
        parts.push(section('Custom title'), title.node, note('A title that members will see instead of \'admin\'.'));
      }
      if (!isNew) {
        parts.push(linkRow({
          label: 'Dismiss admin', danger: true,
          onClick: async () => {
            await one('setChatMemberStatus', {
              chat_id: ctx.chatId, member_id: sender(member.card.userId),
              status: { '@type': 'chatMemberStatusMember', member_until_date: 0 },
            });
            ctx.full.administrator_count = Math.max(0, (ctx.full.administrator_count ?? 1) - 1);
            box.pop();
          },
        }));
      }
      return parts;
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const rights = { '@type': 'chatAdministratorRights', can_manage_chat: true };
          for (const k of [...ADMIN_GROUP, ...ADMIN_CHANNEL].map((r) => r[0])) rights[k] = inputs.get(k)?.checked ?? !!current[k];
          const steps = [{
            key: 's', method: 'setChatMemberStatus',
            params: {
              chat_id: ctx.chatId, member_id: sender(member.card.userId),
              status: { '@type': 'chatMemberStatusAdministrator', can_be_edited: true, rights },
            },
          }];
          if (title && title.input.value.trim() !== (member.tag ?? '')) {
            steps.push({ key: 't', method: 'setChatMemberTag', params: { chat_id: ctx.chatId, user_id: Number(member.card.userId), tag: title.input.value.trim() } });
          }
          await admin(steps);
          // Из выбора участника — на две страницы назад, к списку админов.
          box.pop();
          if (isNew && box.depth > 1) box.pop();
        },
      },
    ],
  };
}

/** Выбор участника (для «Add admin», «Add exception»). */
function pickMemberPage(ctx, title, onPick) {
  let query = '';
  return {
    title,
    async render(body, box) {
      const search = textField('Search', query);
      const listBox = el('div', { class: 'tgbox__list' });
      const fill = async () => {
        const list = await members(ctx, query ? 'search' : 'recent', query);
        listBox.replaceChildren(...list.filter((m) => !m.isMe && m.status['@type'] !== 'chatMemberStatusCreator')
          .map((m) => peerRow(m.card, { right: roleOf(m), onClick: () => onPick(m) })));
      };
      let timer = 0;
      search.input.addEventListener('input', () => {
        query = search.input.value.trim();
        clearTimeout(timer);
        timer = setTimeout(() => fill().catch((e) => showError(body, e)), 300);
      });
      await fill();
      return [search.node, listBox];
    },
    buttons: [{ label: 'Cancel', run: (box) => box.pop() }],
  };
}

/** Ограничения одного участника (исключение из прав группы). */
function restrictPage(ctx, member) {
  const base = member.status?.['@type'] === 'chatMemberStatusRestricted'
    ? member.status.permissions : ctx.chat.permissions;
  let form = null;
  return {
    title: 'Exception',
    render(body, box) {
      form = permissionsForm(base ?? {}, { isForum: !!ctx.group.is_forum });
      return [peerRow(member.card), section('What can this member do?'), ...form.nodes,
        linkRow({
          label: `Remove from ${ctx.word}`, danger: true,
          onClick: async () => {
            await banMember(ctx, member.card.userId);
            box.pop();
          },
        })];
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          await one('setChatMemberStatus', {
            chat_id: ctx.chatId, member_id: sender(member.card.userId),
            status: { '@type': 'chatMemberStatusRestricted', is_member: true, restricted_until_date: 0, permissions: form.read() },
          });
          box.pop();
          if (box.depth > 2) box.pop();
        },
      },
    ],
  };
}

const banMember = (ctx, userId) => one('banChatMember', {
  chat_id: ctx.chatId, member_id: sender(userId), banned_until_date: 0, revoke_messages: false,
});

function membersPage(ctx) {
  let query = '';
  return {
    title: ctx.isChannel ? 'Subscribers' : 'Members',
    async render(body, box) {
      const search = textField('Search', query);
      const listBox = el('div', { class: 'tgbox__list' });
      const fill = async () => {
        const list = await members(ctx, query ? 'search' : 'recent', query);
        listBox.replaceChildren(...list.map((m) => {
          const row = peerRow(m.card, {
            right: roleOf(m),
            onClick: m.isMe || m.status['@type'] === 'chatMemberStatusCreator' ? null : () => {
              const items = [];
              if (ctx.can('can_promote_members')) {
                items.push({
                  label: m.status['@type'] === 'chatMemberStatusAdministrator' ? 'Edit admin rights' : 'Promote to admin',
                  onSelect: () => box.push(rightsPage(ctx, m)),
                });
              }
              if (!ctx.isChannel && ctx.can('can_restrict_members')) {
                items.push({ label: 'Restrict user', onSelect: () => box.push(restrictPage(ctx, m)) });
              }
              if (ctx.can('can_restrict_members')) {
                items.push({
                  label: `Remove from ${ctx.word}`, className: 'is-danger',
                  onSelect: async () => {
                    try {
                      await banMember(ctx, m.card.userId);
                      row.remove();
                    } catch (error) {
                      showError(body, error);
                    }
                  },
                });
              }
              if (items.length) openMenu(row, items);
            },
          });
          return row;
        }));
      };
      let timer = 0;
      search.input.addEventListener('input', () => {
        query = search.input.value.trim();
        clearTimeout(timer);
        timer = setTimeout(() => fill().catch((e) => showError(body, e)), 300);
      });
      await fill();
      const parts = [];
      if (ctx.can('can_invite_users')) {
        parts.push(linkRow({
          iconName: 'person', label: ctx.isChannel ? 'Add subscribers' : 'Add members',
          onClick: () => box.push(addMembersPage(ctx)),
        }));
      }
      parts.push(search.node, listBox);
      return parts;
    },
    buttons: [{ label: 'Close', run: (box) => box.pop() }],
  };
}

function addMembersPage(ctx) {
  let picker = null;
  return {
    title: ctx.isChannel ? 'Add subscribers' : 'Add members',
    async render() {
      picker = await contactPicker(call);
      return picker.nodes;
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Add', primary: true,
        async run(box) {
          const ids = picker.chosen().map(Number);
          if (ids.length) {
            const r = await one('addChatMembers', { chat_id: ctx.chatId, user_ids: ids });
            const failed = r?.failed_to_add_members?.length ?? 0;
            if (failed) emit('ui:notice', `${failed} could not be added: their privacy settings do not allow it`);
          }
          box.pop();
        },
      },
    ],
  };
}

function bannedPage(ctx) {
  return {
    title: 'Removed users',
    async render(body) {
      const list = await members(ctx, 'banned');
      if (!list.length) return [note(`Users removed from the ${ctx.word} by admins can't rejoin via invite links.`), note('No removed users.')];
      return [note(`Users removed from the ${ctx.word} by admins can't rejoin via invite links.`),
        ...list.map((m) => {
          const row = peerRow(m.card, {
            sub: 'Removed',
            onClick: () => openMenu(row, [{
              label: 'Unban',
              onSelect: async () => {
                try {
                  await one('setChatMemberStatus', {
                    chat_id: ctx.chatId, member_id: sender(m.card.userId), status: { '@type': 'chatMemberStatusLeft' },
                  });
                  row.remove();
                } catch (error) {
                  showError(body, error);
                }
              },
            }]),
          });
          return row;
        })];
    },
    buttons: [{ label: 'Close', run: (box) => box.pop() }],
  };
}

function linksPage(ctx) {
  return {
    title: 'Invite links',
    async render(body, box) {
      const me = myId();
      const [active, revoked] = await Promise.all([false, true].map((rev) => one('getChatInviteLinks', {
        chat_id: ctx.chatId, creator_user_id: Number(me), is_revoked: rev, offset_date: 0, offset_invite_link: '', limit: 100,
      }).catch(() => ({ invite_links: [] }))));
      const primary = active.invite_links.find((l) => l.is_primary) ?? ctx.full.invite_link;
      const others = active.invite_links.filter((l) => !l.is_primary);
      const linkBox = el('div', { class: 'tgbox__link' }, primary?.invite_link || 'No link yet');
      const what = ctx.word;
      const linkRowOf = (l, isRevoked) => {
        const row = peerRow({ title: l.name || l.invite_link.replace(/^https?:\/\//, ''), color: 'a5' }, {
          sub: `${l.member_count ?? 0} joined${l.member_limit ? ` · limit ${l.member_limit}` : ''}${l.creates_join_request ? ' · approval' : ''}`,
          onClick: () => openMenu(row, isRevoked ? [{
            label: 'Delete link', className: 'is-danger',
            onSelect: async () => {
              await one('deleteRevokedChatInviteLink', { chat_id: ctx.chatId, invite_link: l.invite_link }).catch((e) => showError(body, e));
              box.refresh();
            },
          }] : [
            { label: 'Copy link', onSelect: async () => { await copyText(l.invite_link); emit('ui:notice', 'Link copied to clipboard'); } },
            {
              label: 'Revoke link', className: 'is-danger',
              onSelect: async () => {
                await one('revokeChatInviteLink', { chat_id: ctx.chatId, invite_link: l.invite_link }).catch((e) => showError(body, e));
                box.refresh();
              },
            },
          ]),
        });
        return row;
      };
      return [
        section('Invite link'), linkBox,
        el('div', { class: 'tgbox__link-actions' },
          el('button', {
            class: 'btn tgbox__btn', type: 'button', disabled: !primary,
            onclick: async () => { await copyText(primary.invite_link); emit('ui:notice', 'Link copied to clipboard'); },
          }, 'Copy link'),
          el('button', {
            class: 'btn tgbox__btn', type: 'button',
            onclick: async () => {
              try {
                await one('replacePrimaryChatInviteLink', { chat_id: ctx.chatId });
                box.refresh();
              } catch (error) {
                showError(body, error);
              }
            },
          }, primary ? 'Revoke link' : 'Create link')),
        note(`Anyone who has Telegram installed will be able to join your ${what} by following this link.`),
        linkRow({ iconName: 'link', label: 'Create a new link', onClick: () => box.push(newLinkPage(ctx)) }),
        others.length ? section('Additional links') : null,
        ...others.map((l) => linkRowOf(l, false)),
        revoked.invite_links.length ? section('Revoked links') : null,
        ...revoked.invite_links.map((l) => linkRowOf(l, true)),
      ];
    },
    buttons: [{ label: 'Close', run: (box) => box.pop() }],
  };
}

function newLinkPage(ctx) {
  let name = null;
  let limit = null;
  let approve = null;
  return {
    title: 'New link',
    render() {
      name = textField('Link name (optional)', '', { max: 32 });
      limit = textField('Limit number of users (0 — no limit)', '0');
      approve = toggleRow('Request admin approval', false, { sub: 'New users will be able to join only after an admin approves their request.' });
      return [approve.node, section('Link name'), name.node, section('Limit number of users'), limit.node];
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Create', primary: true,
        async run(box) {
          const n = Math.max(0, Number.parseInt(limit.input.value, 10) || 0);
          await one('createChatInviteLink', {
            chat_id: ctx.chatId, name: name.input.value.trim(), expiration_date: 0,
            member_limit: approve.input.checked ? 0 : n, creates_join_request: approve.input.checked,
          });
          box.pop();
        },
      },
    ],
  };
}

// ------------------------------------------------------- недавние действия

function contentText(m) {
  const c = m?.content ?? {};
  return c.text?.text || c.caption?.text || c.poll?.question?.text
    || ({ messagePhoto: 'Photo', messageVideo: 'Video', messageDocument: 'File', messageSticker: 'Sticker',
      messageAnimation: 'GIF', messageVoiceNote: 'Voice message', messageAudio: 'Audio' }[c['@type']] ?? 'Message');
}

function eventText(e, people) {
  const a = e.action ?? {};
  const who = (id) => people.get(String(id))?.title ?? 'Someone';
  const short = (s, n = 80) => (s && s.length > n ? `${s.slice(0, n)}…` : s || '');
  switch (a['@type']) {
    case 'chatEventMessageEdited': return `edited message: «${short(contentText(a.new_message))}»`;
    case 'chatEventMessageDeleted': return `deleted message: «${short(contentText(a.message))}»`;
    case 'chatEventMessagePinned': return `pinned message: «${short(contentText(a.message))}»`;
    case 'chatEventMessageUnpinned': return `unpinned message: «${short(contentText(a.message))}»`;
    case 'chatEventPollStopped': return 'stopped poll';
    case 'chatEventMemberJoined': return 'joined the group';
    case 'chatEventMemberJoinedByInviteLink': return 'joined via invite link';
    case 'chatEventMemberJoinedByRequest': return `joined, approved by ${who(a.approver_user_id)}`;
    case 'chatEventMemberInvited': return `invited ${who(a.user_id)}`;
    case 'chatEventMemberLeft': return 'left';
    case 'chatEventMemberPromoted':
      return a.new_status?.['@type'] === 'chatMemberStatusAdministrator'
        ? `changed admin rights of ${who(a.user_id)}` : `dismissed ${who(a.user_id)} from admins`;
    case 'chatEventMemberRestricted': {
      const t = a.new_status?.['@type'];
      const target = who(a.member_id?.user_id);
      if (t === 'chatMemberStatusBanned') return `removed ${target}`;
      if (t === 'chatMemberStatusRestricted') return `restricted ${target}`;
      return `unrestricted ${target}`;
    }
    case 'chatEventMemberTagChanged': return `changed the tag of ${who(a.user_id)} to «${a.new_tag}»`;
    case 'chatEventTitleChanged': return `changed title to «${a.new_title}»`;
    case 'chatEventDescriptionChanged': return `changed description to «${short(a.new_description)}»`;
    case 'chatEventUsernameChanged': return a.new_username ? `changed link to t.me/${a.new_username}` : 'removed the public link';
    case 'chatEventPhotoChanged': return a.new_photo ? 'changed photo' : 'removed photo';
    case 'chatEventPermissionsChanged': return 'changed default permissions';
    case 'chatEventSlowModeDelayChanged': return a.new_slow_mode_delay ? `set slow mode to ${a.new_slow_mode_delay}s` : 'disabled slow mode';
    case 'chatEventHasProtectedContentToggled': return a.has_protected_content ? 'restricted saving content' : 'allowed saving content';
    case 'chatEventInvitesToggled': return a.can_invite_users ? 'allowed members to invite' : 'restricted invites';
    case 'chatEventIsAllHistoryAvailableToggled': return a.is_all_history_available ? 'made history visible to new members' : 'hid history from new members';
    case 'chatEventSignMessagesToggled': return a.sign_messages ? 'enabled signatures' : 'disabled signatures';
    case 'chatEventInviteLinkEdited': return 'edited invite link';
    case 'chatEventInviteLinkRevoked': return 'revoked invite link';
    case 'chatEventInviteLinkDeleted': return 'deleted invite link';
    case 'chatEventVideoChatCreated': return 'started a video chat';
    case 'chatEventVideoChatEnded': return 'ended the video chat';
    case 'chatEventAvailableReactionsChanged': return 'changed reactions';
    case 'chatEventLinkedChatChanged': return 'changed the linked chat';
    default: return a['@type']?.replace(/^chatEvent/, '').replace(/([A-Z])/g, ' $1').trim().toLowerCase() ?? 'action';
  }
}

function logPage(ctx) {
  return {
    title: 'Recent actions',
    async render(body) {
      const r = await one('getChatEventLog', {
        chat_id: ctx.chatId, query: '', from_event_id: 0, limit: 100, filters: null, user_ids: [],
      });
      const events = r.events ?? [];
      const ids = [];
      for (const e of events) {
        ids.push(e.member_id?.user_id);
        for (const k of ['user_id', 'approver_user_id']) ids.push(e.action?.[k]);
        ids.push(e.action?.member_id?.user_id);
      }
      const people = await cards(ids);
      if (!events.length) return [note('No recent actions in the last 48 hours.')];
      return [note('Here are the actions made by admins and members in the last 48 hours.'),
        ...events.map((e) => {
          const card = people.get(String(e.member_id?.user_id)) ?? { title: 'Channel', color: 'a5' };
          const when = new Date(e.date * 1000).toLocaleString([], { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
          return peerRow(card, { sub: eventText(e, people), right: when });
        })];
    },
    buttons: [{ label: 'Close', run: (box) => box.pop() }],
  };
}

// ------------------------------------------------------------ вход

/** Открыть управление группой или каналом. */
export function openManage(chatId, hooks) {
  call = hooks.call;
  const box = openBox();
  box.push(mainPage(chatId));
}

/** Для ui/newchat.js: загрузка сведений и страница типа канала. */
export async function loadContext(chatId, hooks) {
  call = hooks.call;
  return load(chatId);
}
