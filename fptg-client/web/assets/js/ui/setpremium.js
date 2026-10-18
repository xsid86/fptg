import { el, clear } from '../core/dom.js';
import { icon } from '../util/icons.js';
import { store } from '../core/store.js';
import { openLink } from './links.js';
import { stickerNode } from './message.js';
import { openBox, note, toggleRow, textField } from './tgbox.js';
import {
  load, one, td, failed, refresh, group, navRow, intro, actionButton, isPremium, me,
  dateTime,
} from './setkit.js';
import { peerCards, chatPicker } from './setpeers.js';

// Paid sections — as in Telegram Desktop: "Telegram Premium" (what it
// gives, limits, the subscription — via TDLib's payment link), "My stars"
// (balance, transactions, subscriptions), "Telegram Business" (location,
// opening hours, the intro page, chat links; inactive without Premium) and
// "Send a gift" (to whom, which gift, a caption).

// ------------------------------------------------------------ Premium

const FEATURES = {
  premiumFeatureIncreasedLimits: ['Doubled limits', 'Up to 1000 channels, 30 folders, 10 pins, 20 public links, 4 accounts and more.'],
  premiumFeatureIncreasedUploadFileSize: ['Upload 4 GB', 'Increase the upload size from 2 GB to 4 GB per document.'],
  premiumFeatureImprovedDownloadSpeed: ['Faster download speed', 'No more limits on the speed with which media and documents are downloaded.'],
  premiumFeatureVoiceRecognition: ['Voice-to-text conversion', 'Read the transcript of any incoming voice and video message.'],
  premiumFeatureDisabledAds: ['No ads', 'No more ads in public channels where Telegram sometimes shows ads.'],
  premiumFeatureUniqueReactions: ['Infinite reactions', 'React with thousands of emoji, several per message.'],
  premiumFeatureUniqueStickers: ['Premium stickers', 'Exclusive enlarged stickers with additional effects.'],
  premiumFeatureCustomEmoji: ['Animated emoji', 'Include animated emoji from different emoji sets in any message you send.'],
  premiumFeatureAdvancedChatManagement: ['Advanced chat management', 'Tools to set the default folder, auto-archive and hide new chats from non-contacts.'],
  premiumFeatureProfileBadge: ['Profile badge', 'A badge next to your name showing that you are helping support Telegram.'],
  premiumFeatureEmojiStatus: ['Emoji status', 'Add any of thousands of emoji next to your name.'],
  premiumFeatureAnimatedProfilePhoto: ['Animated profile pictures', 'Video avatars animated in chat lists and chats.'],
  premiumFeatureForumTopicIcon: ['Topic icons', 'Custom icons for topics in groups with topics.'],
  premiumFeatureAppIcons: ['Additional app icons', 'Choose from a selection of Telegram app icons.'],
  premiumFeatureRealTimeChatTranslation: ['Real-time translation', 'Real-time translation of channels and chats into other languages.'],
  premiumFeatureUpgradedStories: ['Upgraded stories', 'Priority order, stealth mode, permanent views history and more.'],
  premiumFeatureChatBoost: ['Boosts', 'Boost your favorite channels and groups.'],
  premiumFeatureAccentColor: ['Name and profile colors', 'Choose a color and logo for your profile and replies to your messages.'],
  premiumFeatureBackgroundForBoth: ['Wallpapers for both sides', 'Set custom wallpapers for you and your chat partner.'],
  premiumFeatureSavedMessagesTags: ['Tags for messages', 'Organize your Saved Messages with tags.'],
  premiumFeatureMessagePrivacy: ['Message privacy', 'Restrict people who are not your contacts from sending you messages.'],
  premiumFeatureLastSeenTimes: ['Last seen times', 'See the last seen and read times of others even if you hide yours.'],
  premiumFeatureBusiness: ['Telegram Business', 'Location, opening hours, quick replies and more for your account.'],
  premiumFeatureMessageEffects: ['Message effects', 'Add animated effects to private messages.'],
  premiumFeatureChecklists: ['Checklists', 'Plan, assign and complete tasks together.'],
  premiumFeaturePaidMessages: ['Paid messages', 'Charge a fee for messages from people outside your contacts.'],
  premiumFeatureProtectPrivateChatContent: ['Protected chats', 'Prevent copying and saving messages in your private chats.'],
  premiumFeatureTextComposition: ['Text styles', 'Rewrite and style your text before sending.'],
  premiumFeatureRichMessages: ['Rich messages', 'Headings, lists, tables and collapsible blocks in your messages.'],
};

