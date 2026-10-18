import { el } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { openBox, section, note, linkRow, toggleRow, radioGroup, textField } from './tgbox.js';
import {
  one, td, failed, saving, refresh, group, navRow, switchRow, intro,
  periodLabel, dateTime, isPremium,
} from './setkit.js';
import { peerCards, peerLine, chatPicker, chatKind } from './setpeers.js';

// "Privacy and security" — as in Telegram Desktop: security (the block
// list, sessions, the cloud password, auto-delete), privacy (who sees the
// number, last seen, the photo…; every rule has "always" and "never"
// exceptions), websites, frequent contacts, deleting the account.
//
// Everything is TDLib directly (admin; td_api.tl of commit d1085f9) and anew
// on every opening of the section: it changes from the phone too.

// Privacy rules in Desktop's order. who — the question in the rule's window.
const RULES = [
  { setting: 'userPrivacySettingShowPhoneNumber', label: 'Phone number', who: 'Who can see my phone number',
    about: 'Users who have your number saved in their contacts will also see it on Telegram.' },
  { setting: 'userPrivacySettingShowStatus', label: 'Last seen & online', who: 'Who can see my last seen time',
    about: 'You won’t see last seen and online statuses for people with whom you don’t share yours. '
      + 'Approximate last seen will be shown instead (recently, within a week, within a month).' },
  { setting: 'userPrivacySettingShowProfilePhoto', label: 'Profile photos', who: 'Who can see my profile photos',
    about: 'Choose who can see your profile photos.' },
  { setting: 'userPrivacySettingShowProfileAudio', label: 'Profile audio', who: 'Who can see my profile audio',
    about: 'Choose who can listen to the audio files on your profile.' },
  { setting: 'userPrivacySettingShowBio', label: 'Bio', who: 'Who can see my bio',
    about: 'Choose who can see the bio in your profile.' },
  { setting: 'userPrivacySettingShowBirthdate', label: 'Date of birth', who: 'Who can see my date of birth',
    about: 'Choose who can see your date of birth in your profile.' },
  { setting: 'userPrivacySettingAutosaveGifts', label: 'Gifts', who: 'Who can display gifts on my profile',
    about: 'Choose whether gifts from these people are shown on your profile.' },
  { setting: 'userPrivacySettingShowLinkInForwardedMessages', label: 'Forwarded messages',
    who: 'Who can add a link to my account when forwarding my messages',
    about: 'Messages you send will not link back to your account when forwarded by people outside this list.' },
  { setting: 'userPrivacySettingAllowCalls', label: 'Calls', who: 'Who can call me',
    about: 'You can restrict who can call you with granular precision.' },
  { setting: 'userPrivacySettingAllowPrivateVoiceAndVideoNoteMessages', label: 'Voice messages',
    who: 'Who can send me voice or video messages', premium: true,
    about: 'Choose who can send you voice and video messages.' },
  { messages: true, label: 'Messages', premium: true },
  { setting: 'userPrivacySettingAllowChatInvites', label: 'Invites', who: 'Who can add me to group chats',
    about: 'You can restrict who can add you to groups and channels with granular precision.' },
];
const FIND_BY_PHONE = 'userPrivacySettingAllowFindingByPhoneNumber';
const P2P_CALLS = 'userPrivacySettingAllowPeerToPeerCalls';

const BASES = [
  { value: 'everybody', label: 'Everybody' },
  { value: 'contacts', label: 'My contacts' },
  { value: 'nobody', label: 'Nobody' },
];
const BASE_LABEL = Object.fromEntries(BASES.map((b) => [b.value, b.label]));

// The default auto-delete and the account inactivity period — as in Desktop.
const DAY = 86400;
const AUTO_DELETE = [0, DAY, 7 * DAY, 31 * DAY];
const ACCOUNT_TTL = [30, 90, 180, 365, 548, 730];
const SESSION_TTL = [7, 30, 90, 183, 365];
const ttlLabel = (days) => {
  if (days % 365 === 0) return `${days / 365} year${days === 365 ? '' : 's'}`;
  if (days >= 30) return `${Math.round(days / 30.4)} months`.replace(/^1 months/, '1 month');
  return days === 7 ? '1 week' : `${days} days`;
};

// ------------------------------------------------------------ rules

