unit msglayout;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Math, Graphics, BGRABitmap,
  constants, tdmessages, emojiassets, customemoji;

type
  TRunKind = (rkText, rkLink, rkEmoji);

  { A single text "run" — a word or a piece of one after a hard break,
    already measured and positioned in the message content's local
    coordinates (0,0 is the top-left of the text area, WITHOUT the
    bubble's own padding — that's applied by framehistory). }
  TTextRun = record
    Kind:               TRunKind;
    Rect:               TRect;
    Text:               utf8string;
    URL:                utf8string;   { rkLink only }
    Bold, Italic:       boolean;
    { Byte offsets into TMsgRow.PlainText, CharEnd exclusive — same
      convention as TMsgEntity. Needed for text selection and copy. }
    CharStart, CharEnd: integer;
    { rkEmoji only, 0 if this is a plain Unicode emoji. Set from the
      covering mekCustomEmoji entity, if any (see CustomEmojiEntityAt in
      WrapText) — PaintRuns tries the real custom sticker first
      (customemoji.CustomEmojiBitmapFor) and falls back to the
      plain-Unicode alt-emoji bitmap (still the same run, same Text —
      the entity's underlying text) while it isn't ready yet. }
    CustomEmojiId:      Int64;
  end;
  TTextRunArray = array of TTextRun;

  { One textEntityTypeBlockQuote span, extracted out of the message's
    normal text flow entirely and rendered by its own real widget
    (framehistory.TQuoteWidget) instead of a decorative band painted
    behind inline text — a direct request, replacing the earlier
    band-behind-text approach. ByteStart/ByteLen are the SAME byte
    range as the covering TMsgEntity (into TMsgRow.PlainText) — needed
    by the widget only to identify itself across layout passes (see
    TQuoteWidget.SetQuote), NOT to re-derive Runs: Runs below is
    already fully computed (WrapText, with QUOTE_WIDGET_MARGIN-inset
    width and BLOCKQUOTE_INDENT baked into each Rect.Left for the
    left accent bar's clearance) and is what the widget paints as-is —
    computing it twice, once here and again inside the widget with a
    possibly different Canvas, is exactly the "two places compute the
    same geometry, they drift apart" class of bug this project has hit
    more than once; one computation, cached, avoids it structurally.
    Top/Height are in the SAME local coordinates as TTextRun.Rect (0,0
    = the text block's own top-left) — the caller offsets both by
    ATopOffset (EnsureTextLayout) the same way OffsetRuns does for
    ordinary Runs. }
  TQuoteSlot = record
    ByteStart, ByteLen: integer;
    Top, Height:        integer;
    Runs:                TTextRunArray;
  end;
  TQuoteSlotArray = array of TQuoteSlot;

  { Layout cache for a single message. Stored in TMsgRow.LayoutCache as
    an opaque TObject — tdmessages knows nothing about TMsgLayout. }
  TMsgLayout = class
  public
    CachedWidth: integer;
    Height:      integer;
    Runs:        TTextRunArray;
    QuoteSlots:  TQuoteSlotArray;
  end;

  TMsgLayoutCtx = record
    Canvas:     TCanvas;
    AvailWidth: integer;
  end;

  TMsgHitKind = (mhkNone, mhkText, mhkLink, mhkAudioWidget);
  TMsgHit = record
    Kind:       TMsgHitKind;
    URL:        utf8string;
    CharOffset: integer;   { byte offset into PlainText; -1 if not applicable }
  end;

  { TMsgContentRenderer

    Extension point by message content type: one class per kind (text,
    audio, photo/video/stickers, ...), looked up via RendererFor below.
    framehistory always goes through this abstraction and knows nothing
    about the concrete subclasses. }
  TMsgContentRenderer = class
  public
    { Returns the height for the given available width; along the way
      (re)builds the layout and stores it in ARow.LayoutCache. }
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; virtual; abstract;
    { ASelStart/ASelEnd is the byte range selected in THIS message's
      PlainText (already resolved by the caller against the bounds of a
      multi-message selection); ASelStart < 0 means no selection.
      AAccentColor is the message's own resolved accent color (what the
      header/sender name is painted in, framehistory.SenderColor) — only
      the text-bearing renderers (Text/Photo/Placeholder, the ones with
      a quote band to draw) actually use it; the rest accept and ignore
      it, same as ASelStart/ASelEnd already are for several of them. }
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer; AAccentColor: TColor); virtual; abstract;
    function HitTest(ARow: TMsgRow; const ARect: TRect; X, Y: integer): TMsgHit; virtual;
    { True only for widget-backed content: framehistory creates a real
      pooled child control for such rows instead of painting them
      itself. }
    function WantsWidget: boolean; virtual;
  end;

{ Registry — a simple lookup by content kind. }
function RendererFor(AKind: TMsgContentKind): TMsgContentRenderer;

{ Target photo preview size from natural ANaturalW/ANaturalH — shared
  by TPhotoContentRenderer.Measure/Paint (row height) and TPhotoWidget
  in framehistory.pas (the actual rendering), a single source of truth
  rather than two copies of the same arithmetic. Portrait (height>width)
  is width-capped (PHOTO_MAX_WIDTH), landscape is height-capped
  (PHOTO_MAX_HEIGHT); small images are not upscaled. AMaxW is the
  actual available column width at this point (Ctx.AvailWidth / the
  ContentRect width) — a mandatory second pass on top of the first:
  PHOTO_MAX_WIDTH alone does not guarantee the preview fits the column
  (the window can be narrower than MAX_MSG_W) — without this pass the
  image would overflow the message card on narrow windows. AMaxW<=0
  means the cap doesn't apply (the caller doesn't know the real width
  yet, e.g. before the first layout pass). }
procedure ComputePhotoPreviewSize(ANaturalW, ANaturalH, AMaxW: integer; out AOutW, AOutH: integer);