const LIMITS = {
  premiumLimitTypeSupergroupCount: 'Groups and channels',
  premiumLimitTypePinnedChatCount: 'Pinned chats',
  premiumLimitTypeCreatedPublicChatCount: 'Public links',
  premiumLimitTypeSavedAnimationCount: 'Saved GIFs',
  premiumLimitTypeFavoriteStickerCount: 'Favorite stickers',
  premiumLimitTypeChatFolderCount: 'Folders',
  premiumLimitTypeChatFolderChosenChatCount: 'Chats per folder',
  premiumLimitTypePinnedArchivedChatCount: 'Pinned chats in archive',
  premiumLimitTypeCaptionLength: 'Media caption length',
  premiumLimitTypeBioLength: 'Bio length',
  premiumLimitTypeChatFolderInviteLinkCount: 'Folder invite links',
  premiumLimitTypeShareableChatFolderCount: 'Shareable folders',
  premiumLimitTypeActiveStoryCount: 'Active stories',
  premiumLimitTypeSimilarChatCount: 'Similar channels',
  premiumLimitTypeOwnedBotCount: 'Bots',
};

const humanize = (type, prefix) => type.replace(prefix, '').replace(/([a-z])([A-Z])/g, '$1 $2');

/** An amount in the currency's small units -> "$4.99". */
export function price(amount, currency) {
  try {
    const f = new Intl.NumberFormat('en-US', { style: 'currency', currency });
    const digits = f.resolvedOptions().maximumFractionDigits;
    return f.format(amount / 10 ** digits);
  } catch {
    return `${amount} ${currency}`;
  }
}

/** A payment InternalLinkType -> a t.me link (links.js opens it). */
function paymentHref(link) {
  switch (link?.['@type']) {
    case 'internalLinkTypeBotStart':
      return `https://t.me/${link.bot_username}?start=${encodeURIComponent(link.start_parameter)}`;
    case 'internalLinkTypeInvoice':
      return `https://t.me/$${link.invoice_name}`;
    default:
      return 'https://t.me/PremiumBot';
  }
}