/** TDLib rules -> { base, allowUsers, allowChats, denyUsers, denyChats, premium, bots }. */
export function parseRules(rules) {
  const r = { base: 'nobody', allowUsers: [], allowChats: [], denyUsers: [], denyChats: [], premium: false, bots: false, botsDeny: false };
  let based = false;
  for (const rule of rules?.rules ?? []) {
    switch (rule['@type']) {
      case 'userPrivacySettingRuleAllowAll': if (!based) { r.base = 'everybody'; based = true; } break;
      case 'userPrivacySettingRuleAllowContacts': if (!based) { r.base = 'contacts'; based = true; } break;
      case 'userPrivacySettingRuleRestrictAll': if (!based) { r.base = 'nobody'; based = true; } break;
      case 'userPrivacySettingRuleAllowUsers': r.allowUsers.push(...rule.user_ids.map(String)); break;
      case 'userPrivacySettingRuleAllowChatMembers': r.allowChats.push(...rule.chat_ids.map(String)); break;
      case 'userPrivacySettingRuleRestrictUsers': r.denyUsers.push(...rule.user_ids.map(String)); break;
      case 'userPrivacySettingRuleRestrictChatMembers': r.denyChats.push(...rule.chat_ids.map(String)); break;
      case 'userPrivacySettingRuleAllowPremiumUsers': r.premium = true; break;
      case 'userPrivacySettingRuleAllowBots': r.bots = true; break;
      case 'userPrivacySettingRuleRestrictBots': r.botsDeny = true; break;
      default: break;
    }
  }
  return r;
}

/** Back into userPrivacySettingRules: the exceptions, then the main one. */
function buildRules(r) {
  const rules = [];
  const ids = (a) => a.map(Number);
  if (r.base !== 'everybody') {
    if (r.allowUsers.length) rules.push({ '@type': 'userPrivacySettingRuleAllowUsers', user_ids: ids(r.allowUsers) });
    if (r.allowChats.length) rules.push({ '@type': 'userPrivacySettingRuleAllowChatMembers', chat_ids: ids(r.allowChats) });
    if (r.premium) rules.push({ '@type': 'userPrivacySettingRuleAllowPremiumUsers' });
    if (r.bots) rules.push({ '@type': 'userPrivacySettingRuleAllowBots' });
  }
  if (r.base !== 'nobody') {
    if (r.denyUsers.length) rules.push({ '@type': 'userPrivacySettingRuleRestrictUsers', user_ids: ids(r.denyUsers) });
    if (r.denyChats.length) rules.push({ '@type': 'userPrivacySettingRuleRestrictChatMembers', chat_ids: ids(r.denyChats) });
    if (r.botsDeny) rules.push({ '@type': 'userPrivacySettingRuleRestrictBots' });
  }
  rules.push({
    '@type': {
      everybody: 'userPrivacySettingRuleAllowAll',
      contacts: 'userPrivacySettingRuleAllowContacts',
      nobody: 'userPrivacySettingRuleRestrictAll',
    }[r.base],
  });
  return { '@type': 'userPrivacySettingRules', rules };
}

const allowCount = (r) => r.allowUsers.length + r.allowChats.length;
const denyCount = (r) => r.denyUsers.length + r.denyChats.length;

/** "My contacts (−2, +3)" — like the rule's label in Desktop. */
function summary(r) {
  const parts = [];
  if (r.base !== 'nobody' && denyCount(r)) parts.push(`−${denyCount(r)}`);
  if (r.base !== 'everybody' && allowCount(r)) parts.push(`+${allowCount(r)}`);
  return BASE_LABEL[r.base] + (parts.length ? ` (${parts.join(', ')})` : '');
}

const setting = (type) => ({ '@type': type });
const getRules = (type) => one('getUserPrivacySettingRules', { setting: setting(type) });
const setRules = (type, r) => one('setUserPrivacySettingRules', { setting: setting(type), rules: buildRules(r) });

// ------------------------------------------------------- exceptions

