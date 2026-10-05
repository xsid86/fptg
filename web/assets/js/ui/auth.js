import { el, clear, qs } from '../core/dom.js';
import { icon } from '../util/icons.js';

// Signing in, in the browser.
//
// EVERY STEP IS TELEGRAM'S, NOT OURS. The flow is a state machine in
// tdauth.pas that the native window has always driven; this is a
// second face on the same machine, not a second machine. The page
// never decides what comes next - it draws the step the server says it
// is on, sends back the one answer that step asks for, and redraws
// when the server says the step changed.
//
// That is also why there is no validation here beyond "not empty".
// Whether a code is right, whether a password is right, whether a
// phone number exists at all - Telegram answers those, and its answer
// arrives as the `error` on the next state. Guessing locally would
// only mean two sets of rules to keep in step.
//
// The screens are one card on a backdrop, because at this point there
// is nothing else on screen to arrange it against: no chat list, no
// history, no account.

let root = null;
let hooks = {};
let current = null;   // the last screen drawn, so a redraw of the same step keeps typed text

/**
 * Which SCREEN a state means.
 *
 * Usually the state itself, but not always: resetting a forgotten
 * password is a second form inside tasWaitPassword, and comparing
 * states alone kept the first one on screen after Telegram had
 * already sent the recovery code. The rule is "rebuild when the form
 * changes", and this is what says whether it has.
 */
const screenKey = (info) => (info.state === 'password' && info.recoverySent
  ? 'password:recover'
  : info.state);

const text = (v) => (v ?? '').toString().trim();

/** A labelled input, and the value-getter for it. */
function field(label, props = {}) {
  const input = el('input', { class: 'auth__input', type: 'text', ...props });
  const wrap = el('label', { class: 'auth__field' },
    el('span', { class: 'auth__label' }, label),
    input);
  return { wrap, input };
}

function card(title, note, ...body) {
  return el('div', { class: 'auth__card' },
    el('h1', { class: 'auth__title' }, title),
    note ? el('p', { class: 'auth__note' }, ...[].concat(note)) : null,
    ...body);
}

const submit = (label) => el('button', { class: 'auth__submit', type: 'submit' }, label);

/**
 * A form whose only job is to hand one answer back.
 *
 * Built as a real <form> so Enter submits - on these screens that is
 * the only key anyone presses.
 */
function form(onSend, ...body) {
  return el('form', {
    class: 'auth__form',
    onsubmit: (event) => {
      event.preventDefault();
      onSend();
    },
  }, ...body);
}

const link = (label, onClick) => el('button', {
  class: 'auth__link', type: 'button', onclick: onClick,
}, label);

// ------------------------------------------------------- the screens
function screenApiConfig() {
  const id = field('api_id', { inputMode: 'numeric', autofocus: true });
  const hash = field('api_hash');
  // Ссылка уходит в системный браузер: окно WebView2 отдаёт ему любой
  // target=_blank через NewWindowRequested.
  return card('Connect this app to Telegram',
    ['Telegram gives every application its own api_id and api_hash. '
    + 'Create one at ',
    el('a', { href: 'https://my.telegram.org/apps', target: '_blank',
      rel: 'noopener noreferrer' }, 'my.telegram.org'),
    ', under API development tools, '
    + 'and paste the pair here. They are stored in config.ini beside '
    + 'the program and are not sent anywhere else.'],
    form(() => hooks.send('api.save',
      { apiId: Number(text(id.input.value)), apiHash: text(hash.input.value) }),
    id.wrap, hash.wrap, submit('Save and continue')));
}

function screenPhone(info) {
  const phone = field('Phone number', { type: 'tel', autofocus: true,
    placeholder: '+1 234 567 89 00' });
  return card('Sign in to Telegram',
    'Enter the number of the account you want to use. Telegram will '
    + 'send a confirmation code to it, or to another device you are '
    + 'already signed in on.',
    form(() => hooks.send('auth.phone', { phone: text(phone.input.value) }),
      phone.wrap, submit('Next')),
    el('div', { class: 'auth__aside' },
      link('Sign in by QR code instead', () => hooks.send('auth.qr'))));
}

function screenQr(info) {
  return card('Sign in by QR code', null,
    el('ol', { class: 'auth__steps' },
      el('li', {}, 'Open Telegram on your phone'),
      el('li', {}, 'Go to Settings → Devices → Link Desktop Device'),
      el('li', {}, 'Point your phone at this square')),
    info.qrImage
      ? el('img', { class: 'auth__qr', src: info.qrImage, alt: 'QR code' })
      : el('p', { class: 'auth__note' }, 'Waiting for a code…'),
    el('div', { class: 'auth__aside' },
      link('Use a phone number instead', () => hooks.send('auth.phone', { phone: '' }))));
}

const DELIVERY = {
  app: 'Telegram sent the code to another device you are signed in on.',
  sms: 'Telegram sent the code by SMS.',
  smsWord: 'Telegram sent an SMS. The code is its first word.',
  smsPhrase: 'Telegram sent an SMS. The code is its first phrase.',
  call: 'Telegram is calling to read the code out.',
  flashCall: 'Telegram is calling. The code is in the calling number.',
  missedCall: 'Telegram will call and hang up. The code is the last digits of the number.',
  fragment: 'The code was sent through Fragment.',
  firebase: 'The code is being confirmed by the app itself.',
};

