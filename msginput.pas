unit msginput;

{$mode objfpc}{$H+}

{ Message input panel. Lives at the bottom of the work area (main.pas,
  pnlWork), separated from the frame area (TFrameNavigator) by a
  splitter — see TFormMain.FormCreate.

  Three rows top to bottom: Toolbar (text-formatting TextEditPanel plus the
  HTML/Markdown mode switch, see below), Memo (the message text, fills
  the remaining space), ButtonRow (Send button, right-aligned; further
  TextEditPanel can be added to the same row).

  A real TFrame with a paired .lfm (msginput.lfm) — unlike most of the
  media-viewer/settings code added earlier in this project, this one is
  meant to be laid out visually in the Lazarus Designer (drag icons onto
  the TextEditPanel, reorder them, set ChildSizing on Memo's parent, etc.),
  not built in code. Toolbar/ButtonRow/Memo/the format TextEditPanel are
  therefore plain published fields, streamed from the .lfm, not
  programmatically created in a constructor.

  Not bound to any particular chat/model itself (does not pull
  tdmessages/framehistory/main into uses) — it is just a text source
  plus a "send clicked" event; the owner (main.pas, which already has
  access to both TFrameNavigator.Current and TTdMessages) decides who
  and what to send.

  Formatting toolbar — NOT a WYSIWYG rich-text editor (TMemo is a plain
  Windows edit control, it cannot render bold/italic inline at all, and
  replacing it with a custom owner-drawn one is well outside this
  pass's scope, the same conclusion already reached for colored emoji
  in this same input box). Instead, each button wraps the current
  selection in Telegram's OWN marked-up syntax — either MarkdownV2
  (*bold*, _italic_, __underline__, ~strike~, ||spoiler||, `code`,
  ```code block```, [text](url), a '>' per line for blockquote) or HTML
  (<b>, <i>, <u>, <s>, <tg-spoiler>, <code>, <pre>, <a href>,
  <blockquote>) — confirmed against
  core.telegram.org/bots/api and TDLib's own text-parse-mode docs, not
  guessed. HtmlModeBox selects which syntax gets inserted; the SAME
  choice is read by the owner (TFormMain.MessageInputSend) at send time
  to tell TTdMessages.SendFormattedText which parser to run the whole
  message through (parseTextEntities — see tdmessages.pas). Nothing
  here builds a real TDLib text entity directly; the marked-up string
  is just plain text with visible punctuation/tags in the TMemo, same
  as typing it by hand, until parseTextEntities turns it into one at
  send time (which also escapes any stray reserved punctuation in the
  rest of the message — see EscapeMarkdownV2/EscapeHtml there).

  A caveat worth keeping in mind: the OFFICIAL menus in the reference
  screenshots also had "Cite" (=Quote/blockquote, included below),
  "Translate" (not a formatting entity — calls a completely different
  TDLib method on already-typed text, out of scope here) and a "Date"
  item (Telegram's tg-time countdown entity, a genuinely separate,
  fairly exotic feature, not implemented in this pass — TDLib's own
  parseTextEntities documentation does not list a date/time entity
  among what it parses). }

interface

uses
  { Windows comes first, same reasoning as framehistory.pas's own uses
    clause: EM_GETFIRSTVISIBLELINE/EM_GETLINECOUNT/EM_LINESCROLL/
    SendMessage are needed for Memo's custom scrollbar (see FVScroll's
    own comment) — Memo's native multiline Edit control has no LCL-
    level scroll message handler at all (unlike TCustomGrid's
    LM_VSCROLL, see framechats.pas's own VScrollScroll) — the OS's own
    Edit window class handles line-scrolling internally, driven here
    with the real Win32 API, not LCL's message Dispatch. }
  Windows,
  cardpaint, Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, Buttons,
  constants, Dialogs, LCLType, thinscrollbar, Types;

type

  { TMessageInputPanel }

  TMessageInputPanel = class(TFrame)
    BoldBtn: TSpeedButton;
    ClearFmtBtn: TSpeedButton;
    CodeBtn: TSpeedButton;
    ItalicBtn: TSpeedButton;
    LinkBtn: TSpeedButton;
    MonoBtn: TSpeedButton;
    QuoteBtn: TSpeedButton;
    SpoilerBtn: TSpeedButton;
    StrikeBtn: TSpeedButton;
    TextEditIcons: TImageList;
    Toolbar: TPanel;
    SendBtn: TBitBtn;
    HtmlModeBox: TCheckBox;
    Memo: TMemo;
    UnderlineBtn: TSpeedButton;
    procedure SendBtnClick(Sender: TObject);
    { Enter sends (same path as clicking Send); Ctrl+Enter inserts a
      newline, TMemo's default behavior, left untouched. }
    procedure MemoKeyDown(Sender: TObject; var Key: word; Shift: TShiftState);
    procedure BoldBtnClick(Sender: TObject);
    procedure ItalicBtnClick(Sender: TObject);
    procedure UnderlineBtnClick(Sender: TObject);
    procedure StrikeBtnClick(Sender: TObject);
    procedure MonoBtnClick(Sender: TObject);
    { Multi-line code BLOCK (``` fences / <pre>), distinct from the
      single-backtick/inline Mono button above — Telegram's own
      composer offers both. }
    procedure CodeBtnClick(Sender: TObject);
    procedure SpoilerBtnClick(Sender: TObject);
    { Not a simple wrap: MarkdownV2 blockquote is a '>' prefix on EVERY
      line of the quoted text (see core.telegram.org/bots/api), not an
      open/close pair — a plain WrapSelection would only quote the
      first line. HTML blockquote IS a simple wrap, handled inline. }
    procedure QuoteBtnClick(Sender: TObject);
    { Prompts for link text (if nothing is selected) and a URL via two
      small InputQuery dialogs, then inserts [text](url) or
      <a href="url">text</a> depending on mode. }
    procedure LinkBtnClick(Sender: TObject);
    { Best-effort, not a real parser: strips the delimiter
      characters/tags themselves out of the selection, for whichever
      mode is currently active. A literal '*'/'_'/etc. the user typed
      on purpose, indistinguishable from a formatting marker in this
      plain-marked-up-text model, gets stripped too — same trade-off
      the toolbar's insertion side already accepts. }
    procedure ClearFmtBtnClick(Sender: TObject);
  protected
    { The Memo's rounded corners, antialiased — drawn by the FRAME, not
      by the Memo, because the Memo can't. See the body. }
    procedure Paint; override;
    { Backstop for MemoResize, alongside Memo's own OnResize (Create
      below) — Align recalculation should always fire Memo's OWN
      resize too whenever this frame's does, but this covers it either
      way, cheaply (MemoResize itself is idempotent). }
    procedure Resize; override;
  private
    FOnSend: TNotifyEvent;
    { thinscrollbar.pas, replacing Memo's own native one (Memo.
      ScrollBars set to ssNone in Create) — same reasoning as
      framehistory.pas's message history and framechats.pas's chat
      list: a native Windows scrollbar is OS-drawn and can't be
      custom-painted at all. Created in code in Create below, not
      placed via the Designer like the rest of this frame —
      TThinScrollBar isn't a registered design-time component. }
    FVScroll: TThinScrollBar;
    { Polls Memo's scroll state and mouse wheel/keyboard navigation —
      not row-count-changed like framechats.pas's grid; a plain Edit
      control fires no notification at all for either (EM_LINESCROLL
      doesn't raise OnChange, that's for text-content edits only), so
      there is nothing else to hook into here. Cheap: SyncVScroll's
      own SetParams already no-ops when nothing actually changed. }
    FSyncTimer: TTimer;
    procedure SyncTick(Sender: TObject);
    { Feeds Memo's line-based scroll state (EM_GETFIRSTVISIBLELINE/
      EM_GETLINECOUNT — both counted in WRAPPED/visual lines, not
      logical Memo.Lines.Count, confirmed against Microsoft's own
      EM_GETFIRSTVISIBLELINE docs, not guessed) into FVScroll. }
    procedure SyncVScroll;
    { FVScroll's OnScroll — EM_LINESCROLL is RELATIVE (a delta of
      lines to scroll by), unlike TCustomGrid's absolute LM_VSCROLL
      (framechats.pas): a plain Win32 Edit control has no absolute-
      position scroll message at all (confirmed against Microsoft's
      own EM_LINESCROLL docs). The current first-visible-line is
      re-read right before computing the delta, rather than tracked
      separately, so no rounding ever accumulates across calls. }
    procedure VScrollScroll(Sender: TObject; ScrollCode: TScrollCode; var ScrollPos: integer);
    { Mouse wheel over Memo stopped scrolling once its native scrollbar
      was hidden (Memo.ScrollBars := ssNone, Create below) — TControl.
      WMMouseWheel (control.inc) only falls through to the underlying
      native Edit control's own default wheel handling when nothing
      else claims the event first (DoMouseWheelDown/Up, both no-ops
      TCustomMemo doesn't override), so LCL itself isn't what's
      swallowing it; Windows' own multiline Edit control apparently
      doesn't bother wheel-scrolling itself once it has no vertical
      scrollbar to move. Same fix as VScrollScroll below, just fired
      from the wheel instead of a drag: drive EM_LINESCROLL directly,
      not relying on the native control's own (apparently
      scrollbar-gated) default behavior. }
    procedure MemoMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    { Rounds Memo's corners (SetWindowRgn — the standard way to shape
      ANY native window, custom-painted or not) and insets its text by
      MEMO_PAD on every side (EM_SETRECT) — both re-applied here
      because both are sized/positioned in absolute pixels tied to
      Memo's current Width/Height, which changes whenever this frame
      or FVScroll's own visibility does (see Resize above and Memo.
      OnResize, wired in Create). }
    procedure MemoResize(Sender: TObject);
    function GetText: string;
    procedure SetText(const AValue: string);
    function GetIsHtmlMode: boolean;
    { Wraps the current Memo selection in the delimiter/tag pair
      matching the current mode (plain args for Markdown, html args for
      HTML — see HtmlModeBox). With nothing selected, both markers are
      inserted anyway and the cursor is left BETWEEN them, ready to type
      the formatted text directly; with a real selection, the whole
      wrapped result is left selected afterward so another button can
      be applied right on top of it (e.g. bold+italic together). }
    procedure WrapSelection(const APlainOpen, APlainClose, AHtmlOpen, AHtmlClose: string);
  public
    constructor Create(TheOwner: TComponent); override;
    procedure ClearText;
    property Text: string read GetText write SetText;
    { True = the toolbar buttons insert HTML tags and
      TFormMain.MessageInputSend should ask TDLib to parse the message
      as HTML; False = MarkdownV2. }
    property IsHtmlMode: boolean read GetIsHtmlMode;
    property OnSend: TNotifyEvent read FOnSend write FOnSend;
  end;

implementation

{$R *.lfm}

constructor TMessageInputPanel.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);

  Memo.ScrollBars := ssNone;
  Memo.OnResize := @MemoResize;
  Memo.OnMouseWheel := @MemoMouseWheel;
  FVScroll := TThinScrollBar.Create(Self);
  FVScroll.Parent := Self;
  FVScroll.Align := alRight;
  FVScroll.OnScroll := @VScrollScroll;

  FSyncTimer := TTimer.Create(Self);
  FSyncTimer.Interval := MEMO_SYNC_TIMER_MS;
  FSyncTimer.OnTimer := @SyncTick;
  FSyncTimer.Enabled := True;
end;

procedure TMessageInputPanel.Resize;
begin
  inherited Resize;
  MemoResize(Self);
end;

{ The Memo's own rounded corners — painted HERE, by the frame, because
  the Memo genuinely cannot paint them itself.

  A TMemo is a native Win32 Edit control: this application does not own
  its painting at all, so there is nothing to antialias from inside it,
  and a parent cannot draw on top of a child window either. The only
  lever available is SetWindowRgn (MemoResize above), and a window
  region is a binary per-pixel mask owned by the OS — a pixel either
  belongs to the window or it does not, with no partial coverage — so
  its arc is always stair-stepped. That was the whole reason this was
  first reported as "can't be done without replacing the control".

  It can be done, just from the other side. The region is cut with a
  LARGER radius than the visible one (MEMO_REGION_SLACK), which pulls
  the child's jagged edge strictly inside the intended curve and leaves
  a thin sliver of the frame showing around each corner. That sliver
  belongs to the frame, so the frame can paint it — an antialiased
  rounded rectangle in the Memo's own color, over the Memo's bounds.
  The child covers the middle, this covers the corners, and the visible
  outer edge is entirely the antialiased one. The jagged boundary
  between them is invisible: it has the same color on both sides.

  Only the corners actually differ, so nothing is drawn under the bulk
  of the Memo — the fill would be overdrawn by the child immediately
  anyway. }
procedure TMessageInputPanel.Paint;
var
  B: TRect;
begin
  inherited Paint;
  if not SMOOTH_CHROME_CORNERS then begin
    Exit;
  end;
  if (Memo = nil) or not Memo.Visible then begin
    Exit;
  end;
  B := Rect(Memo.Left, Memo.Top, Memo.Left + Memo.Width, Memo.Top + Memo.Height);
  PaintRounded(Canvas, B, MSG_CORNER_RADIUS, [], Memo.Color, clNone, True);
end;

procedure TMessageInputPanel.MemoResize(Sender: TObject);
var
  Rgn: HRGN;
  R: TRect;
  RgnRadius: integer;
begin
  { Memo can still be nil here: TMessageInputPanel.Resize (above) can
    fire as a side effect of the .lfm's OWN streaming — reading each
    child's bounds off the stream can trigger an intermediate resize
    of the frame itself before every child (Memo included) has been
    created yet, well before "inherited Create" in this unit's own
    constructor even returns. Crashed with an access violation inside
    TWinControl.HandleAllocated (a nil Self) before this guard was
    added. }
  if (Memo = nil) or not Memo.HandleAllocated then begin
    Exit;
  end;

  { Rounded corners, same radius as message blocks in history
    (MSG_CORNER_RADIUS). TMemo is a native Win32 Edit control window —
    SetWindowRgn is the standard way to give ANY window a
    non-rectangular shape, not just a custom-painted one: pixels
    outside the region simply aren't painted, showing this frame's own
    background through instead (same principle as the GDI clip-region
    trick already used elsewhere in this project for a custom-painted
    control, e.g. framehistory.pas's TPhotoWidget.DrawBmpRounded — just
    applied at the window level here instead of within one Paint
    call). Ownership of the region handle passes to the OS once
    SetWindowRgn succeeds — it must NOT be deleted afterward (confirmed
    against Microsoft's own SetWindowRgn documentation), unlike the GDI
    clip regions used elsewhere in this project, which the caller keeps
    and must free itself. A later SetWindowRgn call (the next resize)
    replaces it and the OS frees the old one on its own. }
  { The radius the REGION is cut with is deliberately larger than the
    visible one when the smooth path is on — see this frame's Paint.
    A bigger corner radius removes MORE material at the corner, so the
    region's jagged edge ends up strictly INSIDE the smooth curve
    painted underneath it, and no stair-step can poke out past that
    curve. Along the straight sides the two coincide, as before. }
  if SMOOTH_CHROME_CORNERS then begin
    RgnRadius := MSG_CORNER_RADIUS + MEMO_REGION_SLACK;
  end else begin
    RgnRadius := MSG_CORNER_RADIUS;
  end;
  Rgn := Windows.CreateRoundRectRgn(0, 0, Memo.Width, Memo.Height,
    RgnRadius * 2, RgnRadius * 2);
  Windows.SetWindowRgn(Memo.Handle, Rgn, True);
  { The frame paints the smooth curve into the sliver the region now
    leaves uncovered, so it has to repaint whenever the Memo moves or
    resizes. }
  Invalidate;

  { Inner padding to the text, MEMO_PAD on every side — EM_SETRECT,
    confirmed (Microsoft's own docs) to work on a plain multiline Edit
    control, not just Rich Edit: "This message is processed only by
    multiline edit controls. You can send this message to either an
    edit control or a rich edit control." No border to subtract for it
    (Memo.BorderStyle = bsNone, msginput.lfm) — the inset is straight
    off Memo's own client size. }
  R := Rect(MEMO_PAD, MEMO_PAD, Memo.Width - MEMO_PAD, Memo.Height - MEMO_PAD);
  Windows.SendMessage(Memo.Handle, EM_SETRECT, 0, LPARAM(@R));
end;

procedure TMessageInputPanel.SyncTick(Sender: TObject);
begin
  SyncVScroll;
  { Confirmed with a small standalone test harness (a bare TMemo,
    EM_GETRECT logged before/after a resize and on every subsequent
    poll), not guessed: reapplying EM_SETRECT right when a resize
    happens (Memo.OnResize/this frame's own Resize, both already
    calling MemoResize) is NOT enough on its own — the native Edit
    control silently reverts its own format rectangle back to its own
    auto-computed default ONE MORE TIME, shortly after, WITHOUT any
    further Width/Height change at all (so a poll that only reapplies
    when the size on record differs from Memo's current one — an
    earlier version of this comment/fix — never catches it, since the
    size never changes again). The test also confirmed this drift
    happens exactly ONCE per resize and never again afterward — no
    ongoing fight with Windows to keep reasserting it, reapplying
    unconditionally here on every tick is enough: cheap (a single
    SetWindowRgn + SendMessage, no visible effect when already
    correct) and self-corrects within one tick (MEMO_SYNC_TIMER_MS,
    constants.pas) of the one genuine drift a resize causes. }
  MemoResize(Self);
end;

procedure TMessageInputPanel.SyncVScroll;
var
  FirstLine, LineCount, LineH, PageLines: integer;
  DC: HDC;
  { Windows.-qualified: LCLType (later in this unit's uses) declares
    its own, distinct TEXTMETRICA — the same shadowing pitfall already
    documented in framehistory.pas's own uses-clause comment, just
    hitting a type instead of a function this time. Windows.
    GetTextMetrics below must be called with a var of THIS SAME
    Windows.TEXTMETRICA, not LCLType's. }
  TM: Windows.TEXTMETRICA;
begin
  if (Memo = nil) or (FVScroll = nil) or not Memo.HandleAllocated then begin
    Exit;
  end;
  FirstLine := Windows.SendMessage(Memo.Handle, EM_GETFIRSTVISIBLELINE, 0, 0);
  LineCount := Windows.SendMessage(Memo.Handle, EM_GETLINECOUNT, 0, 0);

  { TMemo has no Canvas of its own to measure with (a native windowed
    control, not a TCustomControl), and TScreen has no Canvas either
    in this LCL version — the real Win32 line height for Memo's own
    font, queried directly from its own device context, same idea as
    the SendMessage calls above. }
  LineH := 0;
  DC := Windows.GetDC(Memo.Handle);
  if DC <> 0 then begin
    Windows.SelectObject(DC, Memo.Font.Handle);
    if Windows.GetTextMetrics(DC, TM) then begin
      LineH := TM.tmHeight + TM.tmExternalLeading;
    end;
    Windows.ReleaseDC(Memo.Handle, DC);
  end;
  if LineH <= 0 then begin
    LineH := 1;
  end;

  PageLines := Memo.ClientHeight div LineH;
  if PageLines < 1 then begin
    PageLines := 1;
  end;
  FVScroll.SetParams(FirstLine, 0, LineCount, PageLines);
end;

procedure TMessageInputPanel.VScrollScroll(Sender: TObject; ScrollCode: TScrollCode; var ScrollPos: integer);
var
  CurLine, Delta: integer;
begin
  if (Memo = nil) or not Memo.HandleAllocated then begin
    Exit;
  end;
  case ScrollCode of
    scTrack, scPosition: begin
      CurLine := Windows.SendMessage(Memo.Handle, EM_GETFIRSTVISIBLELINE, 0, 0);
      Delta := ScrollPos - CurLine;
      if Delta <> 0 then begin
        Windows.SendMessage(Memo.Handle, EM_LINESCROLL, 0, Delta);
      end;
      { Fed back into the thumb directly — EM_LINESCROLL raises no
        notification of its own (it isn't a text-content edit, so
        OnChange doesn't fire either), so nothing else would refresh
        it during a drag. }
      SyncVScroll;
    end;
  end;
end;

procedure TMessageInputPanel.MemoMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  LinesPerNotch, Lines: integer;
begin
  if (Memo = nil) or not Memo.HandleAllocated then begin
    Exit;
  end;
  { Lines-per-notch is the user's own configured mouse setting
    (Control Panel > Mouse > Wheel — SPI_GETWHEELSCROLLLINES), not a
    hardcoded guess; 3 is only the fallback if the query itself somehow
    fails, matching Windows' own documented default for that setting. }
  LinesPerNotch := 3;
  Windows.SystemParametersInfo(SPI_GETWHEELSCROLLLINES, 0, @LinesPerNotch, 0);
  Lines := -(WheelDelta div WHEEL_DELTA) * LinesPerNotch;
  if Lines <> 0 then begin
    Windows.SendMessage(Memo.Handle, EM_LINESCROLL, 0, Lines);
    SyncVScroll;
  end;
  Handled := True;
end;

function TMessageInputPanel.GetText: string;
begin
  Result := Memo.Text;
end;

procedure TMessageInputPanel.SetText(const AValue: string);
begin
  Memo.Text := AValue;
end;

function TMessageInputPanel.GetIsHtmlMode: boolean;
begin
  Result := HtmlModeBox.Checked;
end;

procedure TMessageInputPanel.ClearText;
begin
  Memo.Clear;
end;

procedure TMessageInputPanel.SendBtnClick(Sender: TObject);
begin
  if Assigned(FOnSend) then begin
    FOnSend(Self);
  end;
end;

procedure TMessageInputPanel.MemoKeyDown(Sender: TObject; var Key: word; Shift: TShiftState);
begin
  if Key <> VK_RETURN then begin
    Exit;
  end;
  if ssCtrl in Shift then begin
    Exit;   { Ctrl+Enter — plain newline }
  end;
  Key := 0;   { suppress the newline — send instead }
  SendBtnClick(Self);
end;

procedure TMessageInputPanel.WrapSelection(const APlainOpen, APlainClose,
  AHtmlOpen, AHtmlClose: string);
var
  Open, Close, Sel: string;
  StartPos, Len: integer;
begin
  if IsHtmlMode then begin
    Open := AHtmlOpen;
    Close := AHtmlClose;
  end else begin
    Open := APlainOpen;
    Close := APlainClose;
  end;

  StartPos := Memo.SelStart;
  Len := Memo.SelLength;
  Sel := Memo.SelText;
  Memo.SelText := Open + Sel + Close;

  if Len = 0 then begin
    Memo.SelStart := StartPos + Length(Open);
    Memo.SelLength := 0;
  end else begin
    Memo.SelStart := StartPos;
    Memo.SelLength := Length(Open) + Len + Length(Close);
  end;
  Memo.SetFocus;
end;

procedure TMessageInputPanel.BoldBtnClick(Sender: TObject);
begin
  WrapSelection('*', '*', '<b>', '</b>');
end;

procedure TMessageInputPanel.ItalicBtnClick(Sender: TObject);
begin
  WrapSelection('_', '_', '<i>', '</i>');
end;

procedure TMessageInputPanel.UnderlineBtnClick(Sender: TObject);
begin
  WrapSelection('__', '__', '<u>', '</u>');
end;

procedure TMessageInputPanel.StrikeBtnClick(Sender: TObject);
begin
  WrapSelection('~', '~', '<s>', '</s>');
end;

procedure TMessageInputPanel.MonoBtnClick(Sender: TObject);
begin
  WrapSelection('`', '`', '<code>', '</code>');
end;

procedure TMessageInputPanel.CodeBtnClick(Sender: TObject);
begin
  WrapSelection('```', '```', '<pre>', '</pre>');
end;

procedure TMessageInputPanel.SpoilerBtnClick(Sender: TObject);
begin
  WrapSelection('||', '||', '<tg-spoiler>', '</tg-spoiler>');
end;

procedure TMessageInputPanel.QuoteBtnClick(Sender: TObject);
var
  StartPos: integer;
  Sel, Quoted: string;
begin
  StartPos := Memo.SelStart;
  Sel := Memo.SelText;

  if IsHtmlMode then begin
    Quoted := '<blockquote>' + Sel + '</blockquote>';
    Memo.SelText := Quoted;
    if Sel = '' then begin
      Memo.SelStart := StartPos + Length('<blockquote>');
      Memo.SelLength := 0;
    end else begin
      Memo.SelStart := StartPos;
      Memo.SelLength := Length(Quoted);
    end;
  end else begin
    { '>' at the start, and again right after every line break in the
      selection — LineEnding matches what Memo.SelText itself uses on
      this platform, so this only ever inserts breaks that were already
      there. }
    Quoted := '>' + StringReplace(Sel, LineEnding, LineEnding + '>', [rfReplaceAll]);
    Memo.SelText := Quoted;
    Memo.SelStart := StartPos;
    Memo.SelLength := Length(Quoted);
  end;
  Memo.SetFocus;
end;

procedure TMessageInputPanel.LinkBtnClick(Sender: TObject);
var
  StartPos: integer;
  LinkText, Url, Inserted: string;
begin
  StartPos := Memo.SelStart;
  LinkText := Memo.SelText;

  if LinkText = '' then begin
    if not InputQuery('Add link', 'Link text:', LinkText) then begin
      Exit;
    end;
    if Trim(LinkText) = '' then begin
      Exit;
    end;
  end;

  Url := 'https://';
  if not InputQuery('Add link', 'URL:', Url) then begin
    Exit;
  end;
  if Trim(Url) = '' then begin
    Exit;
  end;

  if IsHtmlMode then begin
    Inserted := '<a href="' + Url + '">' + LinkText + '</a>';
  end else begin
    Inserted := '[' + LinkText + '](' + Url + ')';
  end;

  Memo.SelText := Inserted;
  Memo.SelStart := StartPos;
  Memo.SelLength := Length(Inserted);
  Memo.SetFocus;
end;

{ [text](url) -> text, for ClearFmtBtnClick's Markdown branch — the one
  piece of Markdown syntax that isn't a single repeated delimiter
  character, so the simple StringReplace approach used for the rest
  doesn't cover it. }
function StripMarkdownLinks(const AText: string): string;
var
  I, CloseBracket, CloseParen: integer;
begin
  Result := '';
  I := 1;
  while I <= Length(AText) do begin
    if AText[I] = '[' then begin
      CloseBracket := I + 1;
      while (CloseBracket <= Length(AText)) and (AText[CloseBracket] <> ']') do begin
        Inc(CloseBracket);
      end;
      if (CloseBracket < Length(AText)) and (AText[CloseBracket + 1] = '(') then begin
        CloseParen := CloseBracket + 2;
        while (CloseParen <= Length(AText)) and (AText[CloseParen] <> ')') do begin
          Inc(CloseParen);
        end;
        Result := Result + Copy(AText, I + 1, CloseBracket - I - 1);
        I := CloseParen + 1;
        Continue;
      end;
    end;
    Result := Result + AText[I];
    Inc(I);
  end;
end;

procedure TMessageInputPanel.ClearFmtBtnClick(Sender: TObject);
var
  StartPos, I: integer;
  Sel, Plain: string;
begin
  StartPos := Memo.SelStart;
  Sel := Memo.SelText;
  if Sel = '' then begin
    Exit;
  end;

  if IsHtmlMode then begin
    { Strips ANY <tag> found in the selection, not just the specific
      ones this toolbar itself inserts — a reasonable "remove all
      formatting" for a plain-marked-up-text editor with no real
      entity tracking of its own. }
    Plain := '';
    I := 1;
    while I <= Length(Sel) do begin
      if Sel[I] = '<' then begin
        while (I <= Length(Sel)) and (Sel[I] <> '>') do begin
          Inc(I);
        end;
        Inc(I);   { skip the '>' itself too }
      end else begin
        Plain := Plain + Sel[I];
        Inc(I);
      end;
    end;
  end else begin
    Plain := StripMarkdownLinks(Sel);
    Plain := StringReplace(Plain, '*', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, '_', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, '~', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, '|', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, '`', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, LineEnding + '>', LineEnding, [rfReplaceAll]);
    if (Length(Plain) > 0) and (Plain[1] = '>') then begin
      Delete(Plain, 1, 1);
    end;
  end;

  Memo.SelText := Plain;
  Memo.SelStart := StartPos;
  Memo.SelLength := Length(Plain);
  Memo.SetFocus;
end;

end.