export async function renderPremium() {
  const a = await td([
    { key: 'state', method: 'getPremiumState', soft: true },
    { key: 'features', method: 'getPremiumFeatures', params: { source: { '@type': 'premiumSourceSettings' } }, soft: true },
  ]);
  const premium = isPremium();
  const head = el('div', { class: 'settings__hero' },
    el('span', { class: 'settings__hero-icon' }, icon('star', 'icon--lg')),
    el('h3', { class: 'settings__hero-title' }, 'Telegram Premium'),
    el('p', { class: 'settings__hint' }, premium
      ? 'You are all set! Thank you for subscribing to Telegram Premium.'
      : (failed(a.state) ? 'Go beyond the limits and unlock dozens of exclusive features.'
        : a.state.state?.text || 'Go beyond the limits and unlock dozens of exclusive features.')));
  const options = failed(a.state) ? [] : (a.state.payment_options ?? []);
  const link = failed(a.features) ? null : a.features.payment_link;
  const plans = options.length ? group(premium ? 'Your plan' : 'Subscribe',
    ...options.map((o) => {
      const p = o.payment_option;
      const months = p.month_count;
      const label = months === 12 ? 'Annual' : months === 1 ? 'Monthly' : `${months} months`;
      return el('div', { class: 'settings__row' },
        el('div', { class: 'settings__text' },
          el('span', { class: 'settings__label' }, label,
            p.discount_percentage ? el('span', { class: 'settings__badge is-accent' }, `−${p.discount_percentage}%`) : null),
          el('p', { class: 'settings__hint' },
            `${price(p.amount, p.currency)}${months > 1 ? ` (${price(Math.round(p.amount / months), p.currency)} / month)` : ''}`)),
        el('div', { class: 'settings__control' },
          o.is_current ? el('span', { class: 'settings__value' }, 'Current')
            : actionButton(o.is_upgrade || !premium ? 'Subscribe' : 'Choose',
              () => openLink(paymentHref(p.payment_link ?? link)), { primary: true })));
    })) : (premium ? null : group(null, el('div', { class: 'settings__row' },
    el('div', { class: 'settings__text' }, el('span', { class: 'settings__label' }, 'Subscribe to Telegram Premium')),
    el('div', { class: 'settings__control' }, actionButton('Subscribe', () => openLink(paymentHref(link)), { primary: true })))));
  const features = failed(a.features) ? [] : (a.features.features ?? []);
  const featureGroup = features.length ? group('What you get',
    ...features.map((f) => {
      const [title, about] = FEATURES[f['@type']] ?? [humanize(f['@type'], 'premiumFeature'), ''];
      return el('div', { class: 'settings__row' },
        el('div', { class: 'settings__text' },
          el('span', { class: 'settings__label' }, title),
          about ? el('p', { class: 'settings__hint' }, about) : null));
    })) : null;
  const limits = failed(a.features) ? [] : (a.features.limits ?? []).filter((l) => LIMITS[l.type?.['@type']]);
  const limitGroup = limits.length ? group('Doubled limits',
    el('div', { class: 'settings__grid-wrap' },
      el('table', { class: 'settings__grid' },
        el('thead', {}, el('tr', {},
          el('th', { class: 'settings__grid-corner', scope: 'col' }, el('span', { class: 'u-sr-only' }, 'Limit')),
          el('th', { scope: 'col' }, 'Free'), el('th', { scope: 'col' }, 'Premium'))),
        el('tbody', {}, ...limits.map((l) => el('tr', {},
          el('th', { scope: 'row' }, LIMITS[l.type['@type']]),
          el('td', { class: 'u-tabular' }, String(l.default_value)),
          el('td', { class: 'u-tabular' }, String(l.premium_value)))))))) : null;
  return [head, plans, featureGroup, limitGroup].filter(Boolean);
}

// -------------------------------------------------------------- Stars

const TX_TITLES = {
  starTransactionTypePremiumBotDeposit: 'Stars purchase',
  starTransactionTypeAppStoreDeposit: 'Stars purchase (App Store)',
  starTransactionTypeGooglePlayDeposit: 'Stars purchase (Google Play)',
  starTransactionTypeFragmentDeposit: 'Stars purchase (Fragment)',
  starTransactionTypeUserDeposit: 'Gift from a user',
  starTransactionTypeGiveawayDeposit: 'Giveaway prize',
  starTransactionTypeFragmentWithdrawal: 'Withdrawal',
  starTransactionTypeTelegramAdsWithdrawal: 'Ads withdrawal',
  starTransactionTypeBotPaidMediaPurchase: 'Paid media',
  starTransactionTypeBotPaidMediaSale: 'Paid media sale',
  starTransactionTypeChannelPaidMediaPurchase: 'Paid media',
  starTransactionTypeChannelPaidMediaSale: 'Paid media sale',
  starTransactionTypeBotInvoicePurchase: 'Bot payment',
  starTransactionTypeBotInvoiceSale: 'Bot sale',
  starTransactionTypeBotSubscriptionPurchase: 'Bot subscription',
  starTransactionTypeChannelSubscriptionPurchase: 'Channel subscription',
  starTransactionTypeGiftPurchase: 'Gift sent',
  starTransactionTypeGiftSale: 'Gift converted to Stars',
  starTransactionTypeGiftUpgrade: 'Gift upgrade',
  starTransactionTypeGiftTransfer: 'Gift transfer',
  starTransactionTypeUpgradedGiftPurchase: 'Gift bought',
  starTransactionTypeUpgradedGiftSale: 'Gift sold',
  starTransactionTypeChannelPaidReactionSend: 'Paid reaction',
  starTransactionTypeChannelPaidReactionReceive: 'Paid reaction received',
  starTransactionTypePaidMessageSend: 'Paid messages',
  starTransactionTypePaidMessageReceive: 'Paid messages received',
  starTransactionTypePremiumPurchase: 'Telegram Premium',
  starTransactionTypePublicPostSearch: 'Post search',
};

