import { el } from '../core/dom.js';
import { on } from '../core/bus.js';
import { formDialog, field, checkRow } from './bots.js';
import { openLink } from './links.js';

// Оплата счетов: кнопки «Купить» у ботов ({ msgId }) и ссылки-счета
// t.me/$имя ({ invoiceName }) — событие ui:pay-invoice.
//
// Звёзды — одно подтверждение. Деньги — по шагам, как у Telegram Desktop:
//   1. данные заказа (имя/телефон/почта/адрес), если счёт их просит —
//      validateOrderInfo, и выбор доставки у гибкого счёта;
//   2. способ оплаты: карта, сохранённая в Telegram (при need_password —
//      облачный пароль -> временный пароль), или новая карта;
//   3. новая карта уходит ПРЯМО ПРОВАЙДЕРУ со страницы (fetch): Smart
//      Glocal или Stripe. Ни наш сервер, ни Telegram номера карты не
//      видят — в sendPaymentForm идёт только токен провайдера
//      (inputCredentialsNew.data). Протокол обоих — по исходникам
//      Telegram Desktop (payments/smartglocal, payments/stripe) и
//      документации Stripe; CORS обоих разрешает запрос с этой страницы
//      (проверено preflight-запросом);
//   4. итоговое подтверждение с полной суммой — и только тогда оплата.

let hooks = {};
const notify = (text) => hooks.notice?.(text);

// Адрес токенизации Smart Glocal — как его проверяет Telegram Desktop
// (smartglocal_api_client.cpp, ComputeApiUrl): https, хост на
// .smart-glocal.com, ровно этот путь, без query и фрагмента. Иначе —
// стандартный адрес. Номер карты по чужому адресу не уходит.
const SMART_GLOCAL_PATH = '/cds/v1/tokenize/card';
const SMART_GLOCAL_HOST = { live: 'tgb.smart-glocal.com', test: 'tgb-playground.smart-glocal.com' };
const STRIPE_TOKENS_URL = 'https://api.stripe.com/v1/tokens';

/** Сумма в минимальных единицах валюты — как человек её читает. */
export function money(amount, currency) {
  try {
    const fmt = new Intl.NumberFormat(undefined, { style: 'currency', currency });
    const digits = fmt.resolvedOptions().maximumFractionDigits;
    return fmt.format(amount / 10 ** digits);
  } catch {
    return `${amount} ${currency}`;
  }
}

const note = (...content) => el('p', { class: 'confirm__note' }, ...content);

function termsNote(form) {
  if (!form.terms) return null;
  return note('By paying you accept the ',
    el('a', { href: form.terms, target: '_blank', rel: 'noopener noreferrer' },
      'terms of the payment provider'), '.');
}

async function finish(r) {
  // 3-D Secure и прочие проверки банка — его страница.
  if (r?.url) openLink(r.url);
  else if (r?.success) notify('Payment completed');
}

// ------------------------------------------------------------- stars
async function payStars(invoice, form) {
  const what = form.title ? ` for “${form.title}”` : '';
  const yes = await formDialog({ text: `Pay ${form.stars} Telegram Stars${what}?`, ok: 'Pay' });
  if (!yes) return;
  finish(await hooks.call('bot.pay', { ...invoice, formId: form.formId }));
}

// ------------------------------------------------------- order info
const needsOrder = (need) => Boolean(need?.name || need?.phone || need?.email || need?.shipping);

