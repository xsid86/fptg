Noto Color Emoji
================

Google's emoji font, so the web UI draws emoji the same way the native
window does - that one has drawn them from Noto (emoji_atlas.dat) since
the Twemoji atlas was replaced by direct request.

WHAT IS HERE
    noto-color-emoji.N.woff2   the COLRv1 build, 11 slices by codepoint
    OFL.txt                    SIL Open Font License 1.1

WHERE IT CAME FROM
Google Fonts' own CSS API, asked as a current Chromium would ask:

    curl -A "<a Chrome UA>" \
      "https://fonts.googleapis.com/css2?family=Noto+Color+Emoji"

which answers with one @font-face per slice. The files here are those
slices, byte for byte, renamed from their content hashes to a readable
number. The matching @font-face rules live in
assets/scss/vendor/_noto-emoji.scss and are generated from the same
CSS - urls rewritten to point here, unicode-range kept exactly.

WHY NOT THE .TTF
google/fonts ships NotoColorEmoji-Regular.ttf at 25 MB: that is the
bitmap (CBDT) build. These COLRv1 slices come to 2.1 MB in total, and a
page only fetches the ones its text actually needs.

NOT FIRST IN THE FONT STACK, DELIBERATELY
The font covers more than emoji - slice 2's range includes U+23, U+2A
and U+30..39, i.e. '#', '*' and the digits, because those are the bases
of the keycap sequences. First in the stack it would draw every plain
digit in the UI as emoji art. It goes at the END of the text stack
instead, where the text fonts have already claimed those characters and
only the emoji fall through to it. The native side learned the same
lesson from the other direction - see the note on Emoji_Component in
emojiassets.pas.