const stars = (a) => (a ? a.star_count + (a.nanostar_count ? a.nanostar_count / 1e9 : 0) : 0);
const starText = (n) => `${n > 0 ? '+' : ''}${Number.isInteger(n) ? n : n.toFixed(2)}`;

let starsTab = 'all';

export async function renderStars() {
  const direction = starsTab === 'in' ? { '@type': 'transactionDirectionIncoming' }
    : starsTab === 'out' ? { '@type': 'transactionDirectionOutgoing' } : null;
  const a = await td([
    { key: 'tx', method: 'getStarTransactions', params: { owner_id: me(), subscription_id: '', direction, offset: '', limit: 50 }, soft: true },
    { key: 'subs', method: 'getStarSubscriptions', params: { only_expiring: false, offset: '' }, soft: true },
  ]);
  const balance = failed(a.tx) ? 0 : stars(a.tx.star_amount);
  const head = el('div', { class: 'settings__hero' },
    el('span', { class: 'settings__hero-icon is-stars' }, icon('star', 'icon--lg')),
    el('h3', { class: 'settings__hero-title u-tabular' }, String(balance)),
    el('p', { class: 'settings__hint' }, 'Your balance. Stars pay for digital goods and services in bots, '
      + 'channels and gifts.'));
  const subs = failed(a.subs) ? [] : (a.subs.subscriptions ?? []);
  const subCards = await peerCards({ chats: subs.map((s) => String(s.chat_id)) });
  const subGroup = subs.length ? group('My subscriptions',
    ...subs.map((s) => el('div', { class: 'settings__row' },
      el('div', { class: 'settings__text' },
        el('span', { class: 'settings__label' }, subCards.get(`c${s.chat_id}`)?.title ?? 'Subscription'),
        el('p', { class: 'settings__hint' },
          `${s.is_canceled ? 'Cancelled, ends' : 'Renews'} ${dateTime(s.expiration_date)}`)),
      el('div', { class: 'settings__control' },
        el('span', { class: 'settings__value u-tabular' }, `⭐ ${s.pricing?.star_count ?? 0} / month`))))) : null;
  const tabs = el('div', { class: 'color-tabs settings__tabs' },
    ...[['all', 'All'], ['in', 'Incoming'], ['out', 'Outgoing']].map(([id, label]) => el('button', {
      class: `color-tabs__tab${starsTab === id ? ' is-active' : ''}`, type: 'button',
      onclick: () => { starsTab = id; refresh(); },
    }, label)));
  const txs = failed(a.tx) ? [] : (a.tx.transactions ?? []);
  const txGroup = group('Transactions', tabs,
    ...(txs.length ? txs.map((t) => {
      const n = stars(t.star_amount);
      const type = t.type?.['@type'] ?? '';
      return el('div', { class: 'settings__row' },
        el('div', { class: 'settings__text' },
          el('span', { class: 'settings__label' },
            (TX_TITLES[type] ?? humanize(type, 'starTransactionType')) + (t.is_refund ? ' (refund)' : '')),
          el('p', { class: 'settings__hint' }, dateTime(t.date))),
        el('div', { class: 'settings__control' },
          el('span', { class: `settings__amount u-tabular${n > 0 ? ' is-plus' : ''}` }, `${starText(n)} ⭐`)));
    }) : [el('p', { class: 'settings__hint' }, 'No transactions yet.')]));
  return [head, subGroup, txGroup].filter(Boolean);
}

// --------------------------------------------------------------- Gift

const stickerUrls = new Map();

async function giftSticker(gift) {
  const s = gift.sticker;
  const fmt = { stickerFormatTgs: 'tgs', stickerFormatWebm: 'webm' }[s?.format?.['@type']] ?? 'webp';
  const id = s?.sticker?.id;
  if (!id) return null;
  if (!stickerUrls.has(id)) {
    stickerUrls.set(id, load('file.ensure', { fileId: id }).then((r) => r.url).catch(() => ''));
  }
  const url = await stickerUrls.get(id);
  return url ? { url, format: fmt } : null;
}