async function askOrder(form) {
  const need = form.need;
  const saved = form.savedOrder ?? {};
  const addr = saved.address ?? {};
  const inputs = {};
  const body = [];
  const add = (key, attrs, value) => {
    inputs[key] = field({ type: 'text', ...attrs, value: value ?? '' });
    body.push(inputs[key]);
  };
  if (need.name) add('name', { placeholder: 'Name', autocomplete: 'name' }, saved.name);
  if (need.phone) add('phone', { placeholder: 'Phone number', autocomplete: 'tel', type: 'tel' }, saved.phone);
  if (need.email) add('email', { placeholder: 'Email', autocomplete: 'email', type: 'email' }, saved.email);
  if (need.shipping) {
    add('street1', { placeholder: 'Address line 1', autocomplete: 'address-line1' }, addr.street1);
    add('street2', { placeholder: 'Address line 2 (optional)', autocomplete: 'address-line2' }, addr.street2);
    add('city', { placeholder: 'City', autocomplete: 'address-level2' }, addr.city);
    add('state', { placeholder: 'State / region (optional)', autocomplete: 'address-level1' }, addr.state);
    add('countryCode', { placeholder: 'Country code (e.g. MD)', autocomplete: 'country', maxLength: 2 }, addr.countryCode);
    add('postalCode', { placeholder: 'Postal code', autocomplete: 'postal-code' }, addr.postalCode);
  }
  const save = checkRow('Save this information for future payments', true);
  body.push(save.node);
  const optional = new Set(['street2', 'state']);
  const yes = await formDialog({
    text: 'Order details', body, ok: 'Continue',
    check: () => {
      for (const [key, input] of Object.entries(inputs)) {
        if (!optional.has(key) && !input.value.trim()) return 'Fill in all required fields';
      }
      if (inputs.countryCode && !/^[A-Za-z]{2}$/.test(inputs.countryCode.value.trim())) {
        return 'Country code is two letters';
      }
      return '';
    },
  });
  if (!yes) return null;
  const v = (key) => inputs[key]?.value.trim() ?? '';
  const info = { name: v('name'), phone: v('phone'), email: v('email') };
  if (need.shipping) {
    info.address = {
      countryCode: v('countryCode').toUpperCase(), state: v('state'), city: v('city'),
      street1: v('street1'), street2: v('street2'), postalCode: v('postalCode'),
    };
  }
  return { info, save: save.box.checked };
}

async function askChoice(text, options, ok) {
  const name = `choice-${Date.now()}`;
  const radios = options.map((o, i) => {
    const box = el('input', { type: 'radio', name, checked: i === 0 });
    return { box, node: el('label', { class: 'confirm__check' }, box, el('span', {}, o.label)) };
  });
  const yes = await formDialog({ text, body: radios.map((r) => r.node), ok });
  if (!yes) return null;
  const i = radios.findIndex((r) => r.box.checked);
  return options[i < 0 ? 0 : i];
}

// ------------------------------------------------------------- cards
const digits = (s) => String(s).replace(/\D/g, '');

/** Контрольная сумма номера карты (алгоритм Луна). */
function luhn(number) {
  let sum = 0;
  let dbl = false;
  for (let i = number.length - 1; i >= 0; i -= 1) {
    let d = Number(number[i]);
    if (dbl) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    dbl = !dbl;
  }
  return number.length >= 12 && sum % 10 === 0;
}

function brand(number) {
  if (/^4/.test(number)) return 'visa';
  if (/^(5[1-5]|2[2-7])/.test(number)) return 'mastercard';
  if (/^220[0-4]/.test(number)) return 'mir';
  if (/^3[47]/.test(number)) return 'amex';
  return 'card';
}

/** MM/YY -> { month, year } (год — полный) или null. */
function parseExpiry(text) {
  const m = /^\s*(\d{1,2})\s*\/\s*(\d{2}|\d{4})\s*$/.exec(text);
  if (!m) return null;
  const month = Number(m[1]);
  let year = Number(m[2]);
  if (year < 100) year += 2000;
  if (month < 1 || month > 12) return null;
  const now = new Date();
  if (year < now.getFullYear() || (year === now.getFullYear() && month < now.getMonth() + 1)) return null;
  return { month, year };
}

function smartGlocalUrl(provider, isTest) {
  try {
    const u = new URL(provider.tokenizeUrl);
    if (u.protocol === 'https:' && u.hostname.endsWith('.smart-glocal.com')
        && u.pathname === SMART_GLOCAL_PATH && !u.search && !u.hash) return u.href;
  } catch { /* не адрес — стандартный ниже */ }
  return `https://${isTest ? SMART_GLOCAL_HOST.test : SMART_GLOCAL_HOST.live}${SMART_GLOCAL_PATH}`;
}

