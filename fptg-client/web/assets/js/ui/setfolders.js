import { el } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { openBox, section, note, linkRow, toggleRow, textField } from './tgbox.js';
import {
  load, kept, one, td, failed, saving, refresh, group, navRow, switchRow, intro, actionButton, isPremium, report,
} from './setkit.js';
import { peerCards, peerLine, chatPicker } from './setpeers.js';
import { getPref, setPref } from '../util/prefs.js';

// "Folders" — as in Telegram Desktop: own folders (dragging — the order), a
// new folder and editing it (which chats are in and which are not),
// recommended folders, coloured folder tags in the chat list (Premium).
// The folder list is the latest updateChatFolders (td.kept: TDLib has no
// getter method), the folder itself — getChatFolder.

const folderTitle = (f) => f?.name?.text?.text ?? '';

// A folder tag's colour — color_id 0..6, the same palette as names (.accent-aN).
const FOLDER_COLORS = [0, 1, 2, 3, 4, 5, 6];

const INCLUDE_TYPES = [
  ['include_contacts', 'Contacts'],
  ['include_non_contacts', 'Non-contacts'],
  ['include_groups', 'Groups'],
  ['include_channels', 'Channels'],
  ['include_bots', 'Bots'],
];
const EXCLUDE_TYPES = [
  ['exclude_muted', 'Muted'],
  ['exclude_read', 'Read'],
  ['exclude_archived', 'Archived'],
];

function emptyFolder() {
  const f = {
    '@type': 'chatFolder',
    name: { '@type': 'chatFolderName', text: { '@type': 'formattedText', text: '', entities: [] }, animate_custom_emoji: false },
    icon: { '@type': 'chatFolderIcon', name: 'Custom' },
    color_id: -1, is_shareable: false,
    pinned_chat_ids: [], included_chat_ids: [], excluded_chat_ids: [],
  };
  for (const [k] of [...INCLUDE_TYPES, ...EXCLUDE_TYPES]) f[k] = false;
  return f;
}

// ------------------------------------------------------- folder contents

function chatsPage(f, include) {
  const types = include ? INCLUDE_TYPES : EXCLUDE_TYPES;
  const listKey = include ? 'included_chat_ids' : 'excluded_chat_ids';
  return {
    title: include ? 'Included chats' : 'Excluded chats',
    async render(body, box) {
      const ids = f[listKey].map(String);
      const cards = await peerCards({ chats: ids });
      return [
        section('Chat types'),
        ...types.map(([k, label]) => toggleRow(label, !!f[k], { onChange: (v) => { f[k] = v; } }).node),
        section('Chats'),
        linkRow({
          iconName: 'plus', label: include ? 'Add chats' : 'Remove chats',
          onClick: () => box.push(addChatsPage(f, listKey)),
        }),
        ids.length ? el('div', { class: 'tgbox__list' }, ...ids.map((id) => peerLine(cards.get(`c${id}`), {
          sub: '',
          right: el('button', {
            class: 'btn btn--icon tgbox__remove', type: 'button', title: 'Remove',
            onclick: () => {
              f[listKey] = f[listKey].filter((x) => String(x) !== id);
              f.pinned_chat_ids = f.pinned_chat_ids.filter((x) => String(x) !== id);
              box.refresh();
            },
          }, icon('close')),
        }))) : note(include ? 'No chats added one by one.' : 'No chats excluded one by one.'),
      ];
    },
    buttons: [{ label: 'Done', primary: true, run: (box) => box.pop() }],
  };
}

function addChatsPage(f, listKey) {
  let picker = null;
  return {
    title: listKey === 'included_chat_ids' ? 'Add chats' : 'Exclude chats',
    render() {
      picker = chatPicker({
        kinds: ['self', 'user', 'bot', 'group', 'channel'],
        exclude: new Set([...f.included_chat_ids, ...f.excluded_chat_ids].map(String)),
      });
      return picker.nodes;
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Add', primary: true,
        run: (box) => {
          f[listKey] = [...f[listKey], ...picker.chosen().map(Number)];
          box.pop();
        },
      },
    ],
  };
}

const typesSummary = (f, types) => types.filter(([k]) => f[k]).map(([, l]) => l);