function giftTile(item, onClick) {
  const g = item.gift;
  const frame = el('span', { class: 'gift-tile__sticker is-empty' }, icon('gift'));
  giftSticker(g).then((m) => {
    if (m) clear(frame).append(stickerNode(m));
    frame.classList.toggle('is-empty', !m);
  });
  const soldOut = g.overall_limits && g.overall_limits.remaining_count === 0;
  return el('button', { class: 'gift-tile tgbox__gift', type: 'button', onclick: onClick, disabled: soldOut },
    frame,
    el('span', { class: 'gift-tile__label' }, soldOut ? 'Sold out' : `⭐ ${g.star_count}`),
    g.overall_limits ? el('span', { class: 'tgbox__gift-badge' }, 'Limited') : null);
}

function giftConfirm(recipient, item, balance) {
  const g = item.gift;
  const text = textField('Enter a message (optional)', '', { multiline: true, max: 128 });
  let hidden = false;
  return {
    title: 'Send a gift',
    render: () => [
      el('div', { class: 'tgbox__gift-preview' }, giftTile(item, null)),
      note(`To ${recipient.title}. The gift costs ${g.star_count} Stars; your balance is ${balance} Stars.`),
      text.node,
      toggleRow('Hide my name', false, {
        sub: 'Only the recipient will see your name and message.',
        onChange: (v) => { hidden = v; },
      }).node,
    ],
    buttons: [
      { label: 'Back', run: (box) => box.pop() },
      {
        label: `Send a gift for ⭐ ${g.star_count}`, primary: true,
        async run(box) {
          if (balance < g.star_count) throw new Error('Not enough Stars on your balance.');
          await one('sendGift', {
            gift_id: g.id,
            owner_id: { '@type': 'messageSenderUser', user_id: Number(recipient.id) },
            text: { '@type': 'formattedText', text: text.input.value.trim(), entities: [] },
            is_private: hidden, pay_for_upgrade: false,
          });
          box.close();
        },
      },
    ],
  };
}

function giftsPage(recipient) {
  return {
    title: 'Choose a gift',
    async render(body, box) {
      const a = await td([
        { key: 'gifts', method: 'getAvailableGifts' },
        { key: 'tx', method: 'getStarTransactions', params: { owner_id: me(), subscription_id: '', direction: null, offset: '', limit: 1 }, soft: true },
      ]);
      const balance = failed(a.tx) ? 0 : stars(a.tx.star_amount);
      const items = (a.gifts.gifts ?? []).filter((x) => !x.gift.is_premium || isPremium());
      return [
        note(`Give ${recipient.title} a gift. Your balance: ${balance} Stars.`),
        el('div', { class: 'gift-grid tgbox__gifts' },
          ...items.map((item) => giftTile(item, () => box.push(giftConfirm(recipient, item, balance))))),
      ];
    },
    buttons: [{ label: 'Back', run: (box) => box.pop() }],
  };
}

export function openSendGift() {
  let picker = null;
  openBox().push({
    title: 'Send a gift',
    render() {
      picker = chatPicker({ kinds: ['user', 'self'] });
      return [note('Choose who to send a gift to.'), ...picker.nodes];
    },
    buttons: [
      { label: 'Cancel', run: (box) => box.close() },
      {
        label: 'Next', primary: true,
        run(box) {
          const id = picker.chosen()[0];
          if (!id) throw new Error('Choose a person.');
          const chat = store.chats.find((c) => String(c.id) === id);
          box.push(giftsPage({ id, title: chat?.title ?? 'them' }));
        },
      },
    ],
  });
}

export function renderGift() {
  return [
    intro('Give gifts to your friends: limited and collectible gifts paid with Stars. '
      + 'Gifts appear on the recipient’s profile.'),
    group(null, navRow({ iconName: 'gift', label: 'Send a gift', hint: 'Choose a person and a gift.', onClick: openSendGift })),
  ];
}