async function tokenizeSmartGlocal(provider, card, isTest) {
  const pad = (n) => String(n % 100).padStart(2, '0');
  const response = await fetch(smartGlocalUrl(provider, isTest), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-PUBLIC-TOKEN': provider.publicToken },
    body: JSON.stringify({
      card: {
        number: card.number,
        expiration_month: pad(card.month),
        expiration_year: pad(card.year),
        security_code: card.cvc,
      },
    }),
  });
  const answer = await response.json().catch(() => null);
  const token = answer?.data?.token;
  if (!token) throw new Error(answer?.error?.message || answer?.message || 'The card was not accepted');
  return JSON.stringify({ token, type: 'card' });
}

async function tokenizeStripe(provider, card) {
  const form = new URLSearchParams({
    'card[number]': card.number,
    'card[exp_month]': String(card.month),
    'card[exp_year]': String(card.year),
    'card[cvc]': card.cvc,
  });
  if (card.name) form.set('card[name]', card.name);
  if (card.country) form.set('card[address_country]', card.country);
  if (card.zip) form.set('card[address_zip]', card.zip);
  const response = await fetch(STRIPE_TOKENS_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${provider.publishableKey}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: form.toString(),
  });
  const answer = await response.json().catch(() => null);
  if (!answer?.id) throw new Error(answer?.error?.message || 'The card was not accepted');
  return JSON.stringify({ type: 'card', id: answer.id });
}

/** Новая карта: форма -> токен провайдера. { newData, allowSave, title } или null. */
async function askNewCard(form) {
  const p = form.provider;
  const number = field({ type: 'text', placeholder: 'Card number', inputmode: 'numeric', autocomplete: 'cc-number' });
  const expiry = field({ type: 'text', placeholder: 'MM/YY', inputmode: 'numeric', autocomplete: 'cc-exp', maxLength: 7 });
  const cvc = field({ type: 'password', placeholder: 'CVC', inputmode: 'numeric', autocomplete: 'cc-csc', maxLength: 4 });
  const body = [number, expiry, cvc];
  const name = p.type === 'stripe' && p.needCardholderName
    ? field({ type: 'text', placeholder: 'Cardholder name', autocomplete: 'cc-name' }) : null;
  const country = p.type === 'stripe' && p.needCountry
    ? field({ type: 'text', placeholder: 'Billing country code (e.g. MD)', autocomplete: 'country', maxLength: 2 }) : null;
  const zip = p.type === 'stripe' && p.needPostalCode
    ? field({ type: 'text', placeholder: 'Billing postal code', autocomplete: 'postal-code' }) : null;
  for (const f of [name, country, zip]) if (f) body.push(f);
  const save = form.canSave ? checkRow('Save card for future payments', false) : null;
  if (save) body.push(save.node);
  body.push(note('The card number goes straight to the payment provider; Telegram and this app only get a token.'));

  const yes = await formDialog({
    text: 'New card', body, ok: 'Continue',
    check: () => {
      if (!luhn(digits(number.value))) return 'Check the card number';
      if (!parseExpiry(expiry.value)) return 'Check the expiry date (MM/YY)';
      if (!/^\d{3,4}$/.test(cvc.value.trim())) return 'Check the CVC';
      if (name && !name.value.trim()) return 'Enter the cardholder name';
      if (country && !/^[A-Za-z]{2}$/.test(country.value.trim())) return 'Country code is two letters';
      if (zip && !zip.value.trim()) return 'Enter the postal code';
      return '';
    },
  });
  if (!yes) return null;
  const exp = parseExpiry(expiry.value);
  const card = {
    number: digits(number.value), month: exp.month, year: exp.year, cvc: cvc.value.trim(),
    name: name?.value.trim() ?? '', country: country?.value.trim().toUpperCase() ?? '',
    zip: zip?.value.trim() ?? '',
  };
  try {
    const newData = p.type === 'stripe'
      ? await tokenizeStripe(p, card)
      : await tokenizeSmartGlocal(p, card, form.isTest);
    return { newData, allowSave: Boolean(save?.box.checked), title: `${brand(card.number)} *${card.number.slice(-4)}` };
  } catch (error) {
    hooks.report?.(error);
    return null;
  }
}

