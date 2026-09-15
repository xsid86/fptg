unit constants;

{$mode objfpc}{$H+}

{ All named constants for the project, grouped by source unit and topic.
  This unit deliberately imports nothing project-specific (only Graphics,
  for TColor in the color palettes), so it sits at the bottom of the
  dependency graph: any unit can "uses constants" without creating a
  cycle.

  Constants keep the names and per-group order they had in their
  original unit, including cross-references between constants, except
  for one explicit name collision (COALESCE_MS was declared separately
  in tdchats.pas and tdmessages.pas — see CHATS_COALESCE_MS /
  MESSAGES_COALESCE_MS below). The avatarcache group comes first because
  later groups reference it (CHATROW_HEADER_BAR_H in the framechats.pas
  group, via AVATAR_SIZE).

  The framehistory.pas group comes before framechats.pas because the
  chat-row constants (CHATROW_HEADER_BAR_H etc.) are computed from
  HEADER_PAD_V/MSG_PAD_V/REPLY_LINE_H/MSG_CORNER_RADIUS in the
  framehistory.pas group — the same ordering constraint that already
  requires avatarcache to come first (a constant cannot reference
  something declared later in the same const block). }

interface

uses
  Graphics;

const

  { ================= avatarcache.pas ================= }

  { Avatar size in the chat list's content area, beside the last-message
    preview (moved there from the header during the card redesign — see
    CLAUDE.md). The archive/all-chats pseudo-row uses its own, larger
    BIG_AVATAR_SIZE (framechats.pas group below), independent of this
    value. Sole real reader: TAvatarCache.Render (avatarcache.pas).
    24->32 by direct request — CHATROW_CONTENT_H (below) is derived
    from this, so the row grows taller automatically, not a separate
    number to keep in sync by hand. }
  AVATAR_SIZE = 44;
  { Cache key is the chat id. The cap bounds memory: bitmaps, not list
    entries, and scrolling a long list has a real cost. }
  DEFAULT_CAPACITY = 200;
  { BGRABitmap coordinates are pixel-centered: pixel 0's center sits at
    0, so drawing spans -0.5 to SIZE-0.5. A circle centered at SIZE/2
    with radius SIZE/2 would extend past the right/bottom edge and get
    clipped. }
  AV_CENTER = (AVATAR_SIZE - 1) / 2;
  AV_RADIUS = AVATAR_SIZE / 2;

  PALETTE: array[0..6] of TColor = (
    TColor($5B8BE3), TColor($5FBF6B), TColor($4B5FE8),
    TColor($C77BD8), TColor($D8B24B), TColor($5BC2D8), TColor($6B6BE8));

  { ================= framehistory.pas ================= }

  MSG_PAD_H      = 11;
  MSG_PAD_V      = 6;
  MSG_GAP        = 16;
  { Message column width cap: on a wide window text is not stretched
    full width (unreadable) but centered in a narrow column. 0 means no
    cap, full frame width (see ColumnBounds). }
  MAX_MSG_W      = 600;
  { HEADER_H is the height of the header icon/text itself (used to
    center content within it). HEADER_PAD_V is the header's own
    top/bottom padding inside its colored backing, independent of
    MSG_GAP (the gap between messages) — two visually similar but
    distinct paddings. HEADER_BAR_H is the total space the header
    occupies in the block. }
  HEADER_H       = 16;
  HEADER_PAD_V   = 6;
  HEADER_BAR_H   = HEADER_H + 2 * HEADER_PAD_V;
  NEAR_TOP_PX    = 400;
  WHEEL_LINE_PX  = 60;
  LINE_SCROLL_PX = 24;
  { Corner rendering: antialiased (BGRA, composited via a temporary
    TBGRABitmap) or plain GDI Canvas.RoundRect. Radii elsewhere in this
    file are unaffected by either — only the drawing method changes,
    never the numbers.

    TWO independent switches, deliberately, because the two groups they
    cover have completely different cost profiles:

    SMOOTH_CORNERS — everything INSIDE the message history: the message
    block, its header strip, forward cards, reply quotes, audio/file
    widgets. Up to a dozen rounded rectangles per message, redrawn on
    every scroll frame. This is what tearing/stutter while scrolling
    was traced to, confirmed by the user on a real run ("отрисовка
    рвалась именно из-за bgrabitmap"), and it stays OFF.

    SMOOTH_CHROME_CORNERS — the frame AROUND the history: chat list row
    cards, the chat info bar's card, the message history's own outer
    corners. A handful of rectangles, on elements that don't
    re-composite per message, so the cost that made the other one
    unaffordable simply isn't there — and these are the corners the eye
    actually rests on. ON.

    They used to be one switch; splitting them was a direct request
    once the background stopped being white and GDI's jagged arcs
    became obvious on the outer cards. }
  SMOOTH_CORNERS = False;
  SMOOTH_CHROME_CORNERS = True;
  { Switches message/quote/forward-card rendering between two body
    styles. True: no background fill or outline on the message body /
    forward card / reply quote — only the header row (icon+name+time
    for a message, avatar+name+time for a forward, icon+name for a
    reply quote) keeps a colored backing and outline. False (current):
    the whole block/card/box gets a background fill (SENDER_BG_OPACITY)
    and outline (SENDER_BORDER_OPACITY). Both code paths are kept in
    framehistory.pas (`if not new_style` / `if new_style`) for
    comparison; removing the old path is a separate follow-up. }
  new_style = false;
  { Corner radius for the message block / header backing. }
  MSG_CORNER_RADIUS = 7;
  { Slot reserved for the status icon in the header even for incoming
    messages (which have no icon, crNone) so the sender name doesn't
    shift horizontally row to row. }
  MSG_ICON_W     = 16;
  MSG_ICON_GAP   = 4;

  { Forward-card quote (a message with forward_info) — its own frame
    inside the block, with its own smaller radius and its own gap from
    the message's main header. Remaining inner paddings reuse
    MSG_PAD_H/MSG_PAD_V/HEADER_BAR_H: structurally the quote is the
    same "header+content" shape as the whole block, just nested and
    smaller, so it needs no second set of paddings.
    FORWARD_HEADER_GAP is tied to MSG_PAD_H rather than being its own
    number so the quote's horizontal and vertical padding stay visually
    equal even if MSG_PAD_H is retuned later. }
  FORWARD_CORNER_RADIUS = 4;
  FORWARD_HEADER_GAP    = MSG_PAD_H;

  { Reply quote (reply_to) — a compact box above the message content:
    quote icon + replied sender's name + first line of their text,
    using the same backing/outline treatment as the forward card
    (distinct from FORWARD_*: TDLib sends a full source-context object
    for a forward, while a reply is just a reference to an earlier
    message in the same chat, closer to how the official client
    renders replies). Icon offset from the box's left edge and from
    icon to text uses MSG_PAD_H/MSG_ICON_GAP, top offset uses
    HEADER_PAD_V — the same constants and placement as the icon in the
    main message header (HeaderX := BR.Left + MSG_PAD_H, HeaderY :=
    BR.Top + HEADER_PAD_V, see Paint) and the avatar in the forward
    header (AvX/AvY in PaintForwardCard). Height is two fixed text
    rows, no word-wrap — name and text are truncated with an ellipsis
    instead of wrapping. REPLY_CORNER_RADIUS was split out from the
    shared FORWARD_CORNER_RADIUS so each card type can be tuned
    independently; the value (8) is unchanged. }
  REPLY_LINE_H  = 15;
  REPLY_BOX_H   = 2 * REPLY_LINE_H + 2 * HEADER_PAD_V;
  REPLY_CORNER_RADIUS = 4;

  { Reaction strip (TMsgScroller.PaintReactions/ReactionsRect,
    framehistory.pas) — the row of reaction chips ("👍 3  ❤ 1  ...")
    below a message's content, present only when the message actually
    has reactions. The OUTER strip is visually the same as the message
    header (background tint, height) by direct request — reuses
    HEADER_BAR_H/HEADER_PAD_V/SENDER_HEADER_OPACITY as-is, not its own
    set of numbers. REACTION_GAP is the gap between two separate chips;
    the gap from a chip's emoji to its own count reuses MSG_ICON_GAP
    (the same role it already plays for the status icon in the main
    header).

    Each INDIVIDUAL chip additionally gets its own pill/capsule outline
    — a second, later request, closer to the native client's look:
    tinted with the sender's color, own opacity for a plain reaction
    vs. one this account has added (REACTION_PILL_OPACITY vs.
    REACTION_PILL_CHOSEN_OPACITY — both by direct, exact request, not
    reused from SENDER_BG_OPACITY/SENDER_HEADER_OPACITY: a chip needs
    to read as its own control, distinctly more prominent than the
    header strip it sits on). REACTION_PILL_H (22, by direct request)
    is smaller than HEADER_BAR_H — the pill sits inset within the
    taller outer strip, not flush with it. REACTION_PILL_PAD is the
    pill's own inner horizontal padding (icon/text to the pill's own
    edge), a new, third padding value distinct from MSG_PAD_H (the
    strip's own inset from the block's edge) and REACTION_GAP (the gap
    between pills). REACTION_PILL_CORNER_RADIUS is its own knob, not
    inlined as "REACTION_PILL_H div 2" at the call site — split out by
    direct request, the same reasoning as every other *_CORNER_RADIUS
    in this file (MSG_CORNER_RADIUS, FORWARD_CORNER_RADIUS, ...): tuned
    independently later without touching the drawing code. Currently
    still equal to half the pill's height (a full capsule, semicircular
    ends) — PaintReactions clamps it further by half the pill's own
    WIDTH at the call site, so a narrower value here stays a true
    capsule instead of distorting on a short pill.

    Reactions wrap onto multiple rows when they don't fit the column
    width (LayoutReactions) — REACTION_ROW_GAP is the vertical gap
    between two wrapped rows, reusing MSG_ICON_GAP's small value (the
    same role it already plays elsewhere: a tight gap around a small
    element, not the much larger MSG_GAP between whole messages). The
    strip's total height for N rows is HEADER_BAR_H + (N-1)*
    (REACTION_PILL_H + REACTION_ROW_GAP) — for N=1 (the common case)
    that's exactly HEADER_BAR_H, unchanged from before wrapping existed. }
  REACTION_GAP = MSG_PAD_H;
  REACTION_PILL_H = 22;
  REACTION_PILL_PAD = 8;
  REACTION_PILL_CORNER_RADIUS = 11;
  REACTION_PILL_OPACITY = 0.3;
  REACTION_PILL_CHOSEN_OPACITY = 0.6;
  REACTION_ROW_GAP = MSG_ICON_GAP;

  { Sender color wheel — the one place in the file that would need
    touching for a dark theme (a full theming layer isn't built yet,
    but colors are kept out of the paint code as scattered literals).
    TColor is $00BBGGRR, so each entry carries its RGB name in a
    comment for readability. }
  SENDER_PALETTE: array[0..7] of TColor = (
    $2222B2,  { RGB(178, 34, 34)  firebrick }
    $228B22,  { RGB( 34,139, 34)  forest green }
    $A0501E,  { RGB( 30, 80,160)  steel blue }
    $800080,  { RGB(128,  0,128)  purple }
    $005AB4,  { RGB(180, 90,  0)  dark orange }
    $808000,  { RGB(  0,128,128)  teal }
    $8515C7,  { RGB(199, 21,133)  medium violet red }
    $008080   { RGB(128,128,  0)  olive }
  );
  { How strongly the sender color shows through the block backing —
    0.1 = 10% color over background, the rest clBackground. Kept as a
    constant rather than hardcoded in BlendWithBackground for the same
    reason as SENDER_PALETTE — easy to retune for a dark theme or taste. }
  SENDER_BG_OPACITY = 0.1;
  { The header row's own backing (icon+name) is more prominent than the
    block background — its own, higher opacity level. }
  SENDER_HEADER_OPACITY = 0.2;
  { Block outline — sender color over background, noticeably stronger
    than the fills above (0.5): a defining border, not a tint. }
  SENDER_BORDER_OPACITY = 0.5;

  { Audio widget (TAudioWidget) — same backing/outline treatment as the
    reply-quote box (SENDER_BG_OPACITY/SENDER_BORDER_OPACITY, same
    inner padding MSG_PAD_H), but its own fixed base color rather than
    the message sender's: the same color for any audio. TColor is
    $00BBGGRR, so #03A9F4 (RGB) is stored byte-reversed. }
  AUDIO_COLOR = $F4A903;  { RGB(3, 169, 244) — Material light blue 500 }
  { Split out from the shared FORWARD_CORNER_RADIUS so each card type
    can be tuned independently; the value (8) is unchanged. }
  AUDIO_CORNER_RADIUS = 4;
  { Frame indices in TFrameHistory.ImageList1 (32x32, play/pause
    buttons — its own list, not framechats.ImageList1). }
  AUDIO_ICON_PLAY     = 0;
  AUDIO_ICON_PAUSE    = 1;
  { "Download" icon — reused by TFileWidget (framehistory.pas) for a
    document not yet downloaded to disk; same ImageList1 as play/pause,
    not a separate list. }
  AUDIO_ICON_DOWNLOAD = 2;
  { Frames for the built-in viewer (mediaviewer.pas), added to the same
    ImageList1 as play/pause/download: "«" — previous photo, "»" — next
    photo, red cross — close the viewer. }
  VIEWER_ICON_PREV  = 3;
  VIEWER_ICON_NEXT  = 4;
  VIEWER_ICON_CLOSE = 5;
  AUDIO_BUTTON_SIZE = 32;

  { Transport-button row under the video widget's scrub bar
    (TVideoWidget, framehistory.pas) — viewer only (FIsActive=True
    there; in the chat the widget is never active and the row is not
    drawn at all). Frames come from TFrameHistory.ImageList2 (32x32,
    replacing the older 16x16 "playback" list, which stays unused in
    the .lfm) — 6 slots left to right (previous video / -10s /
    play-pause / repeat / +10s / next video); frame order was confirmed
    by unpacking the Bitmap blob from framehistory.lfm and visually
    inspecting the frames, the same method used for icons12/
    framechats.pas — not guessed. Four of the six slots are
    unavailable/available (gray/blue) pairs; play/pause is just two
    state icons; repeat has three states (off/repeat-all/repeat-one),
    not an availability pair. }
  PLAYBACK_ICON_PREV_OFF    = 0;
  PLAYBACK_ICON_PREV_ON     = 1;
  PLAYBACK_ICON_BACK10_OFF  = 2;
  PLAYBACK_ICON_BACK10_ON   = 3;
  PLAYBACK_ICON_PAUSE       = 4;
  PLAYBACK_ICON_PLAY        = 5;
  PLAYBACK_ICON_REPEAT_OFF  = 6;
  { "Repeat all" is a plain looping arrow, "repeat one" is the same
    arrow with a small "1" inside (visible in the frame itself). }
  PLAYBACK_ICON_REPEAT_ALL  = 7;
  PLAYBACK_ICON_REPEAT_ONE  = 8;
  PLAYBACK_ICON_FWD10_OFF   = 9;
  PLAYBACK_ICON_FWD10_ON    = 10;
  PLAYBACK_ICON_NEXT_OFF    = 11;
  PLAYBACK_ICON_NEXT_ON     = 12;
  { Seconds the -10s/+10s buttons skip. }
  PLAYBACK_SKIP_SEC   = 10;
  PLAYBACK_BTN_SIZE   = 32;   { native ImageList2 frame size (was 16 for the old "playback" list) }
  PLAYBACK_BTN_GAP    = 16;   { gap between adjacent buttons in the row }
  { Progress bar and its thumb. }
  AUDIO_TRACK_H = 2;
  AUDIO_THUMB_W = 3;
  AUDIO_THUMB_H = 6;
  { Played portion and the thumb itself are more prominent than the
    unplayed remainder (0.75 vs 0.25), both using AUDIO_COLOR. }
  AUDIO_PLAYED_OPACITY = 0.75;
  AUDIO_REMAIN_OPACITY = 0.25;
  { File widget (TFileWidget) — same pattern as AUDIO_CORNER_RADIUS
    above: split out from the shared FORWARD_CORNER_RADIUS into its own
    knob. }
  FILE_CORNER_RADIUS = 4;

  { Chat info header bar, above the message history (TFrameHistory,
    framehistory.pas / chatheader.pas) — built to be visually the SAME
    card as one row of the chat list, by direct request: same outer gap
    (CHATROW_GAP), same corner radius (CHATROW_CORNER_RADIUS), same
    header strip on top (CHATROW_HEADER_BAR_H, carrying the chat-type
    icon/name/id/pin/mute/"more"), same content area below it
    (CHATROW_CONTENT_H, sized around AVATAR_SIZE), and the same inner
    paddings throughout (MSG_PAD_H horizontally, MSG_PAD_V vertically,
    GAP between header icons). None of those are duplicated here —
    chatheader.pas reads the chat-list constants directly, so the two
    can't drift apart. Only the two numbers with no chat-list
    equivalent live here: the filter icons' own frame size, and the gap
    between them. }
  { FilterButtons' native frame size (TImageList, 32x32,
    framehistory.lfm) — the filter buttons are drawn at their natural
    size, NOT scaled to AVATAR_SIZE: the avatar next to them is a 44px
    photo, these are 32px glyphs, two different things that happen to
    share a row. }
  CHAT_HEADER_FILTER_SIZE = 32;
  { Gap between two adjacent filter buttons — deliberately its own knob
    (not GAP/MSG_ICON_GAP) so this one row can be tuned without
    touching anything else; 5 by direct request. }
  CHAT_HEADER_FILTER_GAP  = 5;
  { This bar's avatar is 48, not the chat list's own AVATAR_SIZE (44) —
    by direct request; the content area is sized around it exactly the
    way CHATROW_CONTENT_H is sized around AVATAR_SIZE. }
  CHAT_HEADER_AVATAR_SIZE = 48;
  CHAT_HEADER_CONTENT_H   = CHAT_HEADER_AVATAR_SIZE + 2 * MSG_PAD_V;
  { The card's gap from the bar's own edges — one knob per side, NOT one
    shared number: they were briefly folded into a single constant and
    tuning the top silently moved the other two, which is not wanted.
    Right/bottom are matched by eye to the "floating" margin the
    history's thin scrollbar has right below this bar
    (THIN_SCROLLBAR_MARGIN, same value — declared further down this
    file, so it can't be referenced from here). There is deliberately NO
    left margin: that edge is flush with the message history area
    underneath. All by direct request.

    The top was briefly 3 rather than 5 — asked for back when the
    background behind the card was white and the gap was invisible
    anyway; once the background became a real (and configurable) color
    the odd one out was obvious, and it went back to matching the other
    two. }
  CHAT_HEADER_CARD_MARGIN_TOP    = 5;
  CHAT_HEADER_CARD_MARGIN_RIGHT  = 5;
  CHAT_HEADER_CARD_MARGIN_BOTTOM = 5;
  { Frame indices in FilterButtons (TImageList, 32x32, framehistory.lfm)
    — order confirmed by unpacking and visually inspecting the Bitmap
    blob (the same verification method already established in this
    project for icons12/playback/FILE_ICONS — not guessed from the
    designer screenshot alone), one frame per row-2 filter button, in
    the exact order they were added. Nine of them plus the search box
    map onto one TDLib request (searchChatMessages with a different
    SearchMessagesFilter — see TD_MSG_FILTER_* below); gifts, saved and
    similar-channels are the three that don't (their TDLib answers
    aren't messages at all: receivedGifts, savedMessagesTopic history
    and a list of chat ids respectively) and are still stubs. }
  CHAT_HEADER_FILTER_GIFTS   = 0;
  CHAT_HEADER_FILTER_SAVED   = 1;
  CHAT_HEADER_FILTER_PHOTOS  = 2;
  CHAT_HEADER_FILTER_VIDEOS  = 3;
  CHAT_HEADER_FILTER_FILES   = 4;
  CHAT_HEADER_FILTER_AUDIO   = 5;
  CHAT_HEADER_FILTER_LINKS   = 6;
  CHAT_HEADER_FILTER_POLLS   = 7;
  CHAT_HEADER_FILTER_VOICE   = 8;
  CHAT_HEADER_FILTER_GIF     = 9;
  { Only meaningful for channels (ckChannel) — hidden for every other
    chat kind, not merely disabled, per direct request. }
  CHAT_HEADER_FILTER_SIMILAR = 10;
  CHAT_HEADER_FILTER_PINNED  = 11;

  { TDLib SearchMessagesFilter constructor names, passed straight into
    searchChatMessages' filter parameter (TTdMessages.SetSearchFilter).
    Spellings taken from the real td_api.tl (github.com/tdlib/td), not
    from memory — a wrong one is not a compile error, it is a runtime
    code-400 with an empty list and no other clue.

    "Empty" is a real filter, not the absence of one: it is what a
    plain text query with no type restriction uses. There is no "gifts"
    or "similar channels" member of this family at all — those are
    different requests entirely, which is why those buttons are still
    stubs. }
  TD_MSG_FILTER_EMPTY     = 'searchMessagesFilterEmpty';
  TD_MSG_FILTER_PHOTO     = 'searchMessagesFilterPhoto';
  TD_MSG_FILTER_VIDEO     = 'searchMessagesFilterVideo';
  TD_MSG_FILTER_DOCUMENT  = 'searchMessagesFilterDocument';
  TD_MSG_FILTER_AUDIO     = 'searchMessagesFilterAudio';
  TD_MSG_FILTER_URL       = 'searchMessagesFilterUrl';
  TD_MSG_FILTER_POLL      = 'searchMessagesFilterPoll';
  TD_MSG_FILTER_VOICE     = 'searchMessagesFilterVoiceNote';
  TD_MSG_FILTER_ANIMATION = 'searchMessagesFilterAnimation';
  TD_MSG_FILTER_PINNED    = 'searchMessagesFilterPinned';

  { ================= framechats.pas ================= }

  { Frame indices in icons12 (TImageList, 12x12, separate from
    ImageList1 — added for the chat-row redesign that mirrors the
    message-block look). Order confirmed by unpacking the Bitmap blob
    from framechats.lfm and visually inspecting the frames, the same
    method used for the playback list above — not guessed. The six
    original frames (channel/group/bot/private/notify_on/notify_off)
    keep the same order they had in ImageList1; pin/unpin were appended. }
  CHATROW_ICON_CHANNEL    = 0;
  CHATROW_ICON_GROUP      = 1;
  CHATROW_ICON_BOT        = 2;
  CHATROW_ICON_PRIVATE    = 3;
  CHATROW_ICON_NOTIFY_ON  = 4;
  CHATROW_ICON_NOTIFY_OFF = 5;
  { Which of the two new frames is "pinned" vs "unpinned" follows the
    notify_on/notify_off convention (solid icon = state on, crossed-out
    = state off) by analogy, not confirmed against a dedicated
    screenshot; swapping them is a trivial fix if it turns out reversed. }
  CHATROW_ICON_PIN        = 6;
  CHATROW_ICON_UNPIN      = 7;
  { Icon shown in the "chat type" slot for the "Archive"/"All chats"
    pseudo-rows — an archive box and a "back" double-arrow, added
    alongside pin/unpin, order confirmed the same way (Bitmap-blob
    unpack + visual inspection). }
  CHATROW_ICON_ARCHIVE    = 8;
  CHATROW_ICON_ALLCHATS   = 9;
  { Native frame size for icons12 — matches the component's own
    Height/Width in the designer. }
  CHATROW_ICON_SIZE = 12;
  { Premium crown badge, shown right after the chat-type icon
    (TypeIconIndex) for a private chat whose peer is a Telegram Premium
    user (TTdChats.IsPremiumUser, tdchats.pas) — NOT a frame in icons12:
    it lives in FormMain.ImageList1 (16x16, the main FORM's own icon
    list, already reused across units the same way framehistory.pas
    reuses FormMain.Chats.ImageList1 for message-status icons — see that
    group's own comment below). Index confirmed by unpacking the
    Bitmap blob from main.lfm and visually inspecting all 11 frames
    (same method as CHATROW_ICON_*/PLAYBACK_ICON_* above), not guessed:
    frame 10 is a gold crown, added alongside the two presence icons
    (PRESENCE_ICON_ONLINE/INVISIBLE = 8/9 in main.pas's
    StatusBar1DrawPanel). Drawn at its native 16x16 size — larger than
    CHATROW_ICON_SIZE (12), same as the deliberate "crown reads as a
    slightly bigger badge" look in the official client, not an
    oversight. }
  PREMIUM_CROWN_ICON = 10;

  { 6..10 — message status/direction icons in framehistory.pas, the
    same ImageList1 object (via FormMain.Chats.ImageList1) that
    framechats.pas no longer reads by name after the chat-row redesign
    (see CHATROW_ICON_* above) — the component and frames 0-5 in it
    were left untouched in the designer; framehistory.pas simply
    ignores them.
    TODO: the values below are a placeholder — confirm and adjust once
    real frames are added in the designer if they end up laid out
    differently. }
  ICON_MSG_SENT     = 6;
  ICON_MSG_READ     = 7;
  ICON_MSG_PENDING  = 8;
  ICON_MSG_FAILED   = 9;
  { Incoming message — not a delivery status (there is none for someone
    else's message), just a direction marker so the slot before the
    name isn't empty for half the rows, matching the original QIP-style
    reference screenshot. }
  ICON_MSG_INCOMING = 10;
  { Reply-quote icon (reply_to) in framehistory.pas —
    TMsgScroller.PaintReplyBox. Placeholder index until a real frame is
    added in the designer, same convention as ICON_MSG_* above. }
  ICON_QUOTE        = 11;

  BADGE_H  = 18;
  BADGE_PAD = 7;
  BADGE_FONT_H = 12;
  BADGE_CACHE_MAX = 64;
  { Read receipt — the same checkmarks as before (ReceiptBitmap is
    untouched by the redesign). }
  TICK_W   = 12;   { width of a single checkmark }
  TICK_H   = 11;
  TICK_SHIFT = 5;    { offset of the second checkmark for "read" }
  TICK_PEN = 1.6;
  GAP      = 6;
  { How many rows before the end to request the next page. }
  PREFETCH_ROWS = 6;
  { Archive always occupies row 0, matching the official client. }
  ARCHIVE_ROWS = 1;

  { Chat-row card — the same visual language as the message block
    (framehistory.pas group above): header (chat-type icon + avatar +
    name + badges) + content area (preview), rounding, background/
    outline colored by the chat's accent (accent_color_id, the same
    approach as ResolveAccentColor/SenderColor in framehistory.pas —
    framechats.pas cannot import framehistory.pas, since the latter
    already imports framechats.pas, so ChatAccentColor in framechats.pas
    keeps its own copy of that logic rather than sharing a function).
    Inner paddings are literally the same constants used for messages
    (MSG_PAD_H/MSG_PAD_V/HEADER_PAD_V/MSG_ICON_GAP), which is why this
    group is placed after framehistory.pas (see file header). The gap
    between cards is separate and much smaller (4px, not MSG_GAP=16 —
    a contact list needs higher density). }
  { The same gap doubles as the spacing BETWEEN cards and as the card's
    inset from the list's left/right edge — one number, both roles, see
    ChatRowRects (framechats.pas). }
  CHATROW_GAP = 4;
  { Extra breathing room around EVERY side of the card, on top of
    CHATROW_GAP, by direct request. Kept separate rather than folded
    into CHATROW_GAP because that one is two roles at once: growing it
    would widen the gap BETWEEN cards by twice as much as the inset
    from the list's edge. This one is symmetrical — the same number on
    all four sides — and ROW_HEIGHT below accounts for its vertical
    half, so the card keeps its height instead of being squeezed. }
  CHATROW_CARD_INSET = 1;
  { The gap above the FIRST card and below the LAST one — the list's
    own outer margin, not the spacing between cards, and specifically
    chosen to line the first card up with the chat header card's own
    top margin (CHAT_HEADER_CARD_MARGIN_TOP) across the splitter.

    Separate from the inter-card spacing on purpose: the gap between
    neighbours is the sum of two rows' insets and reads as one gap,
    while the outer edge only ever gets one row's worth. Applied as
    BorderSpacing on the grid (framechats.pas), minus what the row
    already contributes — growing the row inset instead would have
    moved the gap between cards along with it. }
  CHATLIST_EDGE_MARGIN = 5;
  { Card header height — the avatar moved into the content area (see
    CHATROW_CONTENT_H below), leaving only the type icon + name +
    badges in the header — the same "content height + own vertical
    padding" shape as the message header, so this is now literally the
    same value rather than a separately computed copy. }
  CHATROW_HEADER_BAR_H = HEADER_BAR_H;
  { Preview area — the avatar (24px) lives here, next to the preview
    text, so row height is computed from the avatar the same way the
    header height used to be computed (AVATAR_SIZE + its own vertical
    padding, MSG_PAD_V here plays the same role as in message content).
    The text line (REPLY_LINE_H-sized) fits within this same height,
    vertically centered next to the avatar — no separate constant for
    it. }
  CHATROW_CONTENT_H = AVATAR_SIZE + 2 * MSG_PAD_V;
  CHATROW_CARD_H = CHATROW_HEADER_BAR_H + CHATROW_CONTENT_H;
  ROW_HEIGHT = CHATROW_CARD_H + CHATROW_GAP + 2 * CHATROW_CARD_INSET;
  { Card corner radius — its own knob, not MSG_CORNER_RADIUS directly
    (same principle as FORWARD/REPLY/AUDIO/FILE_CORNER_RADIUS above —
    each card type tunable independently), initial value matches
    messages. }
  CHATROW_CORNER_RADIUS = MSG_CORNER_RADIUS;
  { Selection fill behind the card uses the chat's own accent color
    (ChatAccentColor), not the system clHighlight. The card itself
    (body/header/outline) no longer reacts to selection at all — it's
    always computed against clWindow, as in the unselected state; the
    only visible selection cue is this surrounding fill, in the
    existing 2px top/bottom and left/right (CHATROW_GAP) gaps. Anchor
    value 0.5 is the same order of magnitude as SENDER_BORDER_OPACITY
    ("a visible accent, not a tint"). }
  CHATROW_SELECTED_OPACITY = 0.5;
  { "Archive"/"All chats" pseudo-rows (DrawHeaderRow) — a fixed card
    color, not ChatAccentColor (they have no chat/accent_color_id of
    their own). #2196F3 (Material Blue 500) — TColor stores BGR, so the
    bytes are reversed. }
  CHATROW_PSEUDO_COLOR = $F39621;  { RGB(33, 150, 243) }

  { Context-menu item codes. }
  MI_NONE    = 0;
  MI_READ    = 1;
  MI_UNREAD  = 2;
  MI_PIN     = 3;
  MI_UNPIN   = 4;
  MI_COPY_ID = 5;
  MI_LEAVE   = 6;
  MI_ARCHIVE = 7;
  MI_UNARCHIVE = 8;

  { ================= framelog.pas ================= }

  { The log must not grow without bound: a memo with hundreds of
    thousands of lines eats memory and starts stalling on repaint. }
  MAX_LOG_LINES = 500;

  { ================= framesettingsautodownload.pas ================= }

  { Five media types x five chat types — the checkbox grid in the
    "Auto download" settings section. AUTODL_*_KINDS are persistence
    keys in config.ini/[autodownload] (key "<media>.<chat>", e.g.
    "images.private"), AUTODL_*_CAPTIONS are the UI labels; both array
    pairs share the same order (media = sections/columns, chat = rows
    within a section). }
  AUTODL_MEDIA_KINDS: array[0..4] of string = ('images', 'video', 'audio', 'gif', 'files');
  AUTODL_MEDIA_CAPTIONS: array[0..4] of string = ('Images', 'Video', 'Audio', 'GIF', 'Files');
  AUTODL_CHAT_KINDS: array[0..4] of string = ('private', 'secret', 'groups', 'channels', 'bots');
  AUTODL_CHAT_CAPTIONS: array[0..4] of string = ('Private chats', 'Secret chats', 'Groups', 'Channels', 'Bots');
  { How many messages beyond the visible area to prefetch when
    auto-download is enabled (TMsgScroller.PrefetchAutoDownload,
    framehistory.pas). MaybeAutoDownload itself is idempotent
    (Ensure*File is a no-op if already downloaded/already requested),
    so rescanning this window on every scroll tick is safe — real work
    only starts for rows newly entering the window. }
  AUTODL_PREFETCH_MESSAGES = 30;

  { ================= msginput.pas ================= }

  { Inner padding from Memo's own edges to its text, on all four
    sides — by direct request, alongside rounding Memo's corners to
    match the message blocks in history (MSG_CORNER_RADIUS,
    framehistory.pas group above, reused as-is rather than a separate
    number — "same as messages"). Applied via EM_SETRECT, not a
    property TMemo exposes itself — see TMessageInputPanel.MemoResize
    (msginput.pas). }
  MEMO_PAD = 8;
  { FSyncTimer's interval (TMessageInputPanel) — drives both the
    custom scrollbar's poll (SyncVScroll, needed since a plain Edit
    control raises no scroll-position notification of its own at all)
    and the MemoResize self-heal poll (needed since the native Edit
    control silently reverts its own format rect once, shortly after
    every resize — see SyncTick's own comment). Pulled out as its own
    number by direct request — noticeably laggy at 150ms, to be
    retuned by hand. }
  MEMO_SYNC_TIMER_MS = 2;

  { ================= msglayout.pas ================= }

  { Small line-spacing margin on top of TextHeight. }
  LINE_LEADING = 4;
  PLACEHOLDER_BOX   = 160;
  PLACEHOLDER_BOX_H = 120;
  CAPTION_GAP       = 6;
  { textEntityTypeBlockQuote (msglayout.pas WrapText/framehistory.
    TQuoteWidget) — a quote is now a REAL separate pooled child widget
    (direct request — "a real separate widget, big rework"), not a
    decorative band painted behind inline text flow (the earlier
    approach, whose own back-and-forth history is preserved in git, not
    repeated here). WrapText extracts a blockquote entity's byte range
    out of the normal flow entirely (see HandleQuoteSlot) and measures
    it via its own recursive, range-scoped call — BLOCKQUOTE_INDENT is
    still how far the quote's OWN text starts from the widget's left
    edge (bar width + a visual gap, not tied to MSG_PAD_H — a quote
    needs more breathing room than an ordinary icon-to-text gap), but
    the surrounding whitespace that used to be BLOCKQUOTE_BAND_PAD is
    now QUOTE_WIDGET_MARGIN below — a real OUTER margin around the
    whole widget (direct request: "4 pixels"), reserved on all four
    sides via WrapText's own layout math, not a decorative fill. Colored
    from the MESSAGE's own resolved accent color (framehistory.
    SenderColor, threaded down through Paint) — a quote is visually
    "part of" its message, not a fixed constant (a fixed color read as
    simply wrong once tested against a message whose accent clearly
    wasn't blue). BG/BAR opacity per direct request (0.2/0.5 of the
    accent, matching the SENDER_BG_OPACITY/SENDER_BORDER_OPACITY "faint
    tint + stronger accent border" language already used everywhere
    else in this app). }
  BLOCKQUOTE_BG_OPACITY  = 0.2;
  BLOCKQUOTE_BAR_OPACITY = 0.5;
  BLOCKQUOTE_BAR_W       = 2;
  BLOCKQUOTE_INDENT      = 12;
  { The quote widget's own outer margin — reserved above/below it (and,
    via a narrower available width passed into its own recursive
    WrapText call, on the sides) by WrapText itself (see HandleQuoteSlot,
    msglayout.pas) — direct request, "4 pixels". }
  QUOTE_WIDGET_MARGIN    = 4;
  { The quote widget's own INNER padding — direct request, "8 pixels on
    all sides", separate from QUOTE_WIDGET_MARGIN above (that one is the
    gap OUTSIDE the widget, between it and the surrounding message
    text/edges; this one is the gap INSIDE it, between its background
    box and the bar+text sitting on top of it). Applied by HandleQuoteSlot
    (via StartLine's CurX and the recursive call's available width, for
    left/right) and framehistory.TQuoteWidget.Paint (for top/bottom, and
    for where the left bar itself sits — it matches the text's own
    padded vertical extent, not the full widget height). }
  QUOTE_PAD              = 8;
  { The quote widget's own line spacing — separate from the app-wide
    LINE_LEADING (used for every OTHER text block, ordinary message text
    included) so it can be tuned for quotes alone, direct request
    ("slightly reduce it, as its own adjustable constant"). Only the
    widget-internal recursive WrapText call (AHandleQuoteWidgets=False)
    uses this; the outer, message-level call still uses LINE_LEADING. }
  QUOTE_LINE_LEADING     = 0;
  { Computed for TAudioWidget (framehistory.pas): 2*MSG_PAD_H (top/
    bottom inner padding) + max(32 [play/pause button],
    REPLY_LINE_H + HEADER_PAD_V + AUDIO_THUMB_H + HEADER_PAD_V +
    REPLY_LINE_H [title+progress+time]) = 2*11 + max(32,48) = 70. }
  AUDIO_WIDGET_H    = 70;
  { File widget (TFileWidget, framehistory.pas) — same backing/outline/
    rounding treatment as AUDIO_WIDGET_H, but with no progress bar, so
    height is not reused wholesale (that one accounts for
    button+title+progress+time) — its own formula: icon
    (AUDIO_BUTTON_SIZE) plus top/bottom padding (MSG_PAD_H=11) on each
    side. }
  FILE_WIDGET_H     = AUDIO_BUTTON_SIZE + 2 * MSG_PAD_H;

  { Photo preview (TPhotoWidget, framehistory.pas). Portrait
    (height>width): width capped at PHOTO_MAX_WIDTH, height scaled
    proportionally; landscape: height capped at PHOTO_MAX_HEIGHT
    instead. Small images are not upscaled — if the natural size is
    already below the cap, the preview stays natural size. This is only
    the upper cap — the actual column width at this point may be
    narrower (a non-wide window), in which case that wins, see AMaxW in
    ComputePhotoPreviewSize (msglayout.pas). Video previews
    (TVideoWidget also calls ComputePhotoPreviewSize) share the same
    cap rather than having their own — both message types should take
    up equally modest space in the chat. The full-size viewer
    (mediaviewer.pas) is NOT bound by this cap at all — it fits to the
    viewer window instead, see its own comment. }
  PHOTO_MAX_WIDTH     = 220;
  PHOTO_MAX_HEIGHT    = 220;
  { Rounding/outline for photo and video previews were removed
    entirely — TPhotoWidget.DrawBmpRounded / TVideoWidget.Paint draw
    the image as-is, rectangular, without these two constants. Both
    constants remain in use only for the "GIF" widget
    (TAnimationWidget.Paint, framehistory.pas), which keeps its
    rounding/outline. }
  PHOTO_CORNER_RADIUS = 4;
  PHOTO_BORDER_COLOR = $cccccc;

  { The app's single "brand" accent color — used wherever the UI needs
    ONE consistent color that isn't tied to a particular sender/chat
    (the first use: the fill of the photo/video download progress bar
    below). This is only the DEFAULT/fallback: the live value is
    user-configurable at Settings > General
    (framesettingsgeneral.pas/.lfm) and lives on FormMain.AccentColor
    (main.pas), persisted to config.ini/[ui] the same way
    CloseToTray/Invisible already are — read this constant only when
    nothing has been saved yet (FormMain.FormCreate). Deliberately NOT
    reused for CHATROW_PSEUDO_COLOR (framechats.pas group below), even
    though the two constants happen to share this exact value today —
    that one colors a specific, fixed UI element (the Archive/All
    chats pseudo-rows) and was never asked to track a user preference;
    unifying them would make changing one silently change the other. }
  APP_ACCENT_COLOR = $F39621;  { RGB(33, 150, 243) — Material Blue 500 }

  { The app's background surface — what the chat-list cards, the chat
    info bar's card and the message input box sit on. Also a live,
    user-configurable setting (Settings > General, FormMain.
    SurfaceColor); this constant is only the fallback used when nothing
    has been saved to config.ini/[ui] yet.

    clBtnFace rather than a fixed RGB value, so the untouched default
    keeps following the Windows theme the way it did before the setting
    existed — a hard-coded grey would have quietly frozen it. Note it
    is NOT the message history's own background: that stays clWindow,
    a sheet of paper with text on it, while this is the desk under
    it. }
  APP_SURFACE_COLOR = clBtnFace;

  { The work area's margin against the window's bottom edge, applied
    (TFormMain.UpdateMessageInputVisibility) only when the message
    input box is hidden — with the box up, its own 5px ChildSizing
    margin plus the splitter already provide the separation, and adding
    this on top would double it. Same value as everything else that
    floats off an edge around here (THIN_SCROLLBAR_MARGIN,
    CHAT_HEADER_CARD_MARGIN_*), kept as its own name because it is a
    different relationship — the work area against the window, not a
    control against its frame. }
  WORKAREA_EDGE_MARGIN = 5;

  { Download progress bar (TPhotoWidget/TVideoWidget, framehistory.pas)
    — drawn under the "download" icon while EnsurePhotoFile/
    EnsureVideoFile's downloadFile request is in flight (see
    ApplyPhotoFile/ApplyVideoFile, tdmessages.pas, which now track
    PhotoDownloadedSize/PhotoTotalSize and VideoDownloadedSize/
    VideoTotalSize instead of discarding every updateFile before
    completion). Width/height/track-background by direct request — the
    fill color is APP_ACCENT_COLOR (or its live override) above, not a
    constant here, since it's meant to change without touching this
    geometry. DOWNLOAD_PROGRESS_GAP is the vertical gap from the
    download icon's own bottom edge to the bar — not reusing MSG_PAD_V
    (that one means "distance from the block's edge", a different
    relationship). }
  DOWNLOAD_PROGRESS_W = 100;
  DOWNLOAD_PROGRESS_H = 4;
  DOWNLOAD_PROGRESS_BG = clWhite;
  DOWNLOAD_PROGRESS_GAP = 8;

  { Maximum sticker size (TStickerWidget, framehistory.pas) — the
    official client fits stickers into a roughly 150-190px square box
    rather than stretching them to the column width like photos. No
    frame/backing/rounding — a sticker is drawn as-is (transparent
    PNG/vector), so no PHOTO_CORNER_RADIUS analog is needed. }
  STICKER_MAX_SIZE = 170;

  { ================= qrrender.pas ================= }

  { Standard quiet zone — 4 modules on each side. Without it a
    significant fraction of scanners fail to read the code. }
  QR_QUIET_ZONE = 4;

  { ================= splash.pas ================= }

  { Minimum splash-screen display time. If TDLib responds faster, the
    window still stays up this long — otherwise it flashes. }
  MIN_SPLASH_MS = 2000;

  { ================= tdaccentcolors.pas ================= }

  { TColor is $00BBGGRR. The comment on each value gives its RGB and
    name per core.telegram.org/api/colors — not an official hex value
    (none is published). }
  BUILT_IN_COLORS: array[0..6] of TColor = (
    $3C3CE6,  { RGB(230, 60, 60)   red }
    $1E8CE6,  { RGB(230,140, 30)   orange }
    $D25096,  { RGB(150, 80,210)   violet }
    $5AAA3C,  { RGB( 60,170, 90)   green }
    $AFA028,  { RGB( 40,160,175)   cyan }
    $DC7832,  { RGB( 50,120,220)   blue }
    $9650DC   { RGB(220, 80,150)   pink }
  );

  { ================= tdauth.pas ================= }

  MAX_PENDING = 32;

  { ================= tdchats.pas ================= }

  { Was COALESCE_MS — renamed on consolidation: the same name and value
    (50) was independently declared in tdmessages.pas
    (MESSAGES_COALESCE_MS below) — the only real name collision when
    merging every project constant into one unit, see file header. }
  CHATS_COALESCE_MS = 50;

  { ================= tdcore.pas ================= }

  SHUTDOWN_TIMEOUT = 5000;
  MANIFEST = 'accounts.ini';

  { ================= tdjson.pas ================= }

  TDJSON_LIB = 'tdjson.dll';

  { ================= tdmessages.pas ================= }

  { Was COALESCE_MS — renamed on consolidation, see the comment on
    CHATS_COALESCE_MS above: the same collision, same meaning (debounce
    interval for a deferred rebuild), different source unit. }
  MESSAGES_COALESCE_MS = 50;
  { getChatHistory can legitimately return fewer messages than limit
    (or even a single duplicate of the anchor) even when history isn't
    exhausted — see HistoryDone in tdmessages.pas. Retries the same
    anchor a few times with a real delay between attempts (not
    synchronously — a synchronous retry inside the same callback once
    hung the app in a tight request/response loop). }
  MAX_NO_PROGRESS_RETRIES = 5;
  RETRY_DELAY_MS = 400;
  { TDLib message-id granularity: id = server_message_id shl 20 —
    confirmed from tdlib_raw.log: every real message id has its low 20
    bits zero, and adjacent messages differ by exactly this constant.
    from_message_id must be a multiple of it — TDLib rejects anything
    else with code 400 "Invalid value of parameter from_message_id
    specified" (also confirmed from the log: passing "anchor minus 1"
    instead of "anchor minus this constant" made almost every request
    fail with that error). }
  TD_MESSAGE_ID_STEP = 1048576;

  { ================= tdrecv.pas ================= }

  RECEIVE_TIMEOUT = 1.0;
  CLIENT_ID_TAG = '"@client_id":';

  { ================= tdreq.pas ================= }

  { Own @extra prefix. TTdAuth has its own ('auth:'), and they must not
    collide — otherwise two owners would compete for the same responses. }
  REQ_PREFIX = 'req:';

  { Synthetic error code for requests left unanswered. }
  TD_ERR_TIMEOUT = -1;
  { Synthetic code for requests canceled by client shutdown. }
  TD_ERR_CLOSED  = -2;

  { ================= thinscrollbar.pas ================= }

  { Custom-painted stand-in for the native TScrollBar, sizes by direct
    request — see the unit's own header comment for why this can't
    just be a TScrollBar subclass (Windows' own SCROLLBAR window class
    isn't Paint-hookable at all). }
  THIN_SCROLLBAR_WIDTH   = 6;
  THIN_SCROLLBAR_THUMB_W = 4;
  { Fully rounded pill ends — half the thumb's own width. }
  THIN_SCROLLBAR_RADIUS  = THIN_SCROLLBAR_THUMB_W / 2;
  { The thumb never shrinks below this, however small the visible page
    is relative to the whole scroll range — otherwise a very long chat
    history would give an unusably tiny, hard-to-grab sliver. Not
    requested explicitly, the same kind of sane floor every native
    scrollbar already enforces. }
  THIN_SCROLLBAR_MIN_THUMB_H = 24;
  { Muted gray, slightly darker while hovered/dragged — the same kind
    of cheap, two-state hover feedback used elsewhere in this project
    (e.g. crHandPoint cursors), not a fully themed control. }
  THIN_SCROLLBAR_THUMB_COLOR        = $C8C8C8;
  THIN_SCROLLBAR_THUMB_ACTIVE_COLOR = $969696;
  { 1px gap kept between the thumb and the very top/bottom edge of the
    track, by direct request — with the track's own corners now rounded
    too (THIN_SCROLLBAR_TRACK_RADIUS below), a thumb sitting flush
    against them would look like it pokes out past the curve. }
  THIN_SCROLLBAR_THUMB_INSET = 1;
  { Corner radius for the TRACK itself (the whole control's own
    background strip), not the thumb (THIN_SCROLLBAR_RADIUS, sized off
    the narrower thumb width, above) — half the track's own width, the
    same "fully rounded pill" convention used everywhere else in this
    project for a narrow element (radius = half the shorter dimension).
    Painted the same antialiased way as the thumb (TThinScrollBar.Paint,
    one composite for both) — an earlier version used a window-region
    clip (SetWindowRgn) instead, which looked visibly stair-stepped by
    direct report: a native region is an all-or-nothing per-pixel mask,
    it can't antialias at all. Reading the real parent background color
    live (Parent.Color) at paint time — rather than needing that color
    plumbed in from each of this control's three call sites, the way
    the message-block widgets elsewhere in this project need a computed
    BackgroundColor — is what makes a plain composite work here: unlike
    those widgets' per-message TINTED backgrounds, this control's
    parent (a plain frame/panel in all three cases) genuinely IS just
    its own flat Color, nothing to compute. }
  THIN_SCROLLBAR_TRACK_RADIUS = THIN_SCROLLBAR_WIDTH div 2;
  { Gap kept between the scrollbar and the surrounding frame's own
    edges (BorderSpacing.Around on the control, framechats.pas/
    framehistory.pas) — by direct request, matching the "floating,
    rounded" look msginput.pas's own scrollbar already had, there by a
    side effect of that frame's ChildSizing (LeftRightSpacing/
    TopBottomSpacing = 5, msginput.lfm — a margin applied to ALL its
    docked children as a group, not something to reuse here without
    doing the same to Toolbar/Memo too). Chat list/history have no such
    ChildSizing at all, so their own scrollbar sat flush against the
    window's true edge — this constant gives them the same 5px margin
    directly, on just this one control, without touching either
    frame's overall layout. }
  THIN_SCROLLBAR_MARGIN = 5;

implementation

end.