/** The exceptions page: a list with "Remove" and "Add users or groups". */
function exceptionsPage(title, users, chats, { onlyUsers = false } = {}) {
  return {
    title,
    async render(body, box) {
      const cards = await peerCards({ users, chats });
      const lines = [
        ...users.map((id) => ({ id, card: cards.get(`u${id}`), list: users })),
        ...chats.map((id) => ({ id, card: cards.get(`c${id}`), list: chats })),
      ].map(({ id, card, list }) => peerLine(card, {
        right: el('button', {
          class: 'btn btn--icon tgbox__remove', type: 'button', title: 'Remove',
          onclick: () => {
            list.splice(list.indexOf(id), 1);
            box.refresh();
          },
        }, icon('close')),
      }));
      return [
        linkRow({
          iconName: 'plus', label: onlyUsers ? 'Add users' : 'Add users or groups',
          onClick: () => box.push(pickPage(users, chats, onlyUsers)),
        }),
        lines.length ? el('div', { class: 'tgbox__list' }, ...lines) : note('No exceptions yet.'),
      ];
    },
    buttons: [{ label: 'Done', primary: true, run: (box) => box.pop() }],
  };
}

function pickPage(users, chats, onlyUsers) {
  let picker = null;
  return {
    title: 'Add exceptions',
    render() {
      const kinds = onlyUsers ? ['user', 'bot'] : ['user', 'bot', 'group'];
      picker = chatPicker({ kinds, exclude: new Set([...users, ...chats]) });
      return picker.nodes;
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Add', primary: true,
        run: (box) => {
          for (const id of picker.chosen()) {
            if (chatKind(id) === 'group') chats.push(id);
            else users.push(id);
          }
          box.pop();
        },
      },
    ],
  };
}

// ------------------------------------------------------ the rule's window

function rulePage(def, rules, extra = {}) {
  const draft = structuredClone(rules[def.setting]);
  const sub = extra.sub ? structuredClone(rules[extra.sub.setting]) : null;
  let hideRead = extra.readDate ? !extra.readDate.show_read_date : false;
  const name = `rule-${def.setting}`;
  return {
    title: def.label,
    render(body, box) {
      const nodes = [
        section(def.who),
        radioGroup(name, BASES, draft.base, (v) => { draft.base = v; box.refresh(); }).node,
        note(def.about),
      ];
      // The number is hidden — who can find me by number (Desktop: under the main choice).
      if (sub && extra.sub.when(draft)) {
        nodes.push(section(extra.sub.who),
          radioGroup(`${name}-sub`, extra.sub.options, sub.base, (v) => { sub.base = v; }).node);
      }
      if (extra.readDate) {
        const t = toggleRow('Hide read time', hideRead, {
          sub: 'Your read time won’t be shown to people you hide your last seen from, '
            + 'and you won’t see theirs.',
          onChange: (v) => { hideRead = v; },
        });
        nodes.push(t.node);
      }
      nodes.push(section('Exceptions'));
      if (draft.base !== 'everybody') {
        nodes.push(linkRow({
          label: 'Always share with', value: allowCount(draft) ? String(allowCount(draft)) : 'Add users',
          onClick: () => box.push(exceptionsPage('Always share with', draft.allowUsers, draft.allowChats)),
        }));
      }
      if (draft.base !== 'nobody') {
        nodes.push(linkRow({
          label: 'Never share with', value: denyCount(draft) ? String(denyCount(draft)) : 'Add users',
          onClick: () => box.push(exceptionsPage('Never share with', draft.denyUsers, draft.denyChats)),
        }));
      }
      nodes.push(note('You can add users or entire groups as exceptions that will override the settings above.'));
      if (extra.p2p) {
        nodes.push(section('Peer-to-peer'), linkRow({
          label: 'Use peer-to-peer with', value: summary(rules[P2P_CALLS]),
          onClick: () => box.push(rulePage({
            setting: P2P_CALLS, label: 'Peer-to-peer', who: 'Use peer-to-peer with',
            about: 'Disabling peer-to-peer will relay all calls through Telegram servers to avoid '
              + 'revealing your IP address, but may slightly decrease audio quality.',
          }, rules, { nested: true })),
        }));
      }
      return nodes;
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          await setRules(def.setting, draft);
          rules[def.setting] = draft;
          if (sub) await setRules(extra.sub.setting, sub);
          if (extra.readDate && hideRead === extra.readDate.show_read_date) {
            await one('setReadDatePrivacySettings', {
              settings: { '@type': 'readDatePrivacySettings', show_read_date: !hideRead },
            });
          }
          if (extra.nested) box.pop();
          else box.close();
          refresh();
        },
      },
    ],
  };
}

