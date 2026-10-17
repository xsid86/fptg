import { el } from '../core/dom.js';
import { emit } from '../core/bus.js';
import { setActiveChat } from '../core/store.js';
import { icon } from '../util/icons.js';
import { openMenu } from '../util/menu.js';
import { openBox, textField, photoPicker, contactPicker, note } from './tgbox.js';
import { typePage, loadContext } from './manage.js';

// «+» над списком чатов: новая группа или канал — шаги, как у Telegram
// Desktop.
//   Группа: «New group» (фото и название) -> «Add members» (контакты,
//   счётчик) -> Create.
//   Канал: «New channel» (фото, название, описание) -> Create -> «Channel
//   type» (публичный с адресом или частный по ссылке) -> «Add
//   subscribers» -> канал открывается.

let hooks = {};

const admin = (steps) => hooks.call('admin', { steps });
const photoStep = (chatId, uploadId) => ({
  key: 'photo', method: 'setChatPhoto',
  params: { chat_id: chatId, photo: { '@type': 'inputChatPhotoStatic', photo: { '@type': 'inputFileUpload', id: uploadId } } },
});

function newGroup() {
  const box = openBox();
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

function newChannel() {
  const box = openBox();
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
          // Дальше — тип канала (шаг без возврата: канал уже создан).
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

/** Кнопка «+» в шапке боковой панели (рядом со вкладками). */
export function mountNewChat(headNode, options) {
  hooks = options;
  const btn = el('button', {
    class: 'sidebar__new', type: 'button', title: 'New group or channel',
    onclick: () => openMenu(btn, [
      { label: 'New group', onSelect: newGroup },
      { label: 'New channel', onSelect: newChannel },
    ]),
  }, icon('plus'), el('span', { class: 'u-sr-only' }, 'New group or channel'));
  headNode.append(btn);
}
