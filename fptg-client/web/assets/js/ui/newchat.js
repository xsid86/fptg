import { el } from '../core/dom.js';
import { emit, on } from '../core/bus.js';
import { store, setActiveChat } from '../core/store.js';
import { icon } from '../util/icons.js';
import { openBox, textField, photoPicker, contactPicker, note, linkRow } from './tgbox.js';
import { typePage, loadContext } from './manage.js';

// "+" above the chat list: a dialog with New group, New channel and New
// bot; the choice goes on in the same dialog — steps as in Telegram Desktop.
//   Group: "New group" (photo and title) -> "Add members" (contacts, a
//   counter) -> Create.
//   Channel: "New channel" (photo, title, description) -> Create -> "Channel
//   type" (public with an address or private by a link) -> "Add
//   subscribers" -> the channel opens.
//   Bot: "New bot" -> the chat with @BotFather and /newbot to it — it starts
//   the bot creation dialogue.

let hooks = {};

const admin = (steps) => hooks.call('admin', { steps });
const photoStep = (chatId, uploadId) => ({
  key: 'photo', method: 'setChatPhoto',
  params: { chat_id: chatId, photo: { '@type': 'inputChatPhotoStatic', photo: { '@type': 'inputFileUpload', id: uploadId } } },
});

export function newGroup(box = openBox()) {
  let name = null;
  let photo = null;
  box.push({
    title: 'New group',
    render() {
      photo = photo ?? photoPicker();
      name = textField('Group name', name?.input.value ?? '', { max: 128 });
      return el('div', { class: 'tgbox__info' }, photo.node, el('div', { class: 'tgbox__info-fields' }, name.node));
    },
    buttons: [
      { label: 'Cancel', run: () => box.close() },
      {
        label: 'Next', primary: true,
        run() {
          const title = name.input.value.trim();
          if (!title) throw new Error('Enter a group name');
          box.push(membersStep(box, title, photo));
        },
      },
    ],
  });
}

function membersStep(box, title, photo) {
  let picker = null;
  return {
    title: 'Add members',
    async render() {
      picker = await contactPicker(hooks.call);
      return picker.nodes;
    },
    buttons: [
      { label: 'Back', run: () => box.pop() },
      {
        label: 'Create', primary: true,
        async run() {
          const ids = picker.chosen().map(Number);
          const { created } = await admin([{
            key: 'created', method: 'createNewBasicGroupChat',
            params: { user_ids: ids, title, message_auto_delete_time: 0 },
          }]);
          const chatId = created.chat_id;
          const uploadId = await photo.upload();
          if (uploadId) await admin([photoStep(chatId, uploadId)]).catch(() => {});
          const failed = created.failed_to_add_members?.failed_to_add_members?.length ?? 0;
          if (failed) emit('ui:notice', `${failed} could not be added: their privacy settings do not allow it`);
          box.close();
          setActiveChat(chatId);
        },
      },
    ],
  };
}

export function newChannel(box = openBox()) {
  let name = null;
  let about = null;
  let photo = null;
  box.push({
    title: 'New channel',
    render() {
      photo = photo ?? photoPicker();
      name = textField('Channel name', name?.input.value ?? '', { max: 128 });
      about = textField('Description (optional)', about?.input.value ?? '', { multiline: true, max: 255 });
      return [
        el('div', { class: 'tgbox__info' }, photo.node, el('div', { class: 'tgbox__info-fields' }, name.node)),
        about.node,
        note('You can provide an optional description for your channel.'),
      ];
    },
    buttons: [
      { label: 'Cancel', run: () => box.close() },
      {
        label: 'Create', primary: true,
        async run() {
          const title = name.input.value.trim();
          if (!title) throw new Error('Enter a channel name');
          const { chat } = await admin([{
            key: 'chat', method: 'createNewSupergroupChat',
            params: {
              title, is_forum: false, is_channel: true, description: about.input.value,
              location: null, message_auto_delete_time: 0, for_import: false,
            },
          }]);
          const uploadId = await photo.upload();
          if (uploadId) await admin([photoStep(chat.id, uploadId)]).catch(() => {});
          // Next — the channel type (a step without return: the channel is created already).
          const ctx = await loadContext(chat.id, hooks);
          const finish = (b) => b.replace(subscribersStep(b, chat.id));
          box.replace(typePage(ctx, { after: finish }));
        },
      },
    ],
  });
}

function subscribersStep(box, chatId) {
  let picker = null;
  const done = () => {
    box.close();
    setActiveChat(chatId);
  };
  return {
    title: 'Add subscribers',
    async render() {
      picker = await contactPicker(hooks.call);
      return picker.nodes;
    },
    buttons: [
      { label: 'Skip', run: done },
      {
        label: 'Add', primary: true,
        async run() {
          const ids = picker.chosen().map(Number);
          if (ids.length) {
            const { r } = await admin([{ key: 'r', method: 'addChatMembers', params: { chat_id: chatId, user_ids: ids } }]);
            const failed = r?.failed_to_add_members?.length ?? 0;
            if (failed) emit('ui:notice', `${failed} could not be added: their privacy settings do not allow it`);
          }
          done();
        },
      },
    ],
  };
}

// How long to wait for the BotFather chat to open before giving up.
const BOTFATHER_OPEN_MS = 10000;

/**
 * New bot: open @BotFather and send it /newbot. The command goes to the open
 * chat (message.send), hence — when its history has arrived.
 */
async function newBot() {
  let target;
  try {
    target = await hooks.call('link.resolve', { url: 'https://t.me/BotFather' });
  } catch (error) {
    hooks.report(error);
    return;
  }
  const chatId = target?.chatId;
  if (!chatId) return;
  const ready = new Promise((resolve) => {
    let off = null;
    const timer = setTimeout(() => { off?.(); resolve(false); }, BOTFATHER_OPEN_MS);
    off = on('store:messages', () => {
      if (store.activeChatId !== chatId) return;
      clearTimeout(timer);
      off();
      resolve(true);
    });
  });
  setActiveChat(chatId);
  if (!(await ready)) return;
  try {
    await hooks.call('message.send', { text: '/newbot', entities: [] });
  } catch (error) {
    hooks.report(error);
  }
}

/** What "+" opens: the three kinds of a new chat. */
function chooseNew() {
  const box = openBox();
  box.push({
    title: 'New',
    render: () => [
      linkRow({ iconName: 'group', label: 'New group', onClick: () => newGroup(box) }),
      linkRow({ iconName: 'channel', label: 'New channel', onClick: () => newChannel(box) }),
      linkRow({
        iconName: 'bot', label: 'New bot',
        onClick: () => {
          box.close();
          newBot().catch(console.error);
        },
      }),
    ],
    buttons: [{ label: 'Cancel', run: () => box.close() }],
  });
}

/** The "+" button in the side panel's header. */
export function mountNewChat(headNode, options) {
  hooks = options;
  if (!hooks.report) hooks.report = (error) => emit('ui:error', error?.message || String(error));
  const btn = el('button', {
    class: 'sidebar__new', type: 'button', title: 'New group, channel or bot',
    onclick: chooseNew,
  }, icon('plus'), el('span', { class: 'u-sr-only' }, 'New group, channel or bot'));
  headNode.append(btn);
}