function openRule(def, state) {
  const extra = {};
  if (def.setting === 'userPrivacySettingShowPhoneNumber') {
    extra.sub = {
      setting: FIND_BY_PHONE, who: 'Who can find me by my number',
      options: BASES.slice(0, 2), when: (d) => d.base !== 'everybody',
    };
  }
  if (def.setting === 'userPrivacySettingShowStatus') extra.readDate = state.readDate;
  if (def.setting === 'userPrivacySettingAllowCalls') extra.p2p = true;
  openBox().push(rulePage(def, state.rules, extra));
}

function openMessages(state) {
  const cur = state.newChat;
  let value = cur.allow_new_chats_from_unknown_users ? 'everybody' : 'contacts';
  openBox().push({
    title: 'Messages',
    render: (body, box) => [
      section('Who can send me messages'),
      radioGroup('new-chats', [
        { value: 'everybody', label: 'Everybody' },
        { value: 'contacts', label: 'My contacts and Premium users' },
      ], value, (v) => { value = v; }).node,
      note('You can restrict incoming messages to only contacts and Premium users.'),
    ],
    buttons: [
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          await one('setNewChatPrivacySettings', {
            settings: {
              '@type': 'newChatPrivacySettings',
              allow_new_chats_from_unknown_users: value === 'everybody',
              incoming_paid_message_star_count: cur.incoming_paid_message_star_count ?? 0,
            },
          });
          box.close();
          refresh();
        },
      },
    ],
  });
}

// ----------------------------------------------------- block list

function openBlocked() {
  const box = openBox();
  box.push({
    title: 'Blocked users',
    async render(body, b) {
      const answer = await one('getBlockedMessageSenders', {
        block_list: { '@type': 'blockListMain' }, offset: 0, limit: 100,
      });
      const senders = answer.senders ?? [];
      const users = senders.filter((s) => s['@type'] === 'messageSenderUser').map((s) => String(s.user_id));
      const chats = senders.filter((s) => s['@type'] === 'messageSenderChat').map((s) => String(s.chat_id));
      const cards = await peerCards({ users, chats });
      const unblock = (sender) => el('button', {
        class: 'btn tgbox__act', type: 'button',
        onclick: async () => {
          await one('setMessageSenderBlockList', { sender_id: sender, block_list: null });
          b.refresh();
          refresh();
        },
      }, 'Unblock');
      const lines = senders.map((s) => {
        const card = s['@type'] === 'messageSenderUser' ? cards.get(`u${s.user_id}`) : cards.get(`c${s.chat_id}`);
        return peerLine(card, { right: unblock(s) });
      });
      return [
        linkRow({ iconName: 'plus', label: 'Block user', onClick: () => b.push(blockPickPage(new Set([...users, ...chats]))) }),
        note('Blocked users can’t send you messages or add you to groups. They will not see your profile '
          + 'photos, stories, online and last seen status.'),
        lines.length ? el('div', { class: 'tgbox__list' }, ...lines) : note('No blocked users.'),
      ];
    },
    buttons: [{ label: 'Close', run: (b) => b.close() }],
  });
}

function blockPickPage(exclude) {
  let picker = null;
  return {
    title: 'Block user',
    render() {
      picker = chatPicker({ kinds: ['user', 'bot'], exclude });
      return picker.nodes;
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Block', primary: true, danger: true,
        async run(box) {
          for (const id of picker.chosen()) {
            await one('setMessageSenderBlockList', {
              sender_id: { '@type': 'messageSenderUser', user_id: Number(id) },
              block_list: { '@type': 'blockListMain' },
            });
          }
          box.pop();
          refresh();
        },
      },
    ],
  };
}

// --------------------------------------------------------- sessions

function sessionTitle(s) {
  return `${s.application_name} ${s.application_version}`.trim();
}

function sessionSub(s) {
  const device = [s.device_model, [s.platform, s.system_version].filter(Boolean).join(' ')].filter(Boolean).join(', ');
  const where = [s.ip_address, s.location].filter(Boolean).join(' – ');
  return [device, where].filter(Boolean).join(' · ');
}

function sessionLine(s, onClick) {
  const when = s.is_current ? 'online' : dateTime(s.last_active_date);
  return el('button', { class: 'tgbox__peer tgbox__session', type: 'button', onclick: onClick },
    el('span', { class: 'avatar tgbox__avatar tgbox__device' }, icon('devices')),
    el('span', { class: 'tgbox__toggle-text' },
      el('span', { class: 'tgbox__row-label' }, sessionTitle(s)),
      el('span', { class: 'tgbox__row-sub' }, sessionSub(s))),
    el('span', { class: `tgbox__row-value${s.is_current ? ' is-online' : ''}` }, when));
}