function editPage(id, f) {
  const name = textField('Folder name', folderTitle(f), { max: 12 });
  return {
    title: id ? 'Edit folder' : 'New folder',
    render(body, box) {
      const inc = [...typesSummary(f, INCLUDE_TYPES), ...(f.included_chat_ids.length ? [`${f.included_chat_ids.length} chats`] : [])];
      const exc = [...typesSummary(f, EXCLUDE_TYPES), ...(f.excluded_chat_ids.length ? [`${f.excluded_chat_ids.length} chats`] : [])];
      const colors = el('div', { class: 'tgbox__colors' },
        el('button', {
          class: `tgbox__color is-none${f.color_id < 0 ? ' is-active' : ''}`, type: 'button', title: 'No color',
          disabled: !isPremium(),
          onclick: () => { f.color_id = -1; box.refresh(); },
        }, icon('block')),
        ...FOLDER_COLORS.map((c) => el('button', {
          class: `tgbox__color accent-a${c}${f.color_id === c ? ' is-active' : ''}`, type: 'button',
          disabled: !isPremium(),
          onclick: () => { f.color_id = c; box.refresh(); },
        })));
      return [
        name.node,
        section('Included chats'),
        linkRow({ iconName: 'plus', label: 'Included chats', value: inc.join(', ') || 'None', onClick: () => box.push(chatsPage(f, true)) }),
        note('Choose chats or types of chats that will appear in this folder.'),
        section('Excluded chats'),
        linkRow({ iconName: 'close', label: 'Excluded chats', value: exc.join(', ') || 'None', onClick: () => box.push(chatsPage(f, false)) }),
        note('Choose chats or types of chats that will never appear in this folder.'),
        section(isPremium() ? 'Folder color' : 'Folder color (Premium)'),
        colors,
        note('This color is shown on the folder’s tag in the chat list.'),
      ];
    },
    buttons: [
      ...(id ? [{
        label: 'Delete', danger: true,
        async run(box) {
          await one('deleteChatFolder', { chat_folder_id: id, leave_chat_ids: [] });
          box.close();
          refresh();
        },
      }] : []),
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          const title = name.input.value.trim();
          if (!title) throw new Error('Enter a folder name.');
          f.name.text.text = title;
          f.name.text.entities = [];
          const empty = !f.included_chat_ids.length && !typesSummary(f, INCLUDE_TYPES).length;
          if (empty) throw new Error('Add at least one chat or chat type to the folder.');
          if (id) await one('editChatFolder', { chat_folder_id: id, folder: f });
          else await one('createChatFolder', { folder: f });
          box.close();
          refresh();
        },
      },
    ],
  };
}

async function openFolder(id) {
  const f = id ? await one('getChatFolder', { chat_folder_id: id }) : emptyFolder();
  openBox().push(editPage(id, f));
}

// --------------------------------------------------- folder order

/** Dragging folder rows: released — reorderChatFolders. */
function sortable(list, ids, position) {
  let dragged = null;
  for (const node of list.children) {
    node.draggable = true;
    node.addEventListener('dragstart', (e) => {
      dragged = node;
      node.classList.add('is-dragging');
      e.dataTransfer.effectAllowed = 'move';
    });
    node.addEventListener('dragend', () => {
      node.classList.remove('is-dragging');
      dragged = null;
    });
    node.addEventListener('dragover', (e) => {
      if (!dragged || dragged === node) return;
      e.preventDefault();
      const r = node.getBoundingClientRect();
      const after = e.clientY > r.top + r.height / 2;
      node.parentNode.insertBefore(dragged, after ? node.nextSibling : node);
    });
    node.addEventListener('drop', (e) => {
      e.preventDefault();
      const order = [...list.children].map((n) => Number(n.dataset.folder));
      if (order.join() === ids.join()) return;
      saving(() => one('reorderChatFolders', { chat_folder_ids: order, main_chat_list_position: position }));
    });
  }
}

// ----------------------------------------------------------- section

export async function renderFolders() {
  const [k, rec] = await Promise.all([
    kept(['updateChatFolders']).catch(() => ({})),
    td([{ key: 'r', method: 'getRecommendedChatFolders', soft: true }]).then((a) => a.r),
  ]);
  const info = k.updateChatFolders ?? { chat_folders: [], main_chat_list_position: 0, are_tags_enabled: false };
  const folders = info.chat_folders ?? [];
  const ids = folders.map((f) => f.id);
  const list = el('div', { class: 'settings__sortable' }, ...folders.map((f) => {
    const node = navRow({
      iconName: 'folder', label: folderTitle(f),
      hint: f.is_shareable ? 'Shared folder' : '',
      onClick: () => openFolder(f.id).catch(report),
    });
    node.dataset.folder = String(f.id);
    if (f.color_id >= 0 && info.are_tags_enabled) {
      node.querySelector('.settings__nav-value').append(el('span', { class: `settings__dot accent-a${f.color_id}` }));
    }
    return node;
  }));
  if (folders.length > 1) sortable(list, ids, info.main_chat_list_position ?? 0);
  const recommended = failed(rec) ? [] : (rec.chat_folders ?? []);
  return [
    intro('Create folders for different groups of chats and quickly switch between them.'),
    group('My folders',
      navRow({ iconName: 'plus', label: 'Create new folder', onClick: () => openFolder(0).catch(report) }),
      folders.length ? list : null,
      folders.length > 1 ? el('p', { class: 'settings__hint' }, 'Drag a folder to change the order.') : null),
    recommended.length ? group('Recommended folders',
      ...recommended.map((r) => el('div', { class: 'settings__row' },
        el('div', { class: 'settings__text' },
          el('span', { class: 'settings__label' }, folderTitle(r.folder)),
          el('p', { class: 'settings__hint' }, r.description)),
        el('div', { class: 'settings__control' },
          actionButton('Add', () => saving(() => one('createChatFolder', { folder: r.folder })), { primary: true }))))) : null,
    // Folder chips in the rows are ours, local (util/prefs.js); with Premium
    // also the account's folder tags (the official clients show them).
    group('Folder tags',
      switchRow('Show folder tags', 'Display folder names for each chat in the chat list.',
        getPref('folderTags'),
        (v) => {
          setPref('folderTags', v);
          if (isPremium() && v !== !!info.are_tags_enabled) {
            saving(() => one('toggleChatFolderTags', { are_tags_enabled: v }), { redraw: false });
          }
        })),
  ].filter(Boolean);
}
