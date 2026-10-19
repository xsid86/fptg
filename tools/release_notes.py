"""Release notes from the commit messages since the previous tag.

    python tools/release_notes.py v0.9.6        (prints the notes)

Commit messages are wrapped at about 72 columns; in a release description
or a Telegram post those breaks fall in the middle of sentences. The
wrapped lines are joined back: a paragraph becomes one line, a "- " list
item becomes one line, blank lines between paragraphs stay.

The tag may not exist yet (a release built by hand): then HEAD is used.
"""
import subprocess
import sys


def git(*args):
    r = subprocess.run(['git', *args], capture_output=True, text=True, encoding='utf-8')
    return r.stdout if r.returncode == 0 else None


def unwrap(text):
    out = []
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line:
            if out and out[-1] != '':
                out.append('')
            continue
        stripped = line.lstrip()
        new_item = stripped.startswith(('- ', '* '))
        continues = out and out[-1] != '' and not new_item
        if continues:
            out[-1] += ' ' + stripped
        else:
            out.append(stripped if new_item else line)
    while out and out[-1] == '':
        out.pop()
    return '\n'.join(out)


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: release_notes.py <tag>')
    tag = sys.argv[1]
    ref = tag if git('rev-parse', '-q', '--verify', f'refs/tags/{tag}') else 'HEAD'
    prev = (git('describe', '--tags', '--abbrev=0', f'{ref}^') or '').strip()
    if prev:
        log = git('log', '--no-merges', '--format=%B%n', f'{prev}..{ref}')
    else:
        log = git('log', '--no-merges', '--format=%B', '-n', '1', ref)
    sys.stdout.reconfigure(encoding='utf-8')
    print(unwrap(log or ''))


if __name__ == '__main__':
    main()