function sessionPage(s) {
  return {
    title: sessionTitle(s),
    render: () => {
      const calls = toggleRow('Accept calls', s.can_accept_calls, {
        onChange: (v) => saving(() => one('toggleSessionCanAcceptCalls', { session_id: s.id, can_accept_calls: v }), { redraw: false }),
      });
      const secret = toggleRow('Accept secret chats', s.can_accept_secret_chats, {
        onChange: (v) => saving(() => one('toggleSessionCanAcceptSecretChats', { session_id: s.id, can_accept_secret_chats: v }), { redraw: false }),
      });
      const detail = (label, value) => (value ? el('div', { class: 'tgbox__detail' },
        el('span', { class: 'tgbox__row-sub' }, label), el('span', {}, value)) : null);
      return [
        detail('Application', sessionTitle(s)),
        detail('Device', [s.device_model, s.platform, s.system_version].filter(Boolean).join(', ')),
        detail('IP address', s.ip_address),
        detail('Location', s.location),
        detail('Logged in', dateTime(s.log_in_date)),
        detail('Last active', s.is_current ? 'online' : dateTime(s.last_active_date)),
        section('Accept on this device'),
        calls.node,
        secret.node,
      ];
    },
    buttons: s.is_current ? [{ label: 'Back', run: (box) => box.pop() }] : [
      { label: 'Back', run: (box) => box.pop() },
      {
        label: 'Terminate session', danger: true,
        async run(box) {
          await one('terminateSession', { session_id: s.id });
          box.pop();
          refresh();
        },
      },
    ],
  };
}

function openSessions() {
  openBox().push({
    title: 'Active sessions',
    async render(body, box) {
      const answer = await one('getActiveSessions');
      const all = answer.sessions ?? [];
      const current = all.find((s) => s.is_current);
      const others = all.filter((s) => !s.is_current).sort((a, b) => b.last_active_date - a.last_active_date);
      const ttl = answer.inactive_session_ttl_days;
      return [
        section('Current session'),
        current ? sessionLine(current, () => box.push(sessionPage(current))) : null,
        others.length ? linkRow({
          label: 'Terminate all other sessions', danger: true,
          onClick: async () => {
            await one('terminateAllOtherSessions');
            box.refresh();
            refresh();
          },
        }) : null,
        note('Logs out all devices except for this one.'),
        section('Automatically terminate old sessions'),
        radioGroup('session-ttl', SESSION_TTL.map((d) => ({ value: String(d), label: `If inactive for ${ttlLabel(d)}` })),
          String(ttl), (v) => saving(() => one('setInactiveSessionTtl', { inactive_session_ttl_days: Number(v) }), { redraw: false })).node,
        others.length ? section('Active sessions') : null,
        ...others.map((s) => sessionLine(s, () => box.push(sessionPage(s)))),
      ];
    },
    buttons: [{ label: 'Close', run: (box) => box.close() }],
  });
}

// ---------------------------------------------------------- websites

function openWebsites() {
  openBox().push({
    title: 'Logged in with Telegram',
    async render(body, box) {
      const answer = await one('getConnectedWebsites');
      const sites = answer.websites ?? [];
      return [
        sites.length ? linkRow({
          label: 'Disconnect all websites', danger: true,
          onClick: async () => {
            await one('disconnectAllWebsites');
            box.refresh();
            refresh();
          },
        }) : null,
        note('You can log in on websites that support signing in with Telegram.'),
        ...sites.map((w) => el('div', { class: 'tgbox__peer' },
          el('span', { class: 'avatar tgbox__avatar tgbox__device' }, icon('globe')),
          el('span', { class: 'tgbox__toggle-text' },
            el('span', { class: 'tgbox__row-label' }, w.domain_name),
            el('span', { class: 'tgbox__row-sub' },
              [w.browser, w.platform, w.ip_address, w.location, dateTime(w.last_active_date)].filter(Boolean).join(' · '))),
          el('button', {
            class: 'btn tgbox__act', type: 'button',
            onclick: async () => {
              await one('disconnectWebsite', { website_id: w.id });
              box.refresh();
              refresh();
            },
          }, 'Disconnect'))),
        sites.length ? null : note('No connected websites.'),
      ];
    },
    buttons: [{ label: 'Close', run: (box) => box.close() }],
  });
}