{ Target sticker size — same approach as ComputePhotoPreviewSize
  (clamped to the STICKER_MAX_SIZE box, then a second pass against the
  real column width), but with no separate width/height: Telegram fits
  stickers into a SQUARE box by the longer side, not a
  PHOTO_MAX_WIDTH/PHOTO_MAX_HEIGHT rectangle (that distinguishes
  portrait/landscape, which doesn't matter for stickers — both TGS/webm
  and webp are almost always close to square, and the official client
  fits them the same way). }
procedure ComputeStickerSize(ANaturalW, ANaturalH, AMaxW: integer; out AOutW, AOutH: integer);

{ Paints an already-computed run array (bold/italic/links/emoji, text
  selection highlight) at AOrigin — the same routine every content
  renderer in this unit uses for its own text, exported here so
  framehistory.TQuoteWidget can paint a TQuoteSlot.Runs array too (see
  the type's own comment: those Runs are computed once, during
  WrapText/EnsureTextLayout, not re-derived by the widget). }
procedure PaintRuns(ACanvas: TCanvas; const AOrigin: TPoint; const ARuns: TTextRunArray;
  ASelStart, ASelEnd: integer);

implementation

{ ---------------- text run splitting ---------------- }

{ UTF-8 character length from its leading byte — same logic as
  avatarcache/tdmessages. msglayout doesn't import either unit
  (avatarcache pulls in LCL/BGRABitmap, tdmessages would be a reverse
  dependency), so this is a local copy. }
function Utf8CharLen(AByte: byte): integer;
begin
  if AByte < $80 then begin
    Result := 1;
  end else if AByte < $C0 then begin
    Result := 1;
  end else if AByte < $E0 then begin
    Result := 2;
  end else if AByte < $F0 then begin
    Result := 3;
  end else begin
    Result := 4;
  end;
end;