async function askPassword() {
  const pass = field({ type: 'password', placeholder: 'Cloud password', autocomplete: 'current-password' });
  const yes = await formDialog({
    text: 'Enter your cloud password to pay with a saved card',
    body: [pass], ok: 'Continue',
    check: () => (pass.value ? '' : 'Enter the password'),
  });
  if (!yes) return false;
  try {
    await hooks.call('bot.tmpPassword', { password: pass.value });
    return true;
  } catch (error) {
    hooks.report?.(error);
    return false;
  }
}

/** Способ оплаты: { savedId, title } | { newCard: true } | null. */
async function askMethod(form) {
  const canNew = form.provider?.type === 'smartglocal' || form.provider?.type === 'stripe';
  const options = (form.saved ?? []).map((s) => ({ label: s.title, savedId: s.id, title: s.title }));
  if (canNew) options.push({ label: 'New card', newCard: true });
  if (!options.length) return null;
  if (options.length === 1) return options[0];
  return askChoice('Pay with', options, 'Continue');
}

// --------------------------------------------------------- card flow
async function payCard(invoice, form) {
  let orderInfoId = '';
  let shipping = null;
  if (needsOrder(form.need)) {
    const order = await askOrder(form);
    if (!order) return;
    const v = await hooks.call('bot.validateOrder', { ...invoice, order: order.info, save: order.save });
    orderInfoId = v.orderInfoId || '';
    if (v.shipping?.length) {
      shipping = await askChoice('Shipping method',
        v.shipping.map((o) => ({ ...o, label: `${o.title} — ${money(o.amount, form.currency)}` })), 'Continue');
      if (!shipping) return;
    }
  }

  const method = await askMethod(form);
  if (!method) {
    notify('This payment method is not supported in this app');
    return;
  }
  let creds;
  if (method.newCard) {
    creds = await askNewCard(form);
    if (!creds) return;
  } else {
    if (form.needPassword && !(await askPassword())) return;
    creds = { savedId: method.savedId, title: method.title };
  }

  const total = form.amount + (shipping?.amount ?? 0);
  const sum = money(total, form.currency);
  const lines = (form.priceParts ?? []).map((p) => note(`${p.label}: ${money(p.amount, form.currency)}`));
  if (shipping) lines.push(note(`${shipping.title}: ${money(shipping.amount, form.currency)}`));
  const what = form.title ? ` for “${form.title}”` : '';
  const yes = await formDialog({
    text: `Pay ${sum}${what} with ${creds.title}?`,
    body: [...lines, termsNote(form), form.isTest ? note('This is a test payment.') : null].filter(Boolean),
    ok: `Pay ${sum}`,
  });
  if (!yes) return;
  finish(await hooks.call('bot.pay', {
    ...invoice,
    formId: form.formId,
    orderInfoId,
    shippingOptionId: shipping?.id ?? '',
    savedId: creds.savedId ?? '',
    newData: creds.newData ?? '',
    allowSave: Boolean(creds.allowSave),
  }));
}

async function payInvoice(invoice) {
  const form = await hooks.call('bot.buy', invoice);
  if (form.kind === 'url' && form.url) {
    openLink(form.url);
    return;
  }
  if (form.kind === 'stars') return payStars(invoice, form);
  if (form.kind === 'card') return payCard(invoice, form);
  notify('This payment method is not supported in this app');
  return undefined;
}

/** hooks: { call(cmd, args), report(err), notice(text) } */
export function mountPayments(options) {
  hooks = options ?? {};
  on('ui:pay-invoice', (invoice) => {
    payInvoice(invoice).catch((error) => hooks.report?.(error));
  });
}
