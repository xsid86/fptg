import { el } from '../core/dom.js';

// Syntax highlighting for code blocks, on the language TDLib already
// tells us (textEntityTypePreCode carries it - see the entry of
// 2026-09-23 in the development log).
//
// PRISM, NOT highlight.js, AND FOR ONE REASON: highlight.js returns
// its result as a string of HTML, which would mean innerHTML on text
// written by a stranger. This app parses markup in exactly one place
// and it is our own icon sheet (see core/dom.js). Prism.tokenize
// returns a TREE OF TOKENS instead, so the nodes below are built with
// the same el() as everything else and nothing is ever parsed.
//
// The files are the stock ones from the npm package, unmodified, so
// updating Prism stays a file copy. They are classic scripts, not
// modules - that is how Prism ships - so they are loaded with a script
// tag rather than import(), and only when a block of that language
// actually turns up.

const VENDOR = 'assets/vendor/prism/';

// Language -> the files to load, in order. Taken from the package's
// own components.json rather than from memory: php really does need
// markup-templating, which needs markup, and cpp goes through c.
const CHAIN = {
    bash: ['bash'],
    c: ['clike', 'c'],
    clike: ['clike'],
    cpp: ['clike', 'c', 'cpp'],
    csharp: ['clike', 'csharp'],
    css: ['css'],
    diff: ['diff'],
    docker: ['docker'],
    go: ['clike', 'go'],
    ini: ['ini'],
    java: ['clike', 'java'],
    javascript: ['clike', 'javascript'],
    json: ['json'],
    kotlin: ['clike', 'kotlin'],
    lua: ['lua'],
    markdown: ['markup', 'markdown'],
    markup: ['markup'],
    nginx: ['nginx'],
    pascal: ['pascal'],
    perl: ['perl'],
    php: ['markup', 'markup-templating', 'php'],
    powershell: ['powershell'],
    python: ['python'],
    ruby: ['clike', 'ruby'],
    rust: ['rust'],
    sql: ['sql'],
    swift: ['swift'],
    typescript: ['clike', 'javascript', 'typescript'],
    yaml: ['yaml'],
};

// What people actually type after ``` , mapped onto the above. Prism's
// own alias list plus the spellings a person is likely to use.
const ALIAS = {
    'c++': 'cpp', 'c#': 'csharp', cs: 'csharp', dotnet: 'csharp',
    delphi: 'pascal', objectpascal: 'pascal', dockerfile: 'docker',
    html: 'markup', htm: 'markup', js: 'javascript', kt: 'kotlin',
    kts: 'kotlin', md: 'markdown', node: 'javascript', objpas: 'pascal',
    postgres: 'sql', postgresql: 'sql', ps1: 'powershell', py: 'python',
    rb: 'ruby', sh: 'bash', shell: 'bash', svg: 'markup', ts: 'typescript',
    webmanifest: 'json', xml: 'markup', yml: 'yaml', zsh: 'bash',
};

const loaded = new Map();   // file name -> promise of it being there
let core = null;

function loadScript(name) {
    let known = loaded.get(name);
    if (known) return known;
    known = new Promise((resolve, reject) => {
        document.head.append(el('script', {
            src: `${VENDOR}prism-${name}.min.js`,
            async: false,
            onload: () => resolve(),
            onerror: () => reject(new Error(`prism: ${name}`)),
        }));
    });
    loaded.set(name, known);
    return known;
}

function loadCore() {
    if (!core) {
        // Before the core runs, or it goes hunting through the whole
        // document for things to highlight on load. This page hands it
        // strings and builds the DOM itself.
        window.Prism = window.Prism || {};
        window.Prism.manual = true;
        core = loadScript('core').then(() => window.Prism);
    }
    return core;
}

/** The token tree, as elements. Prism nests, so this does too. */
function toNodes(tokens) {
    const frag = document.createDocumentFragment();
    for (const token of [].concat(tokens)) {
        if (typeof token === 'string') {
            frag.append(document.createTextNode(token));
            continue;
        }
        const names = ['tok', `tok--${token.type}`]
            .concat([].concat(token.alias ?? []).map((a) => `tok--${a}`));
        const span = el('span', { class: names.join(' ') });
        span.append(typeof token.content === 'string'
            ? document.createTextNode(token.content)
            : toNodes(token.content));
        frag.append(span);
    }
    return frag;
}

/**
 * Highlighted `code`, or null when the language is unknown to us or
 * anything goes wrong - the caller then keeps the plain block, which
 * is a complete answer on its own.
 */
export async function highlight(code, language) {
    const key = String(language || '').trim().toLowerCase();
    const name = ALIAS[key] ?? key;
    const chain = CHAIN[name];
    if (!chain) return null;

    try {
        const prism = await loadCore();
        // In order: a grammar that requires another one is not there
        // until the one it requires has run.
        for (const part of chain) {
            await loadScript(part);
        }
        const grammar = prism.languages[name];
        if (!grammar) return null;
        return toNodes(prism.tokenize(code, grammar));
    } catch {
        return null;
    }
}