{ Greedy word wrap with manual style lookup per entity span. Wrap
  granularity is the word: if a word falls entirely inside a link span,
  the whole link is clickable; if only partially, the boundary rounds
  to the start of the word. For real messages (a link is either a
  space-free token or a named link spanning several words) this is
  exact, not an approximation; for edge cases (a span ending mid-word)
  it's a simplification, acceptable for v1. }
function WrapText(const AText: utf8string; const AEntities: TMsgEntityArray;
  ACanvas: TCanvas; AAvailWidth: integer; out AHeight: integer;
  out AQuoteSlots: TQuoteSlotArray; AHandleQuoteWidgets: boolean = True;
  ARangeStart: integer = 1; ARangeEnd: integer = 0): TTextRunArray;
var
  N, NEnd, I, WordStart, WordLen, LineTop, CurX, LineH, Cap, Cnt, QuoteIdx: integer;
  SpaceW, EmojiLen: integer;
  EmojiCustomId: Int64;
  AtLineStart: boolean;
  { False initially and after any real content (EmitChunk/EmitEmojiChunk)
    — True right after HandleQuoteSlot. Decides how AHeight is derived
    at the very end: a message ending in ordinary text needs +LineH for
    that still-open last line, one ending in a quote widget does not —
    HandleQuoteSlot already advanced LineTop past the widget's own
    bottom margin, nothing left "open" to close. }
  LastWasQuote: boolean;

  { A mekCustomEmoji entity covering APos, if any — its ByteLen is
    authoritative (unlike a plain Unicode emoji, there's no atlas match
    to fall back on for sizing: the entity itself says exactly how many
    bytes this glyph is). }
  function CustomEmojiEntityAt(APos: integer; out ALen: integer; out AId: Int64): boolean;
  var
    J: integer;
    E: TMsgEntity;
  begin
    Result := False;
    ALen := 0;
    AId := 0;
    for J := 0 to High(AEntities) do begin
      E := AEntities[J];
      if (E.Kind = mekCustomEmoji) and (APos >= E.ByteStart) and (APos < E.ByteStart + E.ByteLen) then begin
        ALen := E.ByteStart + E.ByteLen - APos;
        AId := E.CustomEmojiId;
        Result := True;
        Exit;
      end;
    end;
  end;

  { Single entry point for "is there a glyph-sized image at APos" — a
    custom-emoji entity wins over a plain Unicode-emoji match (so an
    entity whose underlying alt text isn't in the emoji atlas still
    reserves its square instead of falling through to plain text), a
    plain Unicode emoji otherwise. }
  function SpecialGlyphAt(APos: integer; out ALen: integer; out ACustomId: Int64): boolean;
  begin
    if CustomEmojiEntityAt(APos, ALen, ACustomId) then begin
      Result := True;
      Exit;
    end;
    ACustomId := 0;
    Result := EmojiMatchAt(AText, APos, ALen);
  end;

  function StyleAt(APos: integer; out ABold, AItalic: boolean;
    out ALinkKind: TMsgEntityKind; out ALinkUrl: utf8string): boolean;
  var
    J: integer;
    E: TMsgEntity;
  begin
    ABold := False;
    AItalic := False;
    ALinkKind := mekNone;
    ALinkUrl := '';
    Result := False;
    for J := 0 to High(AEntities) do begin
      E := AEntities[J];
      if (APos >= E.ByteStart) and (APos < E.ByteStart + E.ByteLen) then begin
        case E.Kind of
          mekBold:   ABold := True;
          mekItalic: AItalic := True;
          mekUrl, mekTextUrl:
            begin
              ALinkKind := E.Kind;
              ALinkUrl := E.URL;
              Result := True;
            end;
        end;
      end;
    end;
  end;

  { How far a line starting at APos should be indented — BLOCKQUOTE_INDENT
    if APos falls inside a mekBlockQuote entity, 0 otherwise. Checked
    fresh at every line break (not tracked as running state), so mixed
    quoted/non-quoted paragraphs in the same message resolve correctly
    without any extra bookkeeping — same style as StyleAt above. Must be
    declared before EmitWord/HardBreakChars/EmitEmojiChunk, which call
    it from their own forced-line-break branches. }
  function QuoteIndentAt(APos: integer): integer;
  var
    J: integer;
    E: TMsgEntity;
  begin
    Result := 0;
    for J := 0 to High(AEntities) do begin
      E := AEntities[J];
      if (E.Kind = mekBlockQuote) and (APos >= E.ByteStart) and (APos < E.ByteStart + E.ByteLen) then begin
        Result := BLOCKQUOTE_INDENT;
        Exit;
      end;
    end;
  end;

  { The mekBlockQuote entity covering APos, if any — index into
    AEntities, -1 if none. Only ever matches when AHandleQuoteWidgets
    is True AND APos hasn't already been consumed by a previous
    HandleQuoteSlot call (that jumps I straight past the whole entity,
    see the main loop below) — so despite scanning the same entities
    array as QuoteIndentAt, the two never fight over the same position
    in practice: this one is checked in the OUTER (message-level) call,
    QuoteIndentAt is what a quote's OWN widget-internal call
    (AHandleQuoteWidgets=False) uses to indent its text for the left
    accent bar. }
  function BlockQuoteEntityAt(APos: integer): integer;
  var
    J: integer;
  begin
    Result := -1;
    for J := 0 to High(AEntities) do begin
      if (AEntities[J].Kind = mekBlockQuote) and (APos >= AEntities[J].ByteStart)
          and (APos < AEntities[J].ByteStart + AEntities[J].ByteLen) then begin
        Result := J;
        Exit;
      end;
    end;
  end;

  { Called at every point a new line begins — sets CurX for BLOCKQUOTE_
    INDENT if the line falls inside a blockquote, 0 otherwise. Only
    ever indents anything in a widget-internal call (AHandleQuoteWidgets
    =False, called from HandleQuoteSlot below with ARangeStart/AREnd
    scoped to exactly one quote's own byte range) — in the OUTER call, a
    position inside a blockquote is intercepted and skipped by
    BlockQuoteEntityAt further down BEFORE this is ever reached for it,
    so QuoteIndentAt there only ever sees plain-text positions and
    always returns 0, and the QUOTE_PAD add-on below never applies to
    ordinary message text either. In a widget-internal call, QUOTE_PAD
    is the left half of the widget's own inner padding — CurX ends up
    at QUOTE_PAD (widget edge to bar) + BLOCKQUOTE_INDENT (bar to text),
    same as HandleQuoteSlot's AAvailWidth below caps the right edge at
    InnerWidth-QUOTE_PAD for the matching right padding; the top/bottom
    half of the padding isn't tracked here at all — see HandleQuoteSlot's
    Slot.Height and framehistory.TQuoteWidget.Paint's PaintRuns origin. }
  procedure StartLine(APos: integer);
  begin
    CurX := QuoteIndentAt(APos);
    if not AHandleQuoteWidgets then begin
      Inc(CurX, QUOTE_PAD);
    end;
  end;

  { Extracts one blockquote's content out of the normal flow entirely —
    called (only from the OUTER, AHandleQuoteWidgets=True call) the
    moment the main loop below reaches E's own ByteStart. Reserves
    QUOTE_WIDGET_MARGIN above/below/(implicitly, via the narrower
    InnerWidth) on the sides — the widget's own outer margin, direct
    request — measures the quote's content via a RANGE-scoped recursive
    WrapText call (AHandleQuoteWidgets=False this time: nothing left to
    extract further, blockquote entities don't nest in practice; note
    it's told to wrap to InnerWidth-QUOTE_PAD, not InnerWidth itself —
    the widget's own right inner padding, matching QUOTE_PAD already
    baked into where StartLine starts CurX on the left), and records
    both the resulting geometry AND the already-computed Runs in one
    TQuoteSlot — see the type's own comment for why the widget paints
    those Runs as-is rather than recomputing them itself. Slot.Height
    is QH (the wrapped text's own height) PLUS 2*QUOTE_PAD (top+bottom
    inner padding) — the recursive call's own Runs are left starting at
    local Y=0 either way; the top half of the padding is applied only
    once, at paint time (framehistory.TQuoteWidget.Paint's PaintRuns
    origin), not duplicated here — LineTop is advanced by this SAME
    padded height afterward, so the next sibling (another quote, or
    ordinary text) sees the widget's true total height, padding
    included. }
  procedure HandleQuoteSlot(const E: TMsgEntity);
  var
    QRuns: TTextRunArray;
    QSlots: TQuoteSlotArray;
    QH, InnerWidth, WrapWidth: integer;
    Slot: TQuoteSlot;
  begin
    Inc(LineTop, QUOTE_WIDGET_MARGIN);
    InnerWidth := AAvailWidth - 2 * QUOTE_WIDGET_MARGIN;
    if InnerWidth < 1 then begin
      InnerWidth := 1;
    end;
    WrapWidth := InnerWidth - QUOTE_PAD;
    if WrapWidth < 1 then begin
      WrapWidth := 1;
    end;
    QRuns := WrapText(AText, AEntities, ACanvas, WrapWidth, QH, QSlots, False,
      E.ByteStart, E.ByteStart + E.ByteLen);
    Slot.ByteStart := E.ByteStart;
    Slot.ByteLen := E.ByteLen;
    Slot.Top := LineTop;
    Slot.Height := QH + 2 * QUOTE_PAD;
    Slot.Runs := QRuns;
    SetLength(AQuoteSlots, Length(AQuoteSlots) + 1);
    AQuoteSlots[High(AQuoteSlots)] := Slot;
    Inc(LineTop, Slot.Height + QUOTE_WIDGET_MARGIN);
    AtLineStart := True;
    LastWasQuote := True;
  end;

  procedure EnsureCap(ANeed: integer);
  begin
    if ANeed > Cap then begin
      Cap := ANeed + 16;
      SetLength(Result, Cap);
    end;
  end;

  procedure EmitChunk(AStart, ALen, AW: integer; ABold, AItalic, AIsLink: boolean;
    const AUrl: utf8string);
  begin
    EnsureCap(Cnt + 1);
    if AIsLink then begin
      Result[Cnt].Kind := rkLink;
    end else begin
      Result[Cnt].Kind := rkText;
    end;
    Result[Cnt].Rect := Rect(CurX, LineTop, CurX + AW, LineTop + LineH);
    Result[Cnt].Text := Copy(AText, AStart, ALen);
    Result[Cnt].Bold := ABold;
    Result[Cnt].Italic := AItalic;
    Result[Cnt].CharStart := AStart;
    Result[Cnt].CharEnd := AStart + ALen;
    Result[Cnt].URL := AUrl;
    Inc(Cnt);
    CurX := CurX + AW;
    AtLineStart := False;
    LastWasQuote := False;
  end;

  { The word doesn't fit on a line no matter what — break it by
    character instead, otherwise it would overflow the right edge or
    loop forever on an empty line. }
  procedure HardBreakChars(AStart, ALen: integer; ABold, AItalic, AIsLink: boolean;
    const AUrl: utf8string);
  var
    P, CLen, ChunkStart, ChunkLen, ChW, AccW: integer;
    Ch: utf8string;
  begin
    P := AStart;
    ChunkStart := AStart;
    ChunkLen := 0;
    AccW := 0;
    while P < AStart + ALen do begin
      CLen := Utf8CharLen(byte(AText[P]));
      if P + CLen - 1 > AStart + ALen - 1 then begin
        CLen := AStart + ALen - P;
      end;
      Ch := Copy(AText, P, CLen);
      ChW := ACanvas.TextWidth(string(Ch));

      if (ChunkLen > 0) and (CurX + AccW + ChW > AAvailWidth) then begin
        EmitChunk(ChunkStart, ChunkLen, AccW, ABold, AItalic, AIsLink, AUrl);
        Inc(LineTop, LineH);
        AtLineStart := True;
        StartLine(P);
        ChunkStart := P;
        ChunkLen := 0;
        AccW := 0;
      end;

      Inc(ChunkLen, CLen);
      Inc(AccW, ChW);
      Inc(P, CLen);
    end;
    if ChunkLen > 0 then begin
      EmitChunk(ChunkStart, ChunkLen, AccW, ABold, AItalic, AIsLink, AUrl);
    end;
  end;

  { An emoji sequence is wrapped like a word (own line if it doesn't fit)
    but painted as a fixed-size square image, not measured text — and,
    unlike words, consecutive emoji with no space between them stay
    flush against each other (CurX just continues, same as any other
    chunk). }
  procedure EmitEmojiChunk(AStart, ALen: integer; ACustomId: Int64);
  var
    Size: integer;
  begin
    Size := LineH - LINE_LEADING;
    if (not AtLineStart) and (CurX + Size > AAvailWidth) then begin
      Inc(LineTop, LineH);
      AtLineStart := True;
      StartLine(AStart);
    end;
    EnsureCap(Cnt + 1);
    Result[Cnt].Kind := rkEmoji;
    Result[Cnt].Rect := Rect(CurX, LineTop, CurX + Size, LineTop + Size);
    Result[Cnt].Text := Copy(AText, AStart, ALen);
    Result[Cnt].Bold := False;
    Result[Cnt].Italic := False;
    Result[Cnt].CharStart := AStart;
    Result[Cnt].CharEnd := AStart + ALen;
    Result[Cnt].URL := '';
    Result[Cnt].CustomEmojiId := ACustomId;
    Inc(Cnt);
    CurX := CurX + Size;
    AtLineStart := False;
    LastWasQuote := False;
  end;

  procedure EmitWord(AStart, ALen: integer);
  var
    W: integer;
    Txt: utf8string;
    Bold, Italic, IsLink: boolean;
    LKind: TMsgEntityKind;
    LUrl: utf8string;
  begin
    IsLink := StyleAt(AStart, Bold, Italic, LKind, LUrl);
    if LKind = mekUrl then begin
      LUrl := Copy(AText, AStart, ALen);   { auto-link — the URL is the text itself }
    end;

    ACanvas.Font.Style := [];
    if Bold then begin
      ACanvas.Font.Style := ACanvas.Font.Style + [fsBold];
    end;
    if Italic then begin
      ACanvas.Font.Style := ACanvas.Font.Style + [fsItalic];
    end;
    Txt := Copy(AText, AStart, ALen);
    W := ACanvas.TextWidth(string(Txt));

    if W > AAvailWidth then begin
      HardBreakChars(AStart, ALen, Bold, Italic, IsLink, LUrl);
      Exit;
    end;

    if (not AtLineStart) and (CurX + W > AAvailWidth) then begin
      Inc(LineTop, LineH);
      AtLineStart := True;
      StartLine(AStart);
    end;

    EmitChunk(AStart, ALen, W, Bold, Italic, IsLink, LUrl);
  end;

begin
  Cnt := 0;
  Cap := 0;
  SetLength(Result, 0);
  SetLength(AQuoteSlots, 0);
  LineTop := 0;
  AtLineStart := True;
  LastWasQuote := False;

  ACanvas.Font.Style := [];
  { A quote's own recursive call (AHandleQuoteWidgets=False) uses its
    own, separately tunable QUOTE_LINE_LEADING (constants.pas) instead
    of the app-wide LINE_LEADING every other text block uses — direct
    request, "slightly reduce quote line spacing", kept independent so
    it doesn't touch ordinary message text. }
  if AHandleQuoteWidgets then begin
    LineH := ACanvas.TextHeight('Щ') + LINE_LEADING;
  end else begin
    LineH := ACanvas.TextHeight('Щ') + QUOTE_LINE_LEADING;
  end;
  SpaceW := ACanvas.TextWidth(' ');

  N := Length(AText);
  if ARangeStart > 1 then begin
    I := ARangeStart;
  end else begin
    I := 1;
  end;
  if (ARangeEnd > 0) and (ARangeEnd - 1 < N) then begin
    NEnd := ARangeEnd - 1;
  end else begin
    NEnd := N;
  end;

  StartLine(I);
  while I <= NEnd do begin
    if AHandleQuoteWidgets then begin
      QuoteIdx := BlockQuoteEntityAt(I);
      if (QuoteIdx >= 0) and (AEntities[QuoteIdx].ByteStart = I) then begin
        HandleQuoteSlot(AEntities[QuoteIdx]);
        I := AEntities[QuoteIdx].ByteStart + AEntities[QuoteIdx].ByteLen;
        StartLine(I);
        Continue;
      end;
    end;

    if AText[I] = #10 then begin
      Inc(LineTop, LineH);
      AtLineStart := True;
      Inc(I);
      StartLine(I);
      Continue;
    end;
    if AText[I] in [' ', #9, #13] then begin
      if not AtLineStart then begin
        CurX := CurX + SpaceW;
      end;
      Inc(I);
      Continue;
    end;

    if SpecialGlyphAt(I, EmojiLen, EmojiCustomId) then begin
      EmitEmojiChunk(I, EmojiLen, EmojiCustomId);
      Inc(I, EmojiLen);
      Continue;
    end;

    WordStart := I;
    while (I <= NEnd) and not (AText[I] in [' ', #9, #10, #13])
        and not SpecialGlyphAt(I, EmojiLen, EmojiCustomId) do begin
      Inc(I);
    end;
    WordLen := I - WordStart;
    if WordLen > 0 then begin
      EmitWord(WordStart, WordLen);
    end;
  end;

  { A message ending in ordinary text needs +LineH for that still-open
    last line; one ending in a quote widget does not — HandleQuoteSlot
    already advanced LineTop past the widget's own bottom margin,
    nothing left "open" to close (see LastWasQuote's own comment). }
  if LastWasQuote then begin
    AHeight := LineTop;
  end else if Cnt = 0 then begin
    AHeight := 0;
  end else begin
    AHeight := LineTop + LineH;
  end;
  SetLength(Result, Cnt);
end;

procedure OffsetRuns(var ARuns: TTextRunArray; ADy: integer);
var
  I: integer;
begin
  if ADy = 0 then begin
    Exit;
  end;
  for I := 0 to High(ARuns) do begin
    ARuns[I].Rect.Top := ARuns[I].Rect.Top + ADy;
    ARuns[I].Rect.Bottom := ARuns[I].Rect.Bottom + ADy;
  end;
end;

{ Shared cache builder for renderers that have a text block (either the
  message text itself, or a caption under a placeholder). ATopOffset is
  the Y coordinate the text starts at: 0 for plain text, the preview
  block's height plus a gap for a caption. Quote slots come back from
  WrapText already measured/positioned in the text block's OWN local
  coordinates (0,0 = its own top-left) — offset by ATopOffset the same
  way OffsetRuns shifts ordinary Runs, but NOT the slots' own cached
  Runs array (those stay in the quote WIDGET's local coordinates —
  framehistory.TQuoteWidget paints them relative to its own top-left,
  not the message's). }
function EnsureTextLayout(ARow: TMsgRow; const ACtx: TMsgLayoutCtx;
  ATopOffset: integer): TMsgLayout;
var
  L: TMsgLayout;
  H, I: integer;
  QSlots: TQuoteSlotArray;
begin
  L := TMsgLayout(ARow.LayoutCache);
  if (L = nil) or (L.CachedWidth <> ACtx.AvailWidth) then begin
    if L = nil then begin
      L := TMsgLayout.Create;
      ARow.LayoutCache := L;
    end;
    L.CachedWidth := ACtx.AvailWidth;
    L.Runs := WrapText(ARow.PlainText, ARow.Entities, ACtx.Canvas, ACtx.AvailWidth, H, QSlots);
    OffsetRuns(L.Runs, ATopOffset);
    if ATopOffset <> 0 then begin
      for I := 0 to High(QSlots) do begin
        Inc(QSlots[I].Top, ATopOffset);
      end;
    end;
    L.QuoteSlots := QSlots;
    L.Height := ATopOffset + H;
  end;
  Result := L;
end;

procedure PaintRuns(ACanvas: TCanvas; const AOrigin: TPoint; const ARuns: TTextRunArray;
  ASelStart, ASelEnd: integer);
var
  I: integer;
  R: TTextRun;
  HasSel: boolean;
  Bmp: TBGRABitmap;
begin
  HasSel := (ASelStart >= 0) and (ASelEnd > ASelStart);
  for I := 0 to High(ARuns) do begin
    R := ARuns[I];
    { Highlighting is per whole run (word) if it at least partially
      falls within the selection range. Highlighting partway through a
      word is not handled here — selection granularity is word-level
      anyway (see framehistory). }
    if HasSel and (R.CharEnd > ASelStart) and (R.CharStart < ASelEnd) then begin
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Brush.Color := clHighlight;
      ACanvas.FillRect(Rect(AOrigin.X + R.Rect.Left, AOrigin.Y + R.Rect.Top,
        AOrigin.X + R.Rect.Right, AOrigin.Y + R.Rect.Bottom));
    end;
    ACanvas.Brush.Style := bsClear;

    if R.Kind = rkEmoji then begin
      Bmp := nil;
      if R.CustomEmojiId <> 0 then begin
        { The real custom sticker, once fetched+decoded (customemoji.pas)
          — until then, fall through to the atlas bitmap for R.Text
          below, which is the entity's own alt-emoji text, a reasonable
          placeholder (not guaranteed related to the real glyph, but
          not blank either — see EnsureCustomEmojiForRow). }
        Bmp := CustomEmojiBitmapFor(R.CustomEmojiId, R.Rect.Bottom - R.Rect.Top);
      end;
      if Bmp = nil then begin
        Bmp := EmojiBitmapFor(R.Text, R.Rect.Bottom - R.Rect.Top);
      end;

      if Bmp <> nil then begin
        Bmp.Draw(ACanvas, AOrigin.X + R.Rect.Left, AOrigin.Y + R.Rect.Top, False);
      end;
      Continue;
    end;

    ACanvas.Font.Style := [];
    if R.Bold then begin
      ACanvas.Font.Style := ACanvas.Font.Style + [fsBold];
    end;
    if R.Italic then begin
      ACanvas.Font.Style := ACanvas.Font.Style + [fsItalic];
    end;
    if R.Kind = rkLink then begin
      ACanvas.Font.Color := clHighlight;
      ACanvas.Font.Style := ACanvas.Font.Style + [fsUnderline];
    end else begin
      ACanvas.Font.Color := clWindowText;
    end;
    ACanvas.TextOut(AOrigin.X + R.Rect.Left, AOrigin.Y + R.Rect.Top, string(R.Text));
  end;
end;

function HitTestRuns(const ARuns: TTextRunArray; LocalX, LocalY: integer): TMsgHit;
var
  I: integer;
  R: TTextRun;
begin
  Result.Kind := mhkNone;
  Result.URL := '';
  Result.CharOffset := -1;
  for I := 0 to High(ARuns) do begin
    R := ARuns[I];
    if (LocalY >= R.Rect.Top) and (LocalY < R.Rect.Bottom) and
       (LocalX >= R.Rect.Left) and (LocalX < R.Rect.Right) then begin
      if R.Kind = rkLink then begin
        Result.Kind := mhkLink;
        Result.URL := R.URL;
      end else begin
        Result.Kind := mhkText;
      end;
      Result.CharOffset := R.CharStart;
      Exit;
    end;
  end;
end;

{ ---------------- TMsgContentRenderer (base) ---------------- }

function TMsgContentRenderer.HitTest(ARow: TMsgRow; const ARect: TRect;
  X, Y: integer): TMsgHit;
begin
  Result.Kind := mhkNone;
  Result.URL := '';
  Result.CharOffset := -1;
end;

function TMsgContentRenderer.WantsWidget: boolean;
begin
  Result := False;
end;

{ ---------------- text ---------------- }

type
  TTextContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer; AAccentColor: TColor); override;
    function HitTest(ARow: TMsgRow; const ARect: TRect; X, Y: integer): TMsgHit; override;
  end;

function TTextContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
begin
  Result := EnsureTextLayout(ARow, ACtx, 0).Height;
end;

procedure TTextContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer; AAccentColor: TColor);
var
  Ctx: TMsgLayoutCtx;
  L: TMsgLayout;
begin
  Ctx.Canvas := ACanvas;
  Ctx.AvailWidth := ARect.Right - ARect.Left;
  L := EnsureTextLayout(ARow, Ctx, 0);
  PaintRuns(ACanvas, Point(ARect.Left, ARect.Top), L.Runs, ASelStart, ASelEnd);
end;

function TTextContentRenderer.HitTest(ARow: TMsgRow; const ARect: TRect;
  X, Y: integer): TMsgHit;
var
  L: TMsgLayout;
begin
  L := TMsgLayout(ARow.LayoutCache);
  if L = nil then begin
    Result.Kind := mhkNone;
    Result.URL := '';
    Result.CharOffset := -1;
    Exit;
  end;
  Result := HitTestRuns(L.Runs, X - ARect.Left, Y - ARect.Top);
end;

{ ---------------- audio: a real widget (framehistory.TAudioWidget) ---------------- }

type
  TAudioContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer; AAccentColor: TColor); override;
    function WantsWidget: boolean; override;
  end;

function TAudioContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
begin
  Result := AUDIO_WIDGET_H;
end;

procedure TAudioContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer; AAccentColor: TColor);
begin
  { Backing shown for the one frame before framehistory positions the
    real pooled TAudioWidget over it — the widget itself paints over
    this rectangle. }
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clBtnFace;
  ACanvas.FillRect(ARect);
end;

function TAudioContentRenderer.WantsWidget: boolean;
begin
  Result := True;
end;

{ ---------------- file/document: a real widget (framehistory.TFileWidget) ----------------
  Same scheme as audio — this renderer only reserves the height and
  paints a placeholder backing for the one frame before TFrameHistory
  positions the real pooled TFileWidget over it. }

type
  TDocContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer; AAccentColor: TColor); override;
    function WantsWidget: boolean; override;
  end;

function TDocContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
begin
  Result := FILE_WIDGET_H;
end;

procedure TDocContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer; AAccentColor: TColor);
begin
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clBtnFace;
  ACanvas.FillRect(ARect);
end;

function TDocContentRenderer.WantsWidget: boolean;
begin
  Result := True;
end;

{ ---------------- photo: a real widget (framehistory.TPhotoWidget) ---------------- }

procedure ComputePhotoPreviewSize(ANaturalW, ANaturalH, AMaxW: integer; out AOutW, AOutH: integer);
begin
  if (ANaturalW <= 0) or (ANaturalH <= 0) then begin
    AOutW := PHOTO_MAX_WIDTH;
    AOutH := PHOTO_MAX_HEIGHT;
  end else if ANaturalH > ANaturalW then begin
    { Portrait — width-capped, height scaled proportionally. }
    AOutW := Min(ANaturalW, PHOTO_MAX_WIDTH);
    AOutH := Round(ANaturalH * (AOutW / ANaturalW));
  end else begin
    { Landscape (or square) — height-capped. }
    AOutH := Min(ANaturalH, PHOTO_MAX_HEIGHT);
    AOutW := Round(ANaturalW * (AOutH / ANaturalH));
  end;

  { Second pass — the real column width at this point may be narrower
    than PHOTO_MAX_WIDTH (a non-wide window): shrink further, keeping
    proportions, otherwise the preview overflows the message card. }
  if (AMaxW > 0) and (AOutW > AMaxW) then begin
    AOutH := Round(AOutH * (AMaxW / AOutW));
    AOutW := AMaxW;
  end;
end;

type
  TPhotoContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer; AAccentColor: TColor); override;
    function HitTest(ARow: TMsgRow; const ARect: TRect; X, Y: integer): TMsgHit; override;
    function WantsWidget: boolean; override;
  end;

{ Natural (unscaled) size of the visual preview — photo, "GIF"
  (messageAnimation), or video message (messageVideo); all three share
  the same renderer (see RendererFor): each is a variable-size image
  with an optional caption, differing only in WHERE width/height come
  from (PhotoWidth/Height for a photo, AnimWidth/Height for an
  animation — different TMsgRow fields, see its own comment).

  mckVideo is an EXCEPTION: the inline chat widget (TVideoWidget,
  framehistory.pas) shows a static frame from content.video.thumbnail
  rather than decoded video, and framehistory.pas (LayoutVideoWidgets)
  computes its ON-SCREEN size from VideoThumbWidth/Height (the
  thumbnail's own resolution), not VideoWidth/Height (the source
  video's resolution). Using VideoWidth/Height here instead would make
  this function (via Measure/Paint below) reserve more space for the
  message block than the widget actually occupies, leaving an empty
  gray strip of block background beside/below the image. Both call
  sites must agree on the same value — falling back to VideoWidth/
  Height below only covers the case where VideoThumbWidth/Height
  haven't arrived yet (in theory, a video with no thumbnail in its
  content at all). }
procedure NaturalMediaSize(ARow: TMsgRow; out AW, AH: integer);
begin
  case ARow.Kind of
    mckAnimation: begin
      AW := ARow.AnimWidth;
      AH := ARow.AnimHeight;
    end;
    mckVideo: begin
      if (ARow.VideoThumbWidth > 0) and (ARow.VideoThumbHeight > 0) then begin
        AW := ARow.VideoThumbWidth;
        AH := ARow.VideoThumbHeight;
      end else begin
        AW := ARow.VideoWidth;
        AH := ARow.VideoHeight;
      end;
    end;
  else
    AW := ARow.PhotoWidth;
    AH := ARow.PhotoHeight;
  end;
end;

function TPhotoContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
var
  NatW, NatH, ImgW, ImgH: integer;
begin
  NaturalMediaSize(ARow, NatW, NatH);
  ComputePhotoPreviewSize(NatW, NatH, ACtx.AvailWidth, ImgW, ImgH);
  if ARow.PlainText = '' then begin
    Result := ImgH;
  end else begin
    { The caption spans the full available column width, not limited
      to the preview's own width (which is often narrower). }
    Result := EnsureTextLayout(ARow, ACtx, ImgH + CAPTION_GAP).Height;
  end;
end;

procedure TPhotoContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer; AAccentColor: TColor);
var
  NatW, NatH, ImgW, ImgH: integer;
  L: TMsgLayout;
  Ctx: TMsgLayoutCtx;
begin
  { Backing shown for the one frame before framehistory positions the
    real pooled widget over it (TPhotoWidget/TAnimationWidget) — same
    approach as audio/file. Only under the preview, not the full width:
    the image has its own natural size, not "full column". }
  NaturalMediaSize(ARow, NatW, NatH);
  ComputePhotoPreviewSize(NatW, NatH, ARect.Right - ARect.Left, ImgW, ImgH);
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clBtnFace;
  ACanvas.FillRect(Rect(ARect.Left, ARect.Top, ARect.Left + ImgW, ARect.Top + ImgH));

  if ARow.PlainText = '' then begin
    Exit;
  end;
  Ctx.Canvas := ACanvas;
  Ctx.AvailWidth := ARect.Right - ARect.Left;
  L := EnsureTextLayout(ARow, Ctx, ImgH + CAPTION_GAP);
  PaintRuns(ACanvas, Point(ARect.Left, ARect.Top), L.Runs, ASelStart, ASelEnd);
end;

function TPhotoContentRenderer.HitTest(ARow: TMsgRow; const ARect: TRect;
  X, Y: integer): TMsgHit;
var
  L: TMsgLayout;
begin
  L := TMsgLayout(ARow.LayoutCache);
  if L = nil then begin
    Result.Kind := mhkNone;
    Result.URL := '';
    Result.CharOffset := -1;
    Exit;
  end;
  Result := HitTestRuns(L.Runs, X - ARect.Left, Y - ARect.Top);
end;

function TPhotoContentRenderer.WantsWidget: boolean;
begin
  Result := True;
end;

{ ---------------- sticker: a real widget (framehistory.TStickerWidget) ---------------- }

procedure ComputeStickerSize(ANaturalW, ANaturalH, AMaxW: integer; out AOutW, AOutH: integer);
begin
  if (ANaturalW <= 0) or (ANaturalH <= 0) then begin
    AOutW := STICKER_MAX_SIZE;
    AOutH := STICKER_MAX_SIZE;
  end else if ANaturalH > ANaturalW then begin
    AOutW := Min(ANaturalW, STICKER_MAX_SIZE);
    AOutH := Round(ANaturalH * (AOutW / ANaturalW));
  end else begin
    AOutH := Min(ANaturalH, STICKER_MAX_SIZE);
    AOutW := Round(ANaturalW * (AOutH / ANaturalH));
  end;
  if (AMaxW > 0) and (AOutW > AMaxW) then begin
    AOutH := Round(AOutH * (AMaxW / AOutW));
    AOutW := AMaxW;
  end;
end;

type
  { A sticker has NO caption at all (messageSticker has no caption
    field, per the official docs.core.telegram.org/tdlib — unlike
    photo/video/"GIF", which always have one, even if empty), so
    Measure/Paint here are simpler than TPhotoContentRenderer — no
    text-present branch, no EnsureTextLayout. }
  TStickerContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer; AAccentColor: TColor); override;
    function WantsWidget: boolean; override;
  end;

function TStickerContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
var
  ImgW, ImgH: integer;
begin
  ComputeStickerSize(ARow.StickerWidth, ARow.StickerHeight, ACtx.AvailWidth, ImgW, ImgH);
  Result := ImgH;
end;

procedure TStickerContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer; AAccentColor: TColor);
var
  ImgW, ImgH: integer;
begin
  { Backing shown for the one frame before framehistory positions the
    real TStickerWidget over it — same approach as photo/audio/file. A
    sticker is transparent by itself, so this still needs to paint
    something, otherwise stale pixels from the previous frame show
    through under the not-yet-positioned widget; clWindow, not
    clBtnFace — the sticker's background should blend with the window,
    not look like a separate gray card (a sticker has no card of its
    own).
    Only under the sticker itself (its natural size, the same
    computation as LayoutStickerWidgets/SetSticker — ComputeStickerSize
    with the same AMaxW), NOT the full ARect — painting the whole
    ARect used to leave a white rectangle visible to the right of a
    small sticker instead of the block's tint (this Paint runs on
    every repaint, even once the real widget is already positioned
    over it, and the white background showed through anywhere the
    widget was physically smaller than ARect). TPhotoContentRenderer.
    Paint already does exactly this — the same approach, applied here. }
  ComputeStickerSize(ARow.StickerWidth, ARow.StickerHeight, ARect.Right - ARect.Left, ImgW, ImgH);
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clWindow;
  ACanvas.FillRect(Rect(ARect.Left, ARect.Top, ARect.Left + ImgW, ARect.Top + ImgH));
end;

function TStickerContentRenderer.WantsWidget: boolean;
begin
  Result := True;
end;

{ ---------------- content with no dedicated renderer: placeholder ---------------- }

type
  TPlaceholderContentRenderer = class(TMsgContentRenderer)
  public
    function Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer; override;
    procedure Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
      ASelStart, ASelEnd: integer; AAccentColor: TColor); override;
    function HitTest(ARow: TMsgRow; const ARect: TRect; X, Y: integer): TMsgHit; override;
  end;

{ mckVoiceNote/mckPhoto/mckAnimation/mckVideo/mckSticker are excluded
  here — all of them now have real widgets (see RendererFor), so this
  branch is unreachable for them; the parameter is kept for future
  content kinds that will eventually need a real renderer of their own. }
function PlaceholderLabel(AKind: TMsgContentKind): string;
begin
  Result := 'Unsupported';
end;

function TPlaceholderContentRenderer.Measure(ARow: TMsgRow; const ACtx: TMsgLayoutCtx): integer;
var
  TopOff: integer;
begin
  if ARow.PlainText = '' then begin
    TopOff := 0;
  end else begin
    TopOff := PLACEHOLDER_BOX_H + CAPTION_GAP;
  end;
  Result := EnsureTextLayout(ARow, ACtx, TopOff).Height;
  if ARow.PlainText = '' then begin
    Result := PLACEHOLDER_BOX_H;
  end;
end;

procedure TPlaceholderContentRenderer.Paint(ARow: TMsgRow; ACanvas: TCanvas; const ARect: TRect;
  ASelStart, ASelEnd: integer; AAccentColor: TColor);
var
  BoxRect: TRect;
  S: string;
  Sz: TSize;
  L: TMsgLayout;
  Ctx: TMsgLayoutCtx;
begin
  BoxRect := Rect(ARect.Left, ARect.Top, ARect.Left + PLACEHOLDER_BOX,
    ARect.Top + PLACEHOLDER_BOX_H);
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := clBtnFace;
  ACanvas.FillRect(BoxRect);

  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Style := [];
  ACanvas.Font.Color := clGrayText;
  S := PlaceholderLabel(ARow.Kind);
  Sz := ACanvas.TextExtent(S);
  ACanvas.TextOut(BoxRect.Left + (PLACEHOLDER_BOX - Sz.cx) div 2,
    BoxRect.Top + (PLACEHOLDER_BOX_H - Sz.cy) div 2, S);

  if ARow.PlainText = '' then begin
    Exit;
  end;
  Ctx.Canvas := ACanvas;
  Ctx.AvailWidth := ARect.Right - ARect.Left;
  L := EnsureTextLayout(ARow, Ctx, PLACEHOLDER_BOX_H + CAPTION_GAP);
  PaintRuns(ACanvas, Point(ARect.Left, ARect.Top), L.Runs, ASelStart, ASelEnd);
end;

function TPlaceholderContentRenderer.HitTest(ARow: TMsgRow; const ARect: TRect;
  X, Y: integer): TMsgHit;
var
  L: TMsgLayout;
begin
  L := TMsgLayout(ARow.LayoutCache);
  if L = nil then begin
    Result.Kind := mhkNone;
    Result.URL := '';
    Result.CharOffset := -1;
    Exit;
  end;
  Result := HitTestRuns(L.Runs, X - ARect.Left, Y - ARect.Top);
end;

{ ---------------- registry ---------------- }

var
  GTextRenderer:        TTextContentRenderer;
  GAudioRenderer:        TAudioContentRenderer;
  GDocRenderer:         TDocContentRenderer;
  GPhotoRenderer:       TPhotoContentRenderer;
  GStickerRenderer:     TStickerContentRenderer;
  GPlaceholderRenderer: TPlaceholderContentRenderer;

function RendererFor(AKind: TMsgContentKind): TMsgContentRenderer;
begin
  case AKind of
    mckText:      Result := GTextRenderer;
    { A voice note uses the same real widget (TAudioWidget) as regular
      audio, matching the same look and behavior — not a separate
      class; GAudioRenderer just reserves the same AUDIO_WIDGET_H, and
      the widget's content is handled by framehistory.pas
      (LayoutAudioWidgets filters both mckAudio and mckVoiceNote). }
    mckAudio, mckVoiceNote: Result := GAudioRenderer;
    mckFile:      Result := GDocRenderer;
    { "GIF" (messageAnimation) and video message (messageVideo) use the
      same real renderer as a photo, the same way voice notes share
      GAudioRenderer: all three are a variable-size image with an
      optional caption, and NaturalMediaSize inside
      TPhotoContentRenderer tells them apart by ARow.Kind. The widget's
      content (downloading/playback) is handled by framehistory.pas. }
    mckPhoto, mckAnimation, mckVideo: Result := GPhotoRenderer;
    mckSticker: Result := GStickerRenderer;
  else
    Result := GPlaceholderRenderer;
  end;
end;

initialization
  GTextRenderer := TTextContentRenderer.Create;
  GAudioRenderer := TAudioContentRenderer.Create;
  GDocRenderer := TDocContentRenderer.Create;
  GPhotoRenderer := TPhotoContentRenderer.Create;
  GStickerRenderer := TStickerContentRenderer.Create;
  GPlaceholderRenderer := TPlaceholderContentRenderer.Create;

finalization
  GTextRenderer.Free;
  GAudioRenderer.Free;
  GDocRenderer.Free;
  GPhotoRenderer.Free;
  GStickerRenderer.Free;
  GPlaceholderRenderer.Free;

end.