// ------------------------------------------------------ cloud password

function openPassword(state) {
  const has = state.has_password;
  const box = openBox();
  const form = (withOld) => {
    const old = withOld ? textField('Current password') : null;
    const next = textField('New password');
    const again = textField('Re-enter new password');
    const hint = textField('Password hint', has ? state.password_hint : '');
    for (const f of [old, next, again].filter(Boolean)) f.input.type = 'password';
    return { old, next, again, hint };
  };
  box.push({
    title: 'Two-step verification',
    render: (body, b) => {
      if (!has) {
        return [
          note('You can set a password that will be required when you log in on a new device '
            + 'in addition to the code you get in the SMS.'),
          linkRow({ iconName: 'lock', label: 'Set password', onClick: () => b.push(passwordPage(false, form(false))) }),
        ];
      }
      return [
        note('Two-step verification is enabled. Your account is protected with an additional password.'),
        state.password_hint ? el('div', { class: 'tgbox__detail' },
          el('span', { class: 'tgbox__row-sub' }, 'Hint'), el('span', {}, state.password_hint)) : null,
        state.has_recovery_email_address ? note('A recovery email is set.') : note('No recovery email is set.'),
        state.login_email_address_pattern ? el('div', { class: 'tgbox__detail' },
          el('span', { class: 'tgbox__row-sub' }, 'Login email'), el('span', {}, state.login_email_address_pattern)) : null,
        linkRow({ iconName: 'lock', label: 'Change password', onClick: () => b.push(passwordPage(true, form(true))) }),
        linkRow({ label: 'Turn off', danger: true, onClick: () => b.push(passwordOffPage()) }),
      ];
    },
    buttons: [{ label: 'Close', run: (b) => b.close() }],
  });
}

function passwordPage(change, f) {
  return {
    title: change ? 'Change password' : 'Set password',
    render: () => [f.old?.node, f.next.node, f.again.node, f.hint.node,
      note('The hint is shown when you are asked for the password. Don’t use the password itself.')],
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Save', primary: true,
        async run(box) {
          if (!f.next.input.value) throw new Error('Enter a new password.');
          if (f.next.input.value !== f.again.input.value) throw new Error('Passwords don’t match.');
          await one('setPassword', {
            old_password: f.old?.input.value ?? '', new_password: f.next.input.value,
            new_hint: f.hint.input.value, set_recovery_email_address: false, new_recovery_email_address: '',
          });
          box.close();
          refresh();
        },
      },
    ],
  };
}

function passwordOffPage() {
  const old = textField('Current password');
  old.input.type = 'password';
  return {
    title: 'Turn off two-step verification',
    render: () => [note('Are you sure you want to disable your password?'), old.node],
    buttons: [
      { label: 'Cancel', run: (box) => box.pop() },
      {
        label: 'Turn off', danger: true,
        async run(box) {
          await one('setPassword', {
            old_password: old.input.value, new_password: '', new_hint: '',
            set_recovery_email_address: false, new_recovery_email_address: '',
          });
          box.close();
          refresh();
        },
      },
    ],
  };
}

// ------------------------------------------- choice from a list (timers)

function openChoice({ title, about, options, value, save }) {
  let chosen = String(value);
  openBox().push({
    title,
    render: () => [
      radioGroup(`choice-${title}`, options.map((o) => ({ value: String(o.value), label: o.label })), chosen,
        (v) => { chosen = v; }).node,
      about ? note(about) : null,
    ],
    buttons: [
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Save', primary: true,
        async run(box) {
          await save(chosen);
          box.close();
          refresh();
        },
      },
    ],
  });
}

// ----------------------------------------------------------- section

