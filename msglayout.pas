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

  { One decorative band per textEntityTypeBlockQuote span — the Y range
    (in the same local coordinates as TTextRun.Rect) covering every run
    that entity's byte range touches, X spanning the full column width.
    Computed post-hoc from already-wrapped Runs (ComputeQuoteBands), not
    tracked live during wrapping — PaintQuoteBands draws these BEHIND
    the text (background tint + left bar), and WrapText separately
    reserves BLOCKQUOTE_INDENT of left margin on any line a blockquote
    entity covers so the bar never overlaps a glyph. }
  TQuoteBandArray = array of TRect;

  { Layout cache for a single message. Stored in TMsgRow.LayoutCache as
    an opaque TObject — tdmessages knows nothing about TMsgLayout. }
  TMsgLayout = class
  public
    CachedWidth: integer;
    Height:      integer;
    Runs:        TTextRunArray;
    QuoteBands:  TQuoteBandArray;
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
  ACanvas: TCanvas; AAvailWidth: integer; out AHeight: integer): TTextRunArray;
var
  N, I, WordStart, WordLen, LineTop, CurX, LineH, Cap, Cnt: integer;
  SpaceW, EmojiLen: integer;
  EmojiCustomId: Int64;
  AtLineStart: boolean;
  { -1 until the first line has been started at all (so a message that
    happens to OPEN inside a blockquote never gets a spurious leading
    blank line); afterwards, the indent value (0 or BLOCKQUOTE_INDENT)
    the PREVIOUS line started at — see StartLine below. }
  PrevQuoteIndent: integer;

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
    entity whose underlying alt text isn't in the Twemoji atlas still
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

  { Called at every point a new line begins (in place of a bare
    "CurX := 0"/"CurX := QuoteIndentAt(...)") — sets CurX for the new
    line AND, if this line crosses the boundary into or out of a
    blockquote (indent changes between 0 and BLOCKQUOTE_INDENT relative
    to the PREVIOUS line), inserts one extra blank line first, matching
    the official client's visual paragraph break around a quote
    (reported directly — text was butting straight up against the
    quote's tinted band with no breathing room). Comparing against the
    previous LINE's indent, not just "am I in a quote right now", is
    what keeps this from firing between every wrapped line INSIDE a
    multi-line quote (those all share the same nonzero indent, so no
    transition, no extra gap) — only the true entry/exit lines get it. }
  procedure StartLine(APos: integer);
  var
    NewIndent: integer;
  begin
    NewIndent := QuoteIndentAt(APos);
    if (PrevQuoteIndent >= 0) and ((NewIndent > 0) <> (PrevQuoteIndent > 0)) then begin
      Inc(LineTop, LineH);
    end;
    CurX := NewIndent;
    PrevQuoteIndent := NewIndent;
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
  LineTop := 0;
  AtLineStart := True;
  PrevQuoteIndent := -1;

  ACanvas.Font.Style := [];
  LineH := ACanvas.TextHeight('Щ') + LINE_LEADING;
  SpaceW := ACanvas.TextWidth(' ');

  N := Length(AText);
  I := 1;
  StartLine(I);
  while I <= N do begin
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
    while (I <= N) and not (AText[I] in [' ', #9, #10, #13])
        and not SpecialGlyphAt(I, EmojiLen, EmojiCustomId) do begin
      Inc(I);
    end;
    WordLen := I - WordStart;
    if WordLen > 0 then begin
      EmitWord(WordStart, WordLen);
    end;
  end;

  if Cnt = 0 then begin
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

{ One band per textEntityTypeBlockQuote entity — the Y range (already
  in the same offset local coordinates as ARuns, so call AFTER
  OffsetRuns) covering every run whose CharStart falls in that entity's
  byte range, X spanning the full column width. Post-hoc over already-
  wrapped runs, not tracked live during WrapText — the actual left
  margin for quoted lines is reserved separately, via QuoteIndentAt
  inside WrapText itself; this only computes where to paint the
  decorative background/bar behind them. }
function ComputeQuoteBands(const AEntities: TMsgEntityArray; const ARuns: TTextRunArray;
  AAvailWidth: integer): TQuoteBandArray;
var
  I, J, Cnt, LinePad: integer;
  E: TMsgEntity;
  MinTop, MaxBottom: integer;
  Found: boolean;
begin
  SetLength(Result, 0);
  Cnt := 0;
  for I := 0 to High(AEntities) do begin
    E := AEntities[I];
    if E.Kind <> mekBlockQuote then begin
      Continue;
    end;
    Found := False;
    MinTop := 0;
    MaxBottom := 0;
    LinePad := 0;
    for J := 0 to High(ARuns) do begin
      if (ARuns[J].CharStart >= E.ByteStart) and (ARuns[J].CharStart < E.ByteStart + E.ByteLen) then begin
        if not Found then begin
          MinTop := ARuns[J].Rect.Top;
          MaxBottom := ARuns[J].Rect.Bottom;
          { One line's worth of vertical breathing room above/below the
            band, per direct request — derived from an actual run's own
            height rather than a fixed pixel constant, so it tracks
            whatever font size is in effect instead of drifting out of
            proportion if that ever changes. }
          LinePad := ARuns[J].Rect.Bottom - ARuns[J].Rect.Top;
          Found := True;
        end else begin
          if ARuns[J].Rect.Top < MinTop then begin
            MinTop := ARuns[J].Rect.Top;
          end;
          if ARuns[J].Rect.Bottom > MaxBottom then begin
            MaxBottom := ARuns[J].Rect.Bottom;
          end;
        end;
      end;
    end;
    if Found then begin
      SetLength(Result, Cnt + 1);
      Result[Cnt] := Rect(0, MinTop - LinePad, AAvailWidth, MaxBottom + LinePad);
      Inc(Cnt);
    end;
  end;
end;

{ Shared cache builder for renderers that have a text block (either the
  message text itself, or a caption under a placeholder). ATopOffset is
  the Y coordinate the text starts at: 0 for plain text, the preview
  block's height plus a gap for a caption. }
function EnsureTextLayout(ARow: TMsgRow; const ACtx: TMsgLayoutCtx;
  ATopOffset: integer): TMsgLayout;
var
  L: TMsgLayout;
  H: integer;
begin
  L := TMsgLayout(ARow.LayoutCache);
  if (L = nil) or (L.CachedWidth <> ACtx.AvailWidth) then begin
    if L = nil then begin
      L := TMsgLayout.Create;
      ARow.LayoutCache := L;
    end;
    L.CachedWidth := ACtx.AvailWidth;
    L.Runs := WrapText(ARow.PlainText, ARow.Entities, ACtx.Canvas, ACtx.AvailWidth, H);
    OffsetRuns(L.Runs, ATopOffset);
    L.QuoteBands := ComputeQuoteBands(ARow.Entities, L.Runs, ACtx.AvailWidth);
    L.Height := ATopOffset + H;
  end;
  Result := L;
end;

{ Cheap RGB blend, no BGRA dependency — msglayout.pas doesn't otherwise
  need alpha compositing for this, and quote bands repaint on every
  scroll frame same as everything else in this file (see SMOOTH_CORNERS
  in framehistory.pas for why that cost matters in this project).
  ColorToRGB is mandatory on BOTH inputs, not optional — a TColor like
  clWindow is a system-color PSEUDO-value (high bit set, a COLOR_xxx
  index packed into the low bits), not a literal RGB triple; extracting
  channels from it directly with Red/Green/Blue reads that index's raw
  bits as if they were color bytes, producing a near-arbitrary dark
  color instead of "blend toward white" (confirmed: this is exactly why
  the first version of PaintQuoteBands rendered as a solid dark navy
  box instead of a light tint). framehistory.BlendWithBackground already
  gets this right, with the same explanation in its own comment — this
  is the same fix, independently applied here since msglayout.pas can't
  import framehistory.pas (reverse dependency). }
function BlendColor(AFg, ABg: TColor; AOpacity: single): TColor;
var
  Fg, Bg: longint;
begin
  Fg := ColorToRGB(AFg);
  Bg := ColorToRGB(ABg);
  Result := RGBToColor(
    Round((Bg and $FF) + AOpacity * ((Fg and $FF) - (Bg and $FF))),
    Round(((Bg shr 8) and $FF) + AOpacity * (((Fg shr 8) and $FF) - ((Bg shr 8) and $FF))),
    Round(((Bg shr 16) and $FF) + AOpacity * (((Fg shr 16) and $FF) - ((Bg shr 16) and $FF))));
end;

{ Drawn BEHIND the text (call before PaintRuns) — a light tint plus a
  left bar per band, matching the indent WrapText already reserved for
  quoted lines (BLOCKQUOTE_INDENT) so the bar never overlaps a glyph.
  AAccentColor is the message's own resolved accent color (the same one
  its header/sender name is painted in — framehistory.SenderColor,
  threaded down through Paint, see TMsgContentRenderer.Paint's own
  comment) — a quote is visually "part of" its message, not a fixed,
  message-independent color (reported directly: the fixed blue read as
  simply wrong once a message's own color was clearly something else).
  Blended against clWindow, the same fixed background approximation
  this content-rendering layer already uses elsewhere (e.g. clBtnFace/
  clWindow placeholders in TAudioContentRenderer/TPhotoContentRenderer,
  above) rather than the real per-message tinted block background —
  that color lives one layer up, in framehistory.pas, not reachable
  from here. Tint and bar use different opacities (BLOCKQUOTE_BG_OPACITY/
  BLOCKQUOTE_BAR_OPACITY) — the bar is a stronger accent, not a solid
  fill, matching the SENDER_BG_OPACITY/SENDER_BORDER_OPACITY "faint tint
  + stronger accent" language already used everywhere else in this app
  for this exact visual role. }
procedure PaintQuoteBands(ACanvas: TCanvas; const AOrigin: TPoint; const ABands: TQuoteBandArray;
  AAccentColor: TColor);
var
  I: integer;
  R, BarR: TRect;
begin
  if Length(ABands) = 0 then begin
    Exit;
  end;
  ACanvas.Pen.Style := psClear;
  ACanvas.Brush.Style := bsSolid;
  for I := 0 to High(ABands) do begin
    R := ABands[I];
    OffsetRect(R, AOrigin.X, AOrigin.Y);

    ACanvas.Brush.Color := BlendColor(AAccentColor, clWindow, BLOCKQUOTE_BG_OPACITY);
    ACanvas.FillRect(R);

    BarR := Rect(R.Left, R.Top, R.Left + BLOCKQUOTE_BAR_W, R.Bottom);
    ACanvas.Brush.Color := BlendColor(AAccentColor, clWindow, BLOCKQUOTE_BAR_OPACITY);
    ACanvas.FillRect(BarR);
  end;
  ACanvas.Brush.Style := bsClear;
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
  PaintQuoteBands(ACanvas, Point(ARect.Left, ARect.Top), L.QuoteBands, AAccentColor);
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
  PaintQuoteBands(ACanvas, Point(ARect.Left, ARect.Top), L.QuoteBands, AAccentColor);
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
  PaintQuoteBands(ACanvas, Point(ARect.Left, ARect.Top), L.QuoteBands, AAccentColor);
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