function screenCode(info) {
  const code = field('Code', { inputMode: 'numeric', autofocus: true,
    maxLength: info.length || undefined });
  const note = [DELIVERY[info.delivery], info.phone && `Sent to ${info.phone}.`]
    .filter(Boolean).join(' ');
  return card('Enter the code', note || null,
    form(() => hooks.send('auth.code', { code: text(code.input.value) }),
      code.wrap, submit('Next')),
    info.nextDelivery
      ? el('div', { class: 'auth__aside' },
        link('Send the code another way', () => hooks.send('auth.resend')))
      : null);
}

function screenEmailAddress() {
  const email = field('Email', { type: 'email', autofocus: true });
  return card('Add a login email',
    'Telegram wants an email address for this account before it can '
    + 'send the confirmation code.',
    form(() => hooks.send('auth.email', { email: text(email.input.value) }),
      email.wrap, submit('Next')));
}

function screenEmailCode(info) {
  const code = field('Code', { inputMode: 'numeric', autofocus: true,
    maxLength: info.length || undefined });
  return card('Check your email',
    info.email ? `Telegram sent a code to ${info.email}.` : null,
    form(() => hooks.send('auth.emailCode', { code: text(code.input.value) }),
      code.wrap, submit('Next')));
}

function screenPassword(info) {
  // Two forms in one screen: the password, and - once a recovery code
  // has actually been sent - the code and the new password to replace
  // it with. Which of the two is showing is the server's answer
  // (recoverySent), not a click remembered here.
  if (info.recoverySent) {
    const code = field('Recovery code', { autofocus: true });
    const pass = field('New password', { type: 'password' });
    const hint = field('Hint (optional)');
    return card('Reset your password',
      `Telegram sent a recovery code to ${info.recoverySent}.`,
      form(() => hooks.send('auth.recoverCode', {
        code: text(code.input.value),
        password: text(pass.input.value),
        hint: text(hint.input.value),
      }), code.wrap, pass.wrap, hint.wrap, submit('Set the new password')));
  }

  const pass = field('Password', { type: 'password', autofocus: true });
  return card('Two-step verification',
    info.hint ? `Hint: ${info.hint}` : 'This account is protected by a password.',
    form(() => hooks.send('auth.password', { password: text(pass.input.value) }),
      pass.wrap, submit('Next')),
    info.hasRecovery
      ? el('div', { class: 'auth__aside' },
        link('Forgot the password?', () => hooks.send('auth.recover')))
      : el('p', { class: 'auth__note auth__note--dim' },
        'No recovery email is set for this account, so the password '
        + 'cannot be reset from here.'));
}

function screenRegistration(info) {
  const first = field('First name', { autofocus: true });
  const last = field('Last name (optional)');
  return card('Create your account',
    info.minAge ? `You must be at least ${info.minAge} to sign up.` : null,
    form(() => hooks.send('auth.register', {
      first: text(first.input.value), last: text(last.input.value),
    }), first.wrap, last.wrap, submit('Sign up')),
    info.tos ? el('p', { class: 'auth__tos' }, info.tos) : null);
}

const WAITING = {
  none: ['No account yet', 'Waiting for the application to create one…'],
  parameters: ['Starting up', 'Connecting to Telegram…'],
  loggingOut: ['Signing out', 'One moment…'],
  closing: ['Closing', 'One moment…'],
  closed: ['Signed out', 'This account has been closed.'],
};

function screenWaiting(state) {
  const [title, note] = WAITING[state] ?? ['Connecting', 'One moment…'];
  return card(title, note, el('div', { class: 'auth__spinner' }, icon('refresh')));
}

const SCREENS = {
  apiConfig: screenApiConfig,
  phone: screenPhone,
  qr: screenQr,
  code: screenCode,
  emailAddress: screenEmailAddress,
  emailCode: screenEmailCode,
  password: screenPassword,
  registration: screenRegistration,
};

// --------------------------------------------------------- the panel
/**
 * Draws the step, or takes the whole thing off screen once there is
 * an account to show.
 *
 * A step is only rebuilt when it CHANGES. The server re-announces the
 * same state for things that have nothing to do with the form - a QR
 * link renewing, an error arriving - and rebuilding on each of those
 * would take the half-typed code out of the box under the user.
 */
export function showAuth(info) {
  if (!root) return;
  const state = info?.state ?? 'none';
  if (state === 'ready') {
    root.hidden = true;
    current = null;
    clear(root);
    return;
  }

  root.hidden = false;
  const same = current !== null && screenKey(current) === screenKey(info);
  if (!same) {
    clear(root);
    const draw = SCREENS[state];
    root.append(el('div', { class: 'auth__backdrop' },
      draw ? draw(info) : screenWaiting(state)));
    // Аккаунт добавлен к уже имеющимся — вход можно отменить и вернуться
    // к прежнему (accounts.cancel).
    if (info?.canCancel && state !== 'apiConfig') {
      qs('.auth__card', root)?.append(
        link('Cancel and go back to the other account', () => hooks.send('accounts.cancel')));
    }
  }
  current = info;

  // The QR link is renewed every minute or so while that screen is up.
  // Swapping the image is the whole update; rebuilding the card around
  // it would only make it blink.
  const square = qs('.auth__qr', root);
  if (square && info.qrImage && square.src !== info.qrImage) {
    square.src = info.qrImage;
  }

  // The error belongs to the step, and is the one part that is worth
  // updating without a rebuild.
  const card = qs('.auth__card', root);
  if (!card) return;
  let line = qs('.auth__error', card);
  if (!info.error) {
    line?.remove();
    return;
  }
  if (!line) {
    line = el('p', { class: 'auth__error' });
    card.append(line);
  }
  line.textContent = info.error;
}

/** hooks: { send(cmd, args) } */
export function mountAuth(node, options) {
  root = node;
  hooks = options ?? {};
  root.hidden = true;
}