async function loadState() {
  const soft = (p) => p.catch(() => null);
  const ruleTypes = [...RULES.filter((r) => r.setting).map((r) => r.setting), FIND_BY_PHONE, P2P_CALLS];
  const [ruleAnswers, extra] = await Promise.all([
    Promise.all(ruleTypes.map((t) => soft(getRules(t)))),
    td([
      { key: 'readDate', method: 'getReadDatePrivacySettings', soft: true },
      { key: 'newChat', method: 'getNewChatPrivacySettings', soft: true },
      { key: 'blocked', method: 'getBlockedMessageSenders', params: { block_list: { '@type': 'blockListMain' }, offset: 0, limit: 1 }, soft: true },
      { key: 'sessions', method: 'getActiveSessions', soft: true },
      { key: 'password', method: 'getPasswordState', soft: true },
      { key: 'websites', method: 'getConnectedWebsites', soft: true },
      { key: 'autoDelete', method: 'getDefaultMessageAutoDeleteTime', soft: true },
      { key: 'ttl', method: 'getAccountTtl', soft: true },
      { key: 'topChats', method: 'getOption', params: { name: 'disable_top_chats' }, soft: true },
    ]),
  ]);
  const rules = {};
  ruleTypes.forEach((t, i) => { rules[t] = parseRules(ruleAnswers[i]); });
  return { rules, ...extra };
}

export async function renderPrivacySecurity() {
  const s = await loadState();
  const val = (x, f) => (failed(x) ? '' : f(x));
  const security = group('Security',
    navRow({
      iconName: 'block', label: 'Blocked users',
      value: val(s.blocked, (b) => (b.total_count ? String(b.total_count) : 'None')), onClick: openBlocked,
    }),
    navRow({
      iconName: 'devices', label: 'Active sessions',
      value: val(s.sessions, (a) => String(a.sessions?.length ?? 0)), onClick: openSessions,
    }),
    navRow({
      iconName: 'lock', label: 'Two-step verification',
      value: val(s.password, (p) => (p.has_password ? 'On' : 'Off')),
      onClick: failed(s.password) ? null : () => openPassword(s.password),
    }),
    navRow({
      iconName: 'clock', label: 'Auto-delete messages',
      value: val(s.autoDelete, (a) => periodLabel(a.time)),
      onClick: () => openChoice({
        title: 'Auto-delete messages',
        about: 'If enabled, all new messages in chats you start will be automatically deleted '
          + 'for everyone at some point after they have been sent. This will not affect your existing chats.',
        options: AUTO_DELETE.map((t) => ({ value: t, label: periodLabel(t) })),
        value: failed(s.autoDelete) ? 0 : s.autoDelete.time,
        save: (v) => one('setDefaultMessageAutoDeleteTime', {
          message_auto_delete_time: { '@type': 'messageAutoDeleteTime', time: Number(v) },
        }),
      }),
    }));
  const privacy = group('Privacy',
    ...RULES.map((def) => {
      if (def.messages) {
        return navRow({
          label: def.label, premium: def.premium,
          value: val(s.newChat, (n) => (n.allow_new_chats_from_unknown_users ? 'Everybody' : 'Contacts and Premium')),
          onClick: failed(s.newChat) ? null : () => openMessages(s),
        });
      }
      return navRow({
        label: def.label, premium: def.premium,
        value: summary(s.rules[def.setting]),
        onClick: () => openRule(def, s),
      });
    }));
  const websites = val(s.websites, (w) => w.websites?.length ?? 0);
  const bots = websites ? group('Bots and websites',
    navRow({ iconName: 'globe', label: 'Logged in with Telegram', value: String(websites), onClick: openWebsites })) : null;
  const topOff = !failed(s.topChats) && s.topChats.value === true;
  const contacts = group('Contacts',
    switchRow('Suggest frequent contacts',
      'Show people you message often at the top of search.',
      !topOff,
      (on) => saving(() => one('setOption', {
        name: 'disable_top_chats', value: { '@type': 'optionValueBoolean', value: !on },
      }))));
  const account = group('Delete my account',
    navRow({
      label: 'If away for',
      value: val(s.ttl, (t) => ttlLabel(t.days)),
      onClick: () => openChoice({
        title: 'Self-destruct if inactive for',
        about: 'If you do not come online at least once within this period, your account will be '
          + 'deleted along with all messages and contacts.',
        options: ACCOUNT_TTL.map((d) => ({ value: d, label: ttlLabel(d) })),
        value: failed(s.ttl) ? 180 : s.ttl.days,
        save: (v) => one('setAccountTtl', { ttl: { '@type': 'accountTtl', days: Number(v) } }),
      }),
    }));
  return [
    isPremium() ? null : intro('Settings marked Premium need Telegram Premium.'),
    security, privacy, bots, contacts, account,
  ].filter(Boolean);
}

