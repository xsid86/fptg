unit framechats;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  avatarcache, BGRABitmap, BGRABitmapTypes, cardpaint,
  Classes, Clipbrd, customemoji,
  Controls, constants, DateUtils, Dialogs, emojiassets, ExtCtrls, Forms, Graphics, Grids,
  LCLType, LMessages, Math, Menus, StdCtrls, SysUtils, tdaccentcolors, tdauth, tdchats,
  tdcore, thinscrollbar, Types, uiframe;

type
  { Clickable areas within a row. }
  TChatHitArea = (chaNone, chaBell, chaAvatar, chaHeader, chaPin, chaFolder,
    chaArchive);

  { Which list is shown. }
  TChatListMode = (clmMain, clmArchive);

  TChatSelectEvent = procedure(Sender: TObject; ARow: TChatRow) of object;
  TAvatarClickEvent = procedure(Sender: TObject; ARow: TChatRow) of object;
  TListModeEvent = procedure(Sender: TObject; AMode: TChatListMode) of object;

  { TFrameChats

    The chat list on a TDrawGrid: the grid has no row collection of its
    own, so the model remains the single store of data, and reordering
    a chat is just an Invalidate.

    A chat row follows the same visual language as a message block in
    framehistory.pas: a rounded card tinted by the chat's accent color
    (accent_color_id), a header (type icon + 24x24 avatar + name +
    time/checkmark/pin/bell) and a content area (preview + unread
    counter). framechats.pas CANNOT import framehistory.pas (that unit
    already imports framechats.pas — a cycle), so the small pieces of
    logic needed here (accent color resolution, background blending,
    rounded fill/outline) are independent copies of the same logic, see
    their own comments below, not shared code. }

  TFrameChats = class(TFrameBase, ITdActiveListener)
    Grid:      TDrawGrid;
    icons12: TImageList;
    mnuChat:   TPopupMenu;
    { 16x16, placed on the frame in the designer (the name must match
      the .lfm). Its comment used to say "chat-type icons" — those
      moved to icons12 (12x12) when the row was redesigned, and this
      list went unread for a while. It is in use again as the image
      list of the folder chip's popup: frames FOLDER_MENU_ICON_NEW/
      REMOVE, added in the designer. }
    ImageList1: TImageList;
    { 32x32 — the avatar's own size (AVATAR_SIZE). It went unread for a
      while after the "Archive"/"All chats" pseudo-rows were redesigned
      to take their icon from icons12 (12x12); it holds the skull
      stamped over a deleted account's avatar now, DELETED_ACCOUNT_ICON. }
    ImageListBig: TImageList;
    procedure GridDrawCell(Sender: TObject; ACol, ARow: Integer; ARect: TRect; AState: TGridDrawState);
    procedure GridSelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
    procedure GridTopLeftChanged(Sender: TObject);
    procedure GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure GridMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure GridMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
  protected
    { Resize is a virtual TControl method, always available regardless
      of whether the same-named event is published on the descendant.
      TDrawGrid does NOT publish it. }
    procedure Resize; override;
  private
    FCache:    TAvatarCache;
    FReady:    Boolean;
    FModel:    TTdChats;      { the active account's model }
    FBadges:   TStringList;   { badge cache: key -> TBGRABitmap }
    FMeasure:  TBGRABitmap;   { 1x1, for measuring text with the same font }
    FReceipts: array[TChatReceipt, Boolean] of TBGRABitmap;
    FMenuRow:  TChatRow;
    { The folder chip's own popup, built fresh on every click (the set
      of folders is the model's, and it changes) — a separate menu from
      mnuChat rather than a reuse of it: that one is the grid's
      right-click context menu, wired in the designer, and having two
      unrelated callers rewrite the same Items list is how one of them
      ends up showing the other's entries. Created in code, not in the
      .lfm, for the same reason its items are: nothing about it is
      designable. }
    FFolderMenu: TPopupMenu;
    { The row whose chip opened FFolderMenu — captured at click time
      and read back in FolderMenuClick, exactly like FMenuRow for the
      context menu: by the time the user picks an item the model may
      have rebuilt and the grid row under the cursor may be a
      different chat. }
    FFolderRow: TChatRow;
    FOnSelect: TChatSelectEvent;
    FOnRowsChanged: TNotifyEvent;
    FOnListMode: TListModeEvent;
    FMode:     TChatListMode;
    FOnAvatar: TAvatarClickEvent;
    { A click on an icon/avatar (chaBell/chaPin/chaAvatar) — CanSelect
      is set to False, selection doesn't move at all, FOnSelect is not
      called. }
    FSuppressSelect: Boolean;
    { A list-mode switch is in progress (chaHeader) — unlike
      FSuppressSelect, selection DOES need to move (CanSelect stays
      True — the new list's header, "Archive"/"All chats", should
      become selected, not the old row from the previous list), but
      FOnSelect is still not called — switching lists on its own must
      not open a chat. Both flags are "sticky": they don't reset
      themselves from inside GridSelectCell on the first call; the only
      place they're reset is the start of GridMouseDown, see its own
      comment for why a self-resetting, one-shot version didn't work
      (Grid.RowCount:=... in ModelChanged can, independently of
      Grid.Row:=0, synchronously re-invoke GridSelectCell again via
      CheckPosition in LCL). }
    FSwitchingMode: Boolean;
    { The chat actually open in the work area (main.pas/TFrameHistory),
      not just "whatever row Grid.Row happens to point at" — Grid.Row
      is a plain index with no memory of WHICH chat it was pointing to,
      so when the list reorders (a chat moving to the top on a new
      message), the OLD index now belongs to a DIFFERENT chat and the
      highlight silently "follows the index" instead of the actually-
      open chat. Set only on a genuine user selection (GridSelectCell,
      the FOnSelect call), read back in ModelChanged to re-sync
      Grid.Row to wherever that same chat ended up after a reorder. 0
      = no chat open (or it isn't in the currently shown list). }
    FActiveChatId: Int64;
    { One-shot, self-contained (set True, do the one Grid.Row
      assignment, set False right after — unlike FSuppressSelect/
      FSwitchingMode, this doesn't need to survive until "the next
      user gesture": the synchronous re-invocations of GridSelectCell
      that LCL may trigger from a single Grid.Row:=/RowCount:=
      assignment (CheckPosition) all happen WITHIN that one assignment
      statement, so clearing it on the very next line is safe). Makes
      the re-sync move succeed (CanSelect stays True) without being
      treated as a new selection (FOnSelect not called) and without
      being blocked by a still-pending FSuppressSelect/FSwitchingMode
      left over from an unrelated earlier click. }
    FResyncingSelection: Boolean;
    { Same idea as TMsgScroller.FCustomEmojiTimer (framehistory.pas),
      but for a different reason: this frame has no direct notification
      path at all from a custom emoji resolving in TTdMessages (a
      different model, opened chat's history) to itself — Touch there
      reaches the message scroller, never the chat list. A slower poll
      (this list doesn't need animation-grade smoothness, just eventual
      consistency once something resolves) that calls
      customemoji.AnyPendingWork and invalidates the grid if true. }
    FCustomEmojiTimer: TTimer;
    { Eased wheel scrolling, the same mechanism (and the same
      SMOOTH_SCROLL* constants) as the message history's
      TMsgScroller — deliberately one set of knobs for the whole app
      rather than a parallel one per list, so the two never drift apart
      in feel. FScrollTarget is the ABSOLUTE pixel top the glide is
      heading for; the grid itself holds the current position
      (GridScrollTop). }
    FScrollAnim: TTimer;
    FScrollTarget: Integer;
    { True only while ScrollAnimTick is driving the grid, so the
      cancel-on-foreign-movement check in GridTopLeftChanged can tell
      the glide's own steps from somebody else moving the list. }
    FAnimating: Boolean;
    { thinscrollbar.pas, replacing Grid's own native one (Grid.
      ScrollBars set to ssNone in Create) — same custom look as
      framehistory.pas's message history, see that unit's own header
      comment for why a plain TScrollBar can't be custom-painted at
      all; TDrawGrid's native scrollbar is the same kind of OS-drawn,
      non-hookable control (its Handle is created with WS_VSCROLL,
      confirmed by reading grids.pas — TCustomGrid.CreateParams — not
      guessed), just attached to the grid's own window instead of
      being a separate control. }
    FVScroll: TThinScrollBar;
    procedure CustomEmojiAnimTick(Sender: TObject);
    { The grid's current scroll offset in PIXELS, and the largest it
      can be. Read straight out of the grid (see TGridAccess) rather
      than derived from Grid.TopRow: TopRow*ROW_HEIGHT was exact only
      while every scroll was a whole multiple of a row, which stopped
      being true the moment the wheel started moving by 60px at a time.
      The maximum is computed here instead because the grid's own is
      protected too — FixedRows is 0 and every row shares ROW_HEIGHT
      (Grid.DefaultRowHeight), so it is just total height minus one
      viewport. }
    function GridScrollTop: Integer;
    function MaxScrollTop: Integer;
    { Absolute pixel scroll, applied immediately. }
    procedure ScrollGridTo(APx: Integer);
    { How far one wheel notch goes, the same answer (and the same
      reasoning about Mouse.WheelScrollLines and WHEEL_PAGESCROLL) as
      TMsgScroller.WheelNotchPx. }
    function WheelNotchPx: Integer;
    { Moves the TARGET by ADelta and lets ScrollAnimTick walk the grid
      towards it, so several quick notches add up into one glide. With
      SMOOTH_SCROLL off it scrolls the whole distance at once — still
      by pixels, still by a notch's worth rather than the grid's own
      DefaultRowHeight*WheelScrollLines (three whole cards), which is
      what made the list look like it scrolled a card at a time. }
    procedure SmoothScrollBy(ADelta: Integer);
    procedure StopScrollAnim;
    procedure ScrollAnimTick(Sender: TObject);
    { Grid.OnMouseWheel, wired in Create. Always reports the wheel as
      handled, which is what keeps TCustomGrid's own GridMouseWheel —
      the DefaultRowHeight*WheelScrollLines jump — from running after
      it (TControl.DoMouseWheel only falls through to DoMouseWheelUp/
      Down when the event left Handled False). }
    procedure GridWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    { Feeds the grid's pixel offset, row count and viewport height into
      FVScroll — called whenever any of those could have changed
      (ModelChanged, Resize, GridTopLeftChanged) and on every animation
      tick, since TopLeftChanged only fires when a whole-row boundary
      is crossed and the thumb would otherwise move in card-sized
      steps while the view glides smoothly underneath it. }
    procedure SyncVScroll;
    { FVScroll's OnScroll — drives Grid by DISPATCHING the exact same
      LM_VSCROLL message its own (now hidden) native scrollbar used to
      send it (TCustomGrid.WMVScroll, grids.pas), not a hand-rolled
      reimplementation of its smooth-scroll pixel math. Dispatch
      (TObject's, always public) is what makes this possible without
      access to any of TCustomGrid's protected scroll internals
      (TrySmoothScrollBy/GetPxTopLeft/ScrollBy). }
    procedure VScrollScroll(Sender: TObject; ScrollCode: TScrollCode; var ScrollPos: integer);
    procedure BindModel;
    procedure UnbindModel;
    { The archive is not a chat: row index 0 is reserved for it, chats
      are shifted by one. A fake TChatRow would drag it into the
      context menu and chat-opening logic, which it must not be part
      of. }
    function ChatAt(AGridRow: Integer): TChatRow;
    { Linear scan of the currently shown list (Main or Archive,
      whichever FMode is) for the grid row whose chat has this id —
      -1 if AChatId is 0 or not present in the current list (e.g. the
      open chat is in Main while Archive is being shown). Called once
      per ModelChanged, not per frame — a chat list is small enough
      that this isn't worth a reverse id->index map. }
    function FindRowIndex(AChatId: Int64): Integer;
    function TypeIconIndex(ARow: TChatRow): Integer;
    procedure DrawIcon12(const ARect: TRect; AIndex: Integer);
    { The single source of truth for a row card's geometry — both
      painting (GridDrawCell) and hit-testing (HitArea) compute it from
      here rather than keeping separate copies of the formulas (the
      same, previously documented pitfall as ContentPadV/
      ForwardCardRect in framehistory.pas). ARect is either the cell's
      real rectangle (for painting) or (0,0,Width,Height) of the same
      cell (for hit-testing, where click coordinates are already
      local). Result is the card itself (ARect minus CHATROW_GAP at the
      bottom).
      AHasPin=False (the archive list — pinning isn't allowed there)
      collapses APinR to zero width at MuteR's left edge (or, if
      AHasMute is ALSO False, at the header's own right-padding edge —
      see AHasMute below), rather than simply not drawing it: TitleRight
      (the time text's right boundary in GridDrawCell) is computed from
      PinR.Left, and without actually shrinking this rectangle the time
      would overlap the empty space where the pin icon used to be.
      AHasMute=False (the Saved Messages row — muting yourself has no
      effect, see TTdChats.IsSelfChat) collapses AMuteR to zero width at
      the header's right-padding edge the SAME way, and — since PinR is
      anchored off AMuteR.Left, not a fixed offset from the header edge
      — the pin (if AHasPin) slides right into the slot the mute icon
      would have occupied, flush against the edge, no leftover gap. }
    function ChatRowRects(const ARect: TRect; AHasPin, AHasMute, AHasArchive: Boolean;
      out AHeader, AContent, AIconR, AAvatarR, AMuteR, APinR, AArchiveR: TRect): TRect;
    { One hit test shared by everything: clicks and cursor updates
      alike. Duplicating the geometry in two places is a reliable way
      to let them drift apart over time. }
    function HitArea(X, Y: Integer; out ARow: TChatRow): TChatHitArea;
    procedure SetMode(AMode: TChatListMode);
    function RowsCount: Integer;
    procedure DrawHeaderRow(ARect: TRect; ASelected: Boolean);
    function BadgeBitmap(const AText: String; ASelected: Boolean): TBGRABitmap;
    function ReceiptBitmap(AKind: TChatReceipt; ASelected: Boolean): TBGRABitmap;
    procedure ModelChanged(Sender: TObject);
    procedure ActionError(Sender: TObject; ACode: Integer; const AMessage, AAction: Utf8string);
    procedure MaybeLoadMore;
    procedure BuildMenu(ARow: TChatRow);
    procedure MenuItemClick(Sender: TObject);
    { What the folder chip reads: the chat's folder name, or
      CHATROW_FOLDER_NONE when it is in none. }
    function FolderChipCaption(ARow: TChatRow): String;
    { The chip's rectangle. Not part of ChatRowRects (which knows
      nothing about a canvas) because the width depends on the caption
      and so has to be measured — but still a single source of truth
      shared by painting and hit-testing, the same principle.
      ARight is the right edge it may not cross. The canvas font is
      changed to measure and put back: in GridDrawCell this is called
      mid-paint, with the canvas already set up for something else. }
    function FolderChipRect(const AAvatarR: TRect; ARight: Integer;
      const ACaption: String): TRect;
    { The unread badge's rectangle — in the card's bottom right corner,
      with the same margin the avatar has on the other side. Shared by
      painting and by the folder chip's right-hand clamp (the two sit
      on the same line now), so neither has to guess the other's width.
      An EMPTY rect anchored at the corner means "no badge": its Left
      is still the boundary the chip must not cross, which keeps the
      caller free of a special case. }
    function UnreadBadgeRect(ARow: TChatRow; const AContent: TRect): TRect;
    { Right-hand boundary for the folder chip: the badge's left edge
      when there is one, the content's own padding edge otherwise. }
    function FolderChipLimit(ARow: TChatRow; const AContent: TRect): Integer;
    procedure ShowFolderMenu(ARow: TChatRow; const AScreenPos: TPoint);
    procedure FolderMenuClick(Sender: TObject);
    function CurrentRow: TChatRow;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;

    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
    property Selected: TChatRow read CurrentRow;
    property OnSelect: TChatSelectEvent read FOnSelect write FOnSelect;
    { Fired whenever the chat list itself was refreshed from the model
      (ModelChanged) — i.e. pin/mute/unread/order changed, whoever
      caused it. TTdChats.OnChanged is a single-listener event and this
      frame already owns it, so anything ELSE that shows the same
      per-chat state has to be told from here instead: right now that's
      the chat info header above the history (chatheader.pas), which
      would otherwise keep showing a stale pin/bell until the next
      message arrived — SetPinned/SetMuted only SEND the request, the
      row's own flags don't change until TDLib's update comes back. }
    property OnRowsChanged: TNotifyEvent read FOnRowsChanged write FOnRowsChanged;
    property Mode: TChatListMode read FMode write SetMode;
    property OnListMode: TListModeEvent read FOnListMode write FOnListMode;
    property OnAvatar: TAvatarClickEvent read FOnAvatar write FOnAvatar;
  end;

implementation

{ main is used in the implementation section, not the interface: main
  itself uses framechats (the permanent left-panel chat list), and
  using it from the interface would create a cycle — same approach as
  framehistory.pas/main. Needed only for FormMain.SetChatListStatus
  (the "N chats (more)" line, now shown in StatusBar1 instead of the
  removed pnlBottom). }
uses
  main;

{$R *.lfm}

type
  { Everything TCustomGrid knows about its own scrolling in PIXELS is
    protected: publicly it offers only TopRow, which is exactly the
    card-at-a-time granularity being replaced here. Declaring a
    descendant makes those members reachable from this unit — the
    standard Pascal accessor idiom, not a way around a private
    interface: they are protected precisely so that a descendant may
    use them, and nothing here writes any of the grid's state directly.

    This is the same wall the custom scrollbar already ran into
    (VScrollScroll dispatches a synthetic LM_VSCROLL rather than call
    TrySmoothScrollBy); that one stays as it is — it works, and
    rewriting a working path is not part of this. }
  TGridAccess = class(TDrawGrid);

{ Timestamp in the Telegram style: today shows the time, yesterday the
  word "yesterday", this week the weekday name, further back the date. }
function ChatTimeStr(AUnix: Int64): String;
const
  WD: array[1..7] of String = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
var
  Dt, Today: TDateTime;
  Days:      Integer;
begin
  Result := '';
  if AUnix <= 0 then begin
    Exit;
  end;
  { TDLib gives Unix time in UTC — converted to local time, otherwise
    the clock would be wrong for anyone outside UTC. }
  Dt    := UniversalTimeToLocal(UnixToDateTime(AUnix));
  Today := Date;
  Days  := Trunc(Today) - Trunc(Dt);

  if Days <= 0 then begin
    Result := FormatDateTime('hh:nn', Dt);   { 24-hour: hh, not ampm }
  end
  else if Days = 1 then begin
    Result := 'yesterday';
  end
  else if Days < 7 then begin
    Result := WD[DayOfWeek(Dt)];
  end
  else begin
    Result := FormatDateTime('dd.mm.yy', Dt);
  end;
end;

{ Chat accent color — its own copy of ResolveAccentColor
  (framehistory.pas): the same idea (accent_color_id, from
  updateChatAccentColors, see tdaccentcolors.pas, in place of a hash by
  id when it's known; a hash over SENDER_PALETTE as the fallback), but
  framechats.pas cannot import framehistory.pas (that unit already
  imports framechats.pas — a cycle), so this is an independent copy of
  the same logic rather than a shared function. }
function ChatAccentColor(ARow: TChatRow): TColor;
var
  AC: TTdAccentColors;
begin
  if ARow.AccentColorId >= 0 then begin
    AC := TdAccentColorList;
    if (AC <> nil) and AC.TryGetColor(ARow.AccentColorId, Result) then begin
      Exit;
    end;
  end;
  Result := SENDER_PALETTE[Abs(ARow.Id) mod Length(SENDER_PALETTE)];
end;

{ Blends AColor with ABackground by AOpacity (0..1) — its own copy of
  BlendWithBackground (framehistory.pas), see the comment on
  ChatAccentColor for why it's a copy rather than shared code. }
function BlendWithBackground(AColor: TColor; AOpacity: double; ABackground: TColor): TColor;
var
  Fg, Bg: longint;
begin
  Fg := ColorToRGB(AColor);
  Bg := ColorToRGB(ABackground);
  Result := RGBToColor(
    Round((Bg and $FF) + AOpacity * ((Fg and $FF) - (Bg and $FF))),
    Round(((Bg shr 8) and $FF) + AOpacity * (((Fg shr 8) and $FF) - ((Bg shr 8) and $FF))),
    Round(((Bg shr 16) and $FF) + AOpacity * (((Fg shr 16) and $FF) - ((Bg shr 16) and $FF)))
  );
end;

{ Rounded fill/outline for a row card. The drawing lives in
  cardpaint.PaintRounded, shared with the message history and the chat
  info bar; this wrapper exists only to supply this part of the UI's
  own answer to "antialiased or not".

  That answer is SMOOTH_CHROME_CORNERS (on), NOT the message history's
  SMOOTH_CORNERS (off) — and the two really are different questions,
  even though the chat list scrolls just as often. A message draws up
  to a dozen rounded rectangles that are re-composited per message; a
  row here draws three, for a card the eye rests on directly, which is
  where GDI's jagged arcs showed up once the background behind the
  cards stopped being white.

  AOptions/[rrBottomLeftSquare, rrBottomRightSquare] is the same
  "square off the bottom" trick used for the card header as with
  messages. }
procedure PaintCardRoundRect(ACanvas: TCanvas; const ABox: TRect; ARadius: single;
  AOptions: TRoundRectangleOptions; AFillColor, ABorderColor: TColor;
  ABorderWidth: single = 1);
begin
  PaintRounded(ACanvas, ABox, ARadius, AOptions, AFillColor, ABorderColor,
    SMOOTH_CHROME_CORNERS, ABorderWidth);
end;

{ ---------------- lifecycle ---------------- }

constructor TFrameChats.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FCache := TAvatarCache.Create;

  FBadges := TStringList.Create;
  FBadges.Sorted := True;
  FBadges.Duplicates := dupIgnore;
  FBadges.OwnsObjects := False;

  { Owned by the frame, so it goes with it — nothing to free by hand
    in the destructor. Its items are rebuilt per click (ShowFolderMenu). }
  FFolderMenu := TPopupMenu.Create(Self);

  FMeasure := TBGRABitmap.Create(1, 1);
  FMeasure.FontName := 'default';
  FMeasure.FontHeight := BADGE_FONT_H;
  FMeasure.FontStyle := [fsBold];
  FMeasure.FontQuality := fqFineAntialiasing;

  { So the field the chat cards float on is the window grey around the
    frame rather than a grid's default white — see GridDrawCell's
    BaseBg for the full reasoning. In code, not in the .lfm, for the
    same reason the filter buttons' GroupIndex is (chatheader.pas):
    a Designer round-trip silently drops .lfm properties whose value
    happens to match a class default, and ParentColor=True is exactly
    such a value. Parent is still nil at this point — LCL propagates
    the colour itself once the navigator parents this frame. }
  ParentColor := True;
  Grid.ParentColor := True;

  { The list's own top/bottom margin. Only the REMAINDER after a row's
    own inset is added here, so the first card ends up exactly
    CHATLIST_EDGE_MARGIN from the top — level with the chat header
    card's own margin on the other side of the splitter, which is the
    whole point of the number.

    BorderSpacing rather than a bigger row inset: the gap between two
    neighbouring cards is the sum of BOTH their insets, so growing that
    would widen it by twice as much.

    One version of this passed the FULL value instead, on the theory
    that a card clipped mid-scroll at the edge contributes no inset of
    its own and so needs the whole margin from the viewport. It does
    not: that made the first card sit 5+3=8px down, visibly below the
    header card, and the theory was chasing a symptom that had a
    completely different cause — the remainder version had been wiped
    from this file by the IDE before it ever ran (see docs/journal/), so
    "it didn't work" was never about the arithmetic.

    Max() rather than a plain subtraction, in case the row inset is
    ever tuned past the margin. }
  Grid.BorderSpacing.Top :=
    Max(0, CHATLIST_EDGE_MARGIN - (CHATROW_GAP div 2 + CHATROW_CARD_INSET));
  Grid.BorderSpacing.Bottom := Grid.BorderSpacing.Top;

  Grid.ColCount  := 1;
  Grid.FixedCols := 0;
  Grid.FixedRows := 0;
  Grid.RowCount  := 0;
  Grid.DefaultRowHeight := ROW_HEIGHT;
  { The wheel is handled by GridWheel below, so this no longer decides
    anything in practice. It stays because of what the DEFAULT is:
    mwCursor moves the SELECTION, and a selection change in this list
    opens a chat — if the handler were ever unhooked, the wheel would
    start opening chats rather than merely scrolling coarsely. }
  Grid.MouseWheelOption := mwGrid;
  Grid.OnMouseWheel := @GridWheel;
  Grid.FocusRectVisible := False;
  { The grid's own native scrollbar is hidden — FVScroll below replaces
    it. Mouse wheel scrolling (MouseWheelOption above) and keyboard
    navigation are untouched: those don't go through the scrollbar at
    all, native or custom. }
  Grid.ScrollBars := ssNone;

  FVScroll := TThinScrollBar.Create(Self);
  FVScroll.Parent := Self;
  FVScroll.Align := alRight;
  { Vertically only — the same small "floating" margin msginput.pas's
    own scrollbar has (see THIN_SCROLLBAR_MARGIN's own comment),
    applied directly here since this frame has no ChildSizing of its
    own to produce it as a side effect.

    HORIZONTALLY it is deliberately zero, which is not the same thing
    as "forgotten". Both sides of this scrollbar already have a 5px lane
    of background without it: on the left, the row card's own inset
    (CHATROW_GAP + CHATROW_CARD_INSET); on the right, the splitter,
    which is 5px wide and painted in the background color. Adding the
    margin on top doubled both to 10 — visibly wider than every other
    gap in the window, which is what was reported. Zero here puts the
    scrollbar INTO those existing lanes instead of beside them. }
  FVScroll.BorderSpacing.Top := THIN_SCROLLBAR_MARGIN;
  FVScroll.BorderSpacing.Bottom := THIN_SCROLLBAR_MARGIN;
  FVScroll.OnScroll := @VScrollScroll;

  FScrollAnim := TTimer.Create(Self);
  FScrollAnim.Interval := SMOOTH_SCROLL_MS;
  FScrollAnim.OnTimer := @ScrollAnimTick;
  FScrollAnim.Enabled := False;

  FCustomEmojiTimer := TTimer.Create(Self);
  FCustomEmojiTimer.Interval := 300;
  FCustomEmojiTimer.OnTimer := @CustomEmojiAnimTick;
  FCustomEmojiTimer.Enabled := True;

  { The flag is set last: before it, any early call (a Resize while the
    .lfm is still being read) is required to do nothing. }
  FReady := True;
  BindModel;
  TdApp.SubscribeActive(Self);
end;

destructor TFrameChats.Destroy;
var
  I: Integer;
  K: TChatReceipt;
begin
  FReady := False;
  TdApp.UnsubscribeActive(Self);
  UnbindModel;
  FCache.Free;
  if FBadges <> nil then begin
    for I := 0 to FBadges.Count - 1 do begin
      FBadges.Objects[I].Free;
    end;
    FBadges.Free;
  end;
  FMeasure.Free;
  for K := Low(TChatReceipt) to High(TChatReceipt) do begin
    FReceipts[K, False].Free;
    FReceipts[K, True].Free;
  end;
  inherited Destroy;
end;

function TFrameChats.BadgeBitmap(const AText: String; ASelected: Boolean): TBGRABitmap;
var
  Key:    String;
  Idx, W: Integer;
  Sz:     TSize;
  BgCol, FgCol: TBGRAPixel;
  B:      TBGRABitmap;
begin
  { Badge values repeat (1, 2, 3...), and antialiased text rendering
    isn't cheap — hence the cache. The key includes selection state:
    colors are inverted on a selected row. }
  if ASelected then begin
    Key := AText + #1;
  end
  else begin
    Key := AText;
  end;

  Idx := FBadges.IndexOf(Key);
  if Idx >= 0 then begin
    Result := TBGRABitmap(FBadges.Objects[Idx]);
    Exit;
  end;

  Sz := FMeasure.TextSize(AText);
  W  := Sz.cx + BADGE_PAD * 2;
  if W < BADGE_H then begin
    W := BADGE_H;
  end;

  if ASelected then begin
    { The row background is already clHighlight when selected — the
      badge would otherwise be hard to spot. Inverted, matching
      Telegram itself. }
    BgCol := ColorToBGRA(clWindow);
    FgCol := ColorToBGRA(clHighlight);
  end
  else begin
    BgCol := ColorToBGRA(clHighlight);
    FgCol := ColorToBGRA(clWindow);
  end;

  B := TBGRABitmap.Create(W, BADGE_H, BGRAPixelTransparent);
  B.FontName := 'default';
  B.FontHeight := BADGE_FONT_H;
  B.FontStyle := [fsBold];
  B.FontQuality := fqFineAntialiasing;

  { The last parameter, False, switches to corner coordinates — then
    (0,0,W,H) covers the whole bitmap with no 0.5 correction needed. }
  B.FillRoundRectAntialias(0, 0, W, BADGE_H, BADGE_H / 2, BADGE_H / 2,
    BgCol, [], False);
  B.TextOut((W - Sz.cx) / 2, (BADGE_H - Sz.cy) / 2, AText, FgCol);

  while FBadges.Count >= BADGE_CACHE_MAX do begin
    FBadges.Objects[0].Free;
    FBadges.Delete(0);
  end;
  FBadges.AddObject(Key, B);
  Result := B;
end;

function TFrameChats.ReceiptBitmap(AKind: TChatReceipt; ASelected: Boolean): TBGRABitmap;
var
  B:   TBGRABitmap;
  Col: TBGRAPixel;
  W:   Integer;

  { One checkmark, offset along X. Coordinates are chosen so the whole
    line fits in the bitmap, accounting for pen width. }
  procedure Tick(ADx: Single);
  begin
    B.DrawPolyLineAntialias(
      [PointF(ADx + 1, 5.5), PointF(ADx + 3.5, 8.5), PointF(ADx + 9, 2)],
      Col, TICK_PEN);
  end;

begin
  Result := FReceipts[AKind, ASelected];
  if (Result <> nil) or (AKind = crNone) then begin
    Exit;
  end;

  { On a selected row the background is clHighlight, so gray and accent
    colors become indistinguishable there — drawn white instead, same
    as the time. }
  if ASelected then begin
    Col := ColorToBGRA(clHighlightText);
  end
  else if AKind = crRead then begin
    Col := ColorToBGRA(clHighlight);
  end
  else if AKind = crFailed then begin
    Col := BGRA(200, 60, 60);
  end
  else begin
    Col := ColorToBGRA(clGrayText);
  end;

  if AKind = crRead then begin
    W := TICK_W + TICK_SHIFT;
  end
  else begin
    W := TICK_W;
  end;

  B := TBGRABitmap.Create(W, TICK_H, BGRAPixelTransparent);
  B.LineCap := pecRound;
  B.JoinStyle := pjsRound;

  case AKind of
    crSent: begin
      Tick(0);
    end;
    crRead: begin
      { Two overlapping checkmarks, matching Telegram. }
      Tick(0);
      Tick(TICK_SHIFT);
    end;
    crPending: begin
      { A clock: a circle with two hands. }
      B.EllipseAntialias(5.5, 5.5, 4.5, 4.5, Col, 1.2);
      B.DrawPolyLineAntialias([PointF(5.5, 3), PointF(5.5, 5.5), PointF(7.5, 6.5)],
        Col, 1.2);
    end;
    crFailed: begin
      { An exclamation mark. }
      B.DrawPolyLineAntialias([PointF(5.5, 1.5), PointF(5.5, 6.5)], Col, 1.8);
      B.DrawPolyLineAntialias([PointF(5.5, 9), PointF(5.5, 9.2)], Col, 1.8);
    end;
  end;

  FReceipts[AKind, ASelected] := B;
  Result := B;
end;

{ ---------------- binding to the active account's model ---------------- }

procedure TFrameChats.BindModel;
var
  M: TTdChats;
begin
  FModel := TdChatList;
  M      := FModel;
  if M = nil then begin
    Exit;
  end;
  M.OnChanged     := @ModelChanged;
  M.OnActionError := @ActionError;
  ModelChanged(nil);
end;

procedure TFrameChats.UnbindModel;
begin
  { Detaches only OUR handlers — someone else's must not be clobbered. }
  if FModel <> nil then begin
    if TMethod(FModel.OnChanged).Data = Pointer(Self) then begin
      FModel.OnChanged := nil;
    end;
    if TMethod(FModel.OnActionError).Data = Pointer(Self) then begin
      FModel.OnActionError := nil;
    end;
    FModel := nil;
  end;
end;

procedure TFrameChats.TdActiveChanged(ANew: TTdAccount);
begin
  if not FReady then begin
    Exit;
  end;
  UnbindModel;
  { Avatars and icons belong to the previous account — cleared here,
    otherwise stale images from it would flash in the new list. }
  FCache.Clear;
  { Chat ids are a different account's namespace — stale, it could
    coincidentally collide with one in the new account's list and have
    ModelChanged (called from BindModel below) move the highlight onto
    the wrong row of a list it was never actually set on. }
  FActiveChatId := 0;
  Grid.Row    := 0;
  Grid.TopRow := 0;
  BindModel;
end;

procedure TFrameChats.TdAccountsChanged;
begin
  { The account roster doesn't matter to the list frame }
end;

procedure TFrameChats.CustomEmojiAnimTick(Sender: TObject);
begin
  if (not FReady) or (Grid = nil) then begin
    Exit;
  end;
  if AnyPendingWork then begin
    Grid.Invalidate;
  end;
end;

{ ---------------- model wiring ---------------- }

procedure TFrameChats.ModelChanged(Sender: TObject);
var
  NewRow: Integer;
begin
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Exit;
  end;
  Grid.RowCount := RowsCount + ARCHIVE_ROWS;

  { Re-sync the highlight to the chat that's actually open, wherever a
    reorder just moved it — see FActiveChatId's own comment. Skipped
    during an explicit list-mode switch (FSwitchingMode, set by
    GridMouseDown's chaHeader case around its own call to SetMode,
    which is what gets here via ModelChanged(nil)): landing on the new
    list's header row is the deliberately correct behavior there (see
    FSwitchingMode's comment), not something this should override. }
  if (not FSwitchingMode) and (FActiveChatId <> 0) then begin
    NewRow := FindRowIndex(FActiveChatId);
    if (NewRow >= 0) and (NewRow <> Grid.Row) then begin
      FResyncingSelection := True;
      Grid.Row := NewRow;
      FResyncingSelection := False;
    end;
  end;

  Grid.Invalidate;
  { If there are fewer chats than fit in the window, load more right
    away: the scrolling that would normally trigger this won't happen. }
  MaybeLoadMore;
  { RowCount just changed above — the thumb's own size/range depends on
    it even when TopRow itself didn't move (e.g. more chats loaded at
    the bottom), which GridTopLeftChanged's own sync wouldn't catch. }
  SyncVScroll;
  if Assigned(FOnRowsChanged) then begin
    FOnRowsChanged(Self);
  end;
end;

procedure TFrameChats.ActionError(Sender: TObject; ACode: Integer; const AMessage, AAction: Utf8string);
begin
  { A TDLib refusal on a menu action must not be silent: without this,
    "Pin" on a full list would just appear to do nothing. }
  if FormMain <> nil then begin
    FormMain.SetChatListStatus(Format('Error %d: %s', [ACode, String(AMessage)]));
  end;
end;

procedure TFrameChats.MaybeLoadMore;
var
  LastVisible: Integer;
  Busy, Done:  Boolean;
begin
  { Resize fires while the .lfm is still being read, when Grid is nil. }
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Exit;
  end;

  if FMode = clmArchive then begin
    Busy := FModel.ArchiveLoading;
    Done := FModel.ArchiveAllLoaded;
  end
  else begin
    Busy := FModel.Loading;
    Done := FModel.AllLoaded;
  end;
  if Busy or Done then begin
    Exit;
  end;

  LastVisible := Grid.TopRow + (Grid.ClientHeight div ROW_HEIGHT) - ARCHIVE_ROWS;
  if LastVisible >= RowsCount - PREFETCH_ROWS then begin
    if FMode = clmArchive then begin
      FModel.LoadMoreArchive;
    end
    else begin
      FModel.LoadMore;
    end;
  end;
end;

function TFrameChats.GridScrollTop: Integer;
begin
  if Grid = nil then begin
    Result := 0;
    Exit;
  end;
  Result := TGridAccess(Grid).GetPxTopLeft.y;
end;

function TFrameChats.MaxScrollTop: Integer;
begin
  Result := 0;
  if Grid = nil then begin
    Exit;
  end;
  Result := Grid.RowCount * ROW_HEIGHT - Grid.ClientHeight;
  if Result < 0 then begin
    Result := 0;
  end;
end;

procedure TFrameChats.ScrollGridTo(APx: Integer);
begin
  if Grid = nil then begin
    Exit;
  end;
  { Relative, because that is the only pixel move the grid offers, and
    it clamps to its own real limits on the way — which is also why
    ScrollAnimTick checks whether anything actually moved rather than
    trusting MaxScrollTop's arithmetic to agree with it exactly. }
  TGridAccess(Grid).TrySmoothScrollBy(0, APx - GridScrollTop);
end;

function TFrameChats.WheelNotchPx: Integer;
var
  Lines, ViewH: Integer;
begin
  Lines := Mouse.WheelScrollLines;
  ViewH := 0;
  if Grid <> nil then begin
    ViewH := Grid.ClientHeight;
  end;
  { Windows reports "one screen at a time" as WHEEL_PAGESCROLL, too
    large for the signed Integer LCL returns it in, so it arrives
    negative; that and the ordinary one-page clamp have the same
    answer. Floor of one line so a viewport shorter than a line still
    scrolls by something. }
  if (Lines <= 0) or (Lines * WHEEL_LINE_PX > ViewH) then begin
    Result := ViewH;
    if Result < WHEEL_LINE_PX then begin
      Result := WHEEL_LINE_PX;
    end;
    Exit;
  end;
  Result := Lines * WHEEL_LINE_PX;
end;

procedure TFrameChats.SmoothScrollBy(ADelta: Integer);
var
  MaxTop: Integer;
begin
  if Grid = nil then begin
    Exit;
  end;
  if not SMOOTH_SCROLL then begin
    ScrollGridTo(GridScrollTop + ADelta);
    SyncVScroll;
    Exit;
  end;
  MaxTop := MaxScrollTop;
  { A glide already under way keeps its target and has this notch added
    to it; one that has finished starts again from where the view
    actually is. }
  if not FScrollAnim.Enabled then begin
    FScrollTarget := GridScrollTop;
  end;
  FScrollTarget := FScrollTarget + ADelta;
  if FScrollTarget < 0 then begin
    FScrollTarget := 0;
  end;
  if FScrollTarget > MaxTop then begin
    FScrollTarget := MaxTop;
  end;
  if FScrollTarget <> GridScrollTop then begin
    FScrollAnim.Enabled := True;
  end;
end;

procedure TFrameChats.StopScrollAnim;
begin
  if (FScrollAnim <> nil) and FScrollAnim.Enabled then begin
    FScrollAnim.Enabled := False;
    FScrollTarget := GridScrollTop;
  end;
end;

procedure TFrameChats.ScrollAnimTick(Sender: TObject);
var
  Cur, Diff, Step, MaxTop: Integer;
begin
  if Grid = nil then begin
    FScrollAnim.Enabled := False;
    Exit;
  end;
  { Re-clamped every tick rather than once when it was set: rows can
    arrive (LoadMore) or the panel can be resized under a running
    glide. }
  MaxTop := MaxScrollTop;
  if FScrollTarget > MaxTop then begin
    FScrollTarget := MaxTop;
  end;
  if FScrollTarget < 0 then begin
    FScrollTarget := 0;
  end;

  Cur := GridScrollTop;
  Diff := FScrollTarget - Cur;
  FAnimating := True;
  try
    if Abs(Diff) <= SMOOTH_SCROLL_SNAP then begin
      FScrollAnim.Enabled := False;
      ScrollGridTo(FScrollTarget);
      SyncVScroll;
      Exit;
    end;
    Step := Round(Diff * SMOOTH_SCROLL_FACTOR);
    { Rounding to zero near the end would leave the glide creeping
      forever; one pixel in the right direction guarantees it reaches
      the snap window. }
    if Step = 0 then begin
      if Diff > 0 then begin
        Step := 1;
      end
      else begin
        Step := -1;
      end;
    end;
    TGridAccess(Grid).TrySmoothScrollBy(0, Step);
    { The grid refused to move: it is against one of its own limits,
      and the rest of the distance is never going to be covered no
      matter how many more ticks are spent on it. }
    if GridScrollTop = Cur then begin
      FScrollAnim.Enabled := False;
      FScrollTarget := Cur;
    end;
    SyncVScroll;
  finally
    FAnimating := False;
  end;
end;

procedure TFrameChats.GridWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
begin
  Handled := True;
  SmoothScrollBy(-(WheelDelta div 120) * WheelNotchPx);
end;

procedure TFrameChats.SyncVScroll;
begin
  if (not FReady) or (Grid = nil) or (FVScroll = nil) then begin
    Exit;
  end;
  FVScroll.SetParams(GridScrollTop, 0, Grid.RowCount * ROW_HEIGHT, Grid.ClientHeight);
end;

procedure TFrameChats.VScrollScroll(Sender: TObject; ScrollCode: TScrollCode; var ScrollPos: integer);
var
  Msg: TLMVScroll;
  WinCode: SmallInt;
begin
  if Grid = nil then begin
    Exit;
  end;
  { Direct manipulation wins outright: a glide still running would keep
    pulling the view away from the thumb the user is holding. }
  StopScrollAnim;
  case ScrollCode of
    scTrack:    WinCode := SB_THUMBTRACK;
    scPosition: WinCode := SB_THUMBPOSITION;
  else
    { scEndScroll (the only other code FVScroll ever sends) — the
      preceding scTrack/scPosition already applied the real position;
      a native scrollbar's own SB_ENDSCROLL carries no position update
      of its own either. }
    Exit;
  end;
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.Msg := LM_VSCROLL;
  Msg.ScrollCode := WinCode;
  Msg.Pos := ScrollPos;
  Grid.Dispatch(Msg);
  { Fed back into the thumb directly here, not only through Grid's own
    OnTopLeftChanged (GridTopLeftChanged/SyncVScroll below): that event
    only fires when a WHOLE-ROW boundary is crossed
    (TCustomGrid.TrySmoothScrollBy, grids.pas — checked, not guessed),
    so relying on it alone while dragging would make the thumb feel
    stepped/row-snapped instead of tracking the cursor smoothly. Any
    rounding difference between this and the grid's own settled state
    is corrected on the very next real sync (wheel, resize, a new
    ModelChanged) — never visible for more than one frame. }
  FVScroll.SetParams(ScrollPos, 0, Grid.RowCount * ROW_HEIGHT, Grid.ClientHeight);
end;

procedure TFrameChats.GridTopLeftChanged(Sender: TObject);
begin
  { Something other than the glide moved the list — a selection
    change, the keyboard, a scroll the model asked for — so the glide
    has been overtaken and its target is stale. }
  if not FAnimating then begin
    StopScrollAnim;
  end;
  MaybeLoadMore;
  SyncVScroll;
end;

procedure TFrameChats.Resize;
begin
  inherited Resize;
  { Column width is handled by the grid's AutoFillColumns. All that's
    left here is loading more: a bigger window means more rows visible. }
  MaybeLoadMore;
  SyncVScroll;
end;

function TFrameChats.RowsCount: Integer;
begin
  if FModel = nil then begin
    Result := 0;
  end
  else if FMode = clmArchive then begin
    Result := FModel.ArchiveCount;
  end
  else begin
    Result := FModel.Count;
  end;
end;

function TFrameChats.ChatAt(AGridRow: Integer): TChatRow;
begin
  { Row zero is the header, there's no chat behind it. }
  Result := nil;
  if (FModel = nil) or (AGridRow < ARCHIVE_ROWS) then begin
    Exit;
  end;
  if FMode = clmArchive then begin
    Result := FModel.ArchiveRows[AGridRow - ARCHIVE_ROWS];
  end
  else begin
    Result := FModel[AGridRow - ARCHIVE_ROWS];
  end;
end;

function TFrameChats.FindRowIndex(AChatId: Int64): Integer;
var
  GridRow, Last: Integer;
  R: TChatRow;
begin
  Result := -1;
  if (FModel = nil) or (AChatId = 0) then begin
    Exit;
  end;
  Last := RowsCount + ARCHIVE_ROWS - 1;
  for GridRow := ARCHIVE_ROWS to Last do begin
    R := ChatAt(GridRow);
    if (R <> nil) and (R.Id = AChatId) then begin
      Result := GridRow;
      Exit;
    end;
  end;
end;

procedure TFrameChats.SetMode(AMode: TChatListMode);
begin
  if FMode = AMode then begin
    Exit;
  end;
  FMode := AMode;
  if Grid <> nil then begin
    Grid.TopRow := 0;
    Grid.Row    := 0;
  end;
  ModelChanged(nil);
  if Assigned(FOnListMode) then begin
    FOnListMode(Self, FMode);
  end;
end;

function TFrameChats.TypeIconIndex(ARow: TChatRow): Integer;
begin
  Result := -1;
  if (ARow = nil) or (FModel = nil) then begin
    Exit;
  end;

  case ARow.Kind of
    ckChannel:
      Result := CHATROW_ICON_CHANNEL;
    ckBasicGroup, ckSupergroup:
      Result := CHATROW_ICON_GROUP;
    ckPrivate, ckSecret: begin
        { Being a bot is a property of the peer, not the chat: the
          chat's own type is still private either way. The flag comes
          from a separate updateUser. }
      if FModel.IsBotChat(ARow) then begin
        Result := CHATROW_ICON_BOT;
      end
      else begin
        Result := CHATROW_ICON_PRIVATE;
      end;
    end;
  end;
end;

procedure TFrameChats.DrawIcon12(const ARect: TRect; AIndex: Integer);
begin
  if (AIndex < 0) or (icons12 = nil) or (AIndex >= icons12.Count) then begin
    Exit;
  end;
  icons12.Draw(Grid.Canvas, ARect.Left, ARect.Top, AIndex, True);
end;

function TFrameChats.ChatRowRects(const ARect: TRect; AHasPin, AHasMute, AHasArchive: Boolean;
  out AHeader, AContent, AIconR, AAvatarR, AMuteR, APinR, AArchiveR: TRect): TRect;
var
  IconY, RightEdge: Integer;
begin
  { The card is ARect inset by CHATROW_GAP left/right (from the list's
    edge) and, vertically, by HALF of CHATROW_GAP on both top AND
    bottom — the whole 4px gap used to go entirely to the bottom (the
    same idea as MSG_GAP for messages, "after the block"), which made
    the card visually start right at the top edge of the list row; the
    card's total height is unchanged, the 4px still goes entirely to
    the gap, just split evenly between both sides instead of only the
    bottom.

    CHATROW_CARD_INSET is then added to all four sides alike (by direct
    request) — the card does NOT get shorter for it: ROW_HEIGHT already
    includes its vertical share. }
  Result := Rect(
    ARect.Left + CHATROW_GAP + CHATROW_CARD_INSET,
    ARect.Top + CHATROW_GAP div 2 + CHATROW_CARD_INSET,
    ARect.Right - CHATROW_GAP - CHATROW_CARD_INSET,
    ARect.Bottom - CHATROW_GAP div 2 - CHATROW_CARD_INSET);

  AHeader := Rect(Result.Left, Result.Top, Result.Right, Result.Top + CHATROW_HEADER_BAR_H);
  AContent := Rect(Result.Left, AHeader.Bottom, Result.Right, Result.Bottom);

  { The header no longer has an avatar (it moved into the content area,
    see below): left to right, just the chat-type icon, then the name
    (whose width depends on the time/checkmark text — computed at the
    point of drawing, not here). }
  IconY := AHeader.Top + (CHATROW_HEADER_BAR_H - CHATROW_ICON_SIZE) div 2;
  AIconR := Rect(AHeader.Left + MSG_PAD_H, IconY,
    AHeader.Left + MSG_PAD_H + CHATROW_ICON_SIZE, IconY + CHATROW_ICON_SIZE);

  { The avatar lives in the content area, before the message preview,
    vertically centered on the same height as the area itself
    (CHATROW_CONTENT_H is computed SPECIFICALLY around the avatar, see
    constants.pas).

    Inset by MSG_PAD_V on the left, not MSG_PAD_H: that is the SAME
    number the content area already leaves above and below it, so the
    avatar sits in an even margin on three sides instead of a wider
    one on the left (by direct request). MSG_PAD_H stays the text
    padding everywhere else on the card. }
  AAvatarR := Rect(AContent.Left + MSG_PAD_V, AContent.Top + MSG_PAD_V,
    AContent.Left + MSG_PAD_V + AVATAR_SIZE, AContent.Top + MSG_PAD_V + AVATAR_SIZE);

  { Right to left: the notification bell (at the very edge), then the
    pin, then archive/unarchive. Further left (checkmark/time) is variable width,
    computed at the point of drawing, and not part of the hit test
    (not clickable). RightEdge is the "next icon goes here" cursor —
    starts at the header's own right padding edge, and only moves left
    (by one icon's width plus a GAP) when an icon actually occupies that
    slot; a disabled icon collapses to a zero-width point at the CURRENT
    RightEdge and leaves it untouched, so the next real icon (if any)
    slides flush into the freed slot instead of leaving an empty gap
    behind a bell/pin that was never drawn — see the comment on the
    declaration. }
  RightEdge := AHeader.Right - MSG_PAD_H;
  if AHasMute then begin
    AMuteR := Rect(RightEdge - CHATROW_ICON_SIZE, IconY, RightEdge, IconY + CHATROW_ICON_SIZE);
    RightEdge := AMuteR.Left - GAP;
  end
  else begin
    AMuteR := Rect(RightEdge, IconY, RightEdge, IconY + CHATROW_ICON_SIZE);
  end;
  if AHasPin then begin
    APinR := Rect(RightEdge - CHATROW_ICON_SIZE, IconY, RightEdge, IconY + CHATROW_ICON_SIZE);
    RightEdge := APinR.Left - GAP;
  end
  else begin
    { Pinning isn't allowed in the archive — collapsed to zero width,
      not simply "not drawn": TitleRight in GridDrawCell is computed
      from the LEFTMOST icon slot, and the time needs to butt right up
      against whatever real icon precedes it, as if the pin slot had
      never existed. }
    APinR := Rect(RightEdge, IconY, RightEdge, IconY + CHATROW_ICON_SIZE);
  end;
  if AHasArchive then begin
    AArchiveR := Rect(RightEdge - CHATROW_ICON_SIZE, IconY, RightEdge, IconY + CHATROW_ICON_SIZE);
  end
  else begin
    AArchiveR := Rect(RightEdge, IconY, RightEdge, IconY + CHATROW_ICON_SIZE);
  end;
end;

procedure TFrameChats.DrawHeaderRow(ARect: TRect; ASelected: Boolean);
var
  Cv:    TCanvas;
  Badge: TBGRABitmap;
  A:     TArchiveInfo;
  Card, Header, Content, IconR, AvatarR, MuteR, PinR, ArchiveR: TRect;
  BodyFill, HeaderFill, BorderCol: TColor;
  PrevRight, Y, IconIdx: Integer;
  S, Title: String;
begin
  Cv := Grid.Canvas;

  { In the main list, the header leads to the archive; in the archive,
    back to the main list. The summary shown is for the list it leads
    TO. Same card look as a real chat — just without time/avatar/pin/
    notification icons (which is what keeps it a "pseudo-row" rather
    than a real chat) and a fixed CHATROW_PSEUDO_COLOR instead of
    ChatAccentColor. }
  if FMode = clmArchive then begin
    A       := FModel.MainInfo;
    IconIdx := CHATROW_ICON_ALLCHATS;
    Title   := 'All chats';
  end
  else begin
    A       := FModel.Archive;
    IconIdx := CHATROW_ICON_ARCHIVE;
    Title   := 'Archive';
  end;

  { AvatarR/MuteR/PinR use the same geometry as real chats but simply
    go unused here (this card has none of them). AHasPin/AHasMute don't
    matter (both False for consistency — there's no icon from either
    pair here either way). }
  { No per-row buttons on the pseudo-row: it IS the archive, and the
    whole row is one click target (chaHeader). }
  Card := ChatRowRects(ARect, False, False, False,
    Header, Content, IconR, AvatarR, MuteR, PinR, ArchiveR);

  if ASelected then begin
    Cv.Brush.Color := BlendWithBackground(CHATROW_PSEUDO_COLOR, CHATROW_SELECTED_OPACITY, clWindow);
    Cv.Brush.Style := bsSolid;
    Cv.FillRect(ARect);
  end;

  BodyFill   := BlendWithBackground(CHATROW_PSEUDO_COLOR, SENDER_BG_OPACITY, clWindow);
  HeaderFill := BlendWithBackground(CHATROW_PSEUDO_COLOR, SENDER_HEADER_OPACITY, clWindow);
  BorderCol  := BlendWithBackground(CHATROW_PSEUDO_COLOR, SENDER_BORDER_OPACITY, clWindow);

  PaintCardRoundRect(Cv, Card, CHATROW_CORNER_RADIUS, [], BodyFill, clNone);
  PaintCardRoundRect(Cv, Header, CHATROW_CORNER_RADIUS,
    [rrBottomLeftSquare, rrBottomRightSquare], HeaderFill, clNone);

  DrawIcon12(IconR, IconIdx);

  Cv.Brush.Style := bsClear;
  Cv.Font.Style  := [fsBold];
  Cv.Font.Height := -13;
  Cv.Font.Color  := clWindowText;
  Cv.TextRect(Rect(IconR.Right + MSG_ICON_GAP, Header.Top, Header.Right - MSG_PAD_H, Header.Bottom),
    IconR.Right + MSG_ICON_GAP, Header.Top + (CHATROW_HEADER_BAR_H - Cv.TextHeight(Title)) div 2, Title);

  { The counter shows the number of unread CHATS in the archive,
    matching Telegram — in the content area, the same spot as the
    unread-message counter on a real chat. }
  PrevRight := Content.Right - MSG_PAD_H;
  if A.UnreadChats > 0 then begin
    Badge := BadgeBitmap(IntToStr(A.UnreadChats), False);
    if Badge <> nil then begin
      Y := Content.Top + (CHATROW_CONTENT_H - Badge.Height) div 2;
      Badge.Draw(Cv, PrevRight - Badge.Width, Y, False);
      Dec(PrevRight, Badge.Width + GAP);
    end;
  end;

  Cv.Brush.Style := bsClear;
  Cv.Font.Style  := [];
  Cv.Font.Height := -12;
  Cv.Font.Color  := clGrayText;
  S := String(A.Preview);
  if S = '' then begin
    if A.TotalChats > 0 then begin
      S := Format('%d chats', [A.TotalChats]);
    end
    else begin
      S := 'Empty';
    end;
  end;
  { With no avatar, the text starts right at the content area's left
    edge (not after AvatarR, as with a real chat), vertically centered
    on the same line. }
  { A.Preview is a comma-joined list of chat TITLES (see the archive
    summary builder), not one chat's last-message text — there's no
    entity data captured for chat titles anywhere in the model, so this
    one has no custom-emoji glyphs to pass, unlike the real preview
    below. }
  DrawEmojiLine(Cv, Rect(Content.Left + MSG_PAD_H, Content.Top, PrevRight, Content.Bottom),
    Content.Left + MSG_PAD_H, Content.Top + (CHATROW_CONTENT_H - Cv.TextHeight(S)) div 2, S, nil);

  PaintCardRoundRect(Cv, Card, CHATROW_CORNER_RADIUS, [], clNone, BorderCol);
end;

{ ---------------- drawing ---------------- }

procedure TFrameChats.GridDrawCell(Sender: TObject; ACol, ARow: Integer; ARect: TRect; AState: TGridDrawState);
var
  R:   TChatRow;
  Cv:  TCanvas;
  Bmp, Badge, Rec, StatusBmp: TBGRABitmap;
  Card, Header, Content, IconR, AvatarR, MuteR, PinR, ArchiveR: TRect;
  BaseBg, Accent, BodyFill, HeaderFill, BorderCol: TColor;
  TitleRight, PrevRight, W, MuteIdx, PinIdx: Integer;
  NameLeft, NameEndX, StatusSize, StatusX: Integer;
  Sel: Boolean;
  IsSelf: Boolean;
  S:   String;
  PrevGlyphs: TCustomGlyphSpanArray;
  GlyphShift, GI: Integer;
  ChipR, BadgeR: TRect;
  ChipCap: String;
  ChipColor, ChipFill: TColor;
begin
  { FCache is created in the constructor's body, i.e. after streaming.
    If the grid requests a paint before that finishes, it's nil here. }
  if (not FReady) or (FCache = nil) or (FModel = nil) then begin
    Exit;
  end;
  R  := ChatAt(ARow);
  Cv := Grid.Canvas;

  Sel := gdSelected in AState;
  if Sel then begin
    BaseBg := clHighlight;
  end
  else begin
    { The surface the cards FLOAT ON, not the cards themselves — the
      window grey the chat header bar and the rest of the work area
      already use, by direct request. It used to be a hard-coded
      clWindow, which put a second, brighter surface in the
      CHATROW_GAP gaps between and around the cards.

      Resolved through the parent chain (Create turns ParentColor on
      for both this grid and the frame) rather than named outright, so
      it keeps following whatever the form around it uses; the CARDS
      stay blended against clWindow below, which is what keeps them
      reading as light panels lying on top of this. }
    BaseBg := Grid.GetRGBColorResolvingParent;
  end;
  Cv.Brush.Color := BaseBg;
  Cv.Brush.Style := bsSolid;
  Cv.FillRect(ARect);

  if ARow < ARCHIVE_ROWS then begin
    DrawHeaderRow(ARect, Sel);
    Exit;
  end;

  if R = nil then begin
    Exit;
  end;

  { TDrawGrid only calls OnDrawCell for visible cells — no separate
    FirstVisible/LastVisible bookkeeping needed here, unlike the message
    history's own AutoDownloadVisible (framehistory.pas). Cheap no-op
    for the common case (no custom-emoji glyphs in this row's preview),
    see EnsureCustomEmojiForRow's own comment (tdchats.pas). }
  FModel.EnsureCustomEmojiForRow(R);

  { The fill "behind the card" on selection uses the contact's own
    color, not the system clHighlight — it overlays the generic fill
    already done above (BaseBg=clHighlight), which is shared with the
    "Archive"/"All chats" pseudo-row and is unaffected by this. The
    card itself (body/header/outline below) no longer reacts to Sel at
    all — it's always computed against clWindow; the only visible
    selection cue is this surrounding fill, in the CHATROW_GAP gaps. }
  Accent := ChatAccentColor(R);
  if Sel then begin
    Cv.Brush.Color := BlendWithBackground(Accent, CHATROW_SELECTED_OPACITY, clWindow);
    Cv.Brush.Style := bsSolid;
    Cv.FillRect(ARect);
  end;

  { Pinning isn't allowed in the archive — the pin icon isn't drawn at
    all, not merely disabled. Saved Messages loses two of the three
    buttons for the same "the action makes no sense here" reason:
    muting has no effect (you can't mute notifications from yourself),
    and archiving your own notes away is not something to offer on a
    one-pixel-wide icon (by direct request). }
  IsSelf := FModel.IsSelfChat(R);
  Card := ChatRowRects(ARect, FMode <> clmArchive, not IsSelf, not IsSelf,
    Header, Content, IconR, AvatarR, MuteR, PinR, ArchiveR);

  { The card uses the same visual language as a message block: body
    (SENDER_BG_OPACITY), header on top (SENDER_HEADER_OPACITY, more
    prominent — its bottom is squared off so a rounded corner doesn't
    poke into the body), outline last, on top of everything. }
  BodyFill   := BlendWithBackground(Accent, SENDER_BG_OPACITY, clWindow);
  HeaderFill := BlendWithBackground(Accent, SENDER_HEADER_OPACITY, clWindow);
  BorderCol  := BlendWithBackground(Accent, SENDER_BORDER_OPACITY, clWindow);

  PaintCardRoundRect(Cv, Card, CHATROW_CORNER_RADIUS, [], BodyFill, clNone);
  PaintCardRoundRect(Cv, Header, CHATROW_CORNER_RADIUS,
    [rrBottomLeftSquare, rrBottomRightSquare], HeaderFill, clNone);

  { The avatar is requested only for rows that are actually being
    painted — that's the laziness: only what's visible gets downloaded.
    Drawn in the content area, before the preview text — its position
    is already computed in AvatarR. }
  FModel.EnsureAvatar(R);
  Bmp := FCache.Get(R);
  if Bmp <> nil then begin
    { Opaque=False — alpha blending over the already-filled background.
      This is what gives a soft edge on any background, selection
      included. }
    Bmp.Draw(Cv, AvatarR.Left, AvatarR.Top, False);
  end;

  { A deleted account has no photo and no initials to fall back on (its
    name is empty, which is the whole reason the title is substituted
    below), so the avatar is a bare colored disc. The skull goes on top
    of it rather than instead of it — the disc keeps the chat's own
    color, the way every other row's does. Centered rather than drawn
    at AvatarR's corner: the two are the same size today, and this
    stays right if either one is retuned. }
  if FModel.IsDeletedUser(R) and (ImageListBig <> nil)
     and (DELETED_ACCOUNT_ICON < ImageListBig.Count) then begin
    ImageListBig.Draw(Cv,
      AvatarR.Left + (AVATAR_SIZE - ImageListBig.Width) div 2,
      AvatarR.Top + (AVATAR_SIZE - ImageListBig.Height) div 2,
      DELETED_ACCOUNT_ICON, True);
  end;

  DrawIcon12(IconR, TypeIconIndex(R));

  { Premium crown — right after the chat-type icon, before the name.
    An ordinary icons12 frame, so it sits on the same baseline and at
    the same size as the type icon it follows (IconR), with no
    centering of its own to keep in step. }
  NameLeft := IconR.Right + MSG_ICON_GAP;
  if FModel.IsPremiumUser(R) then begin
    DrawIcon12(Rect(NameLeft, IconR.Top, NameLeft + CHATROW_ICON_SIZE,
      IconR.Bottom), CHATROW_ICON_PREMIUM);
    NameLeft := NameLeft + CHATROW_ICON_SIZE + MSG_ICON_GAP;
  end;

  if not IsSelf then begin
    if R.IsMuted then begin
      MuteIdx := CHATROW_ICON_NOTIFY_OFF;
    end
    else begin
      MuteIdx := CHATROW_ICON_NOTIFY_ON;
    end;
    DrawIcon12(MuteR, MuteIdx);
  end;

  if FMode <> clmArchive then begin
    if R.IsPinned then begin
      PinIdx := CHATROW_ICON_PIN;
    end
    else begin
      PinIdx := CHATROW_ICON_UNPIN;
    end;
    DrawIcon12(PinR, PinIdx);
  end;

  { Archive/unarchive — the icon shows what the CLICK WILL DO, not the
    current state (there is no "state" to show: which list the row is
    in is already obvious from which list you are looking at). In the
    main list that means the archive box, in the archive the crossed-out
    one. }
  if not IsSelf then begin
    if FMode = clmArchive then begin
      DrawIcon12(ArchiveR, CHATROW_ICON_UNARCHIVE);
    end
    else begin
      DrawIcon12(ArchiveR, CHATROW_ICON_ARCHIVE);
    end;
  end;

  Cv.Brush.Style := bsClear;

  { --- header: time + read receipt, right to left from the pin ---
    Text colors inside the card no longer depend on Sel (see the
    comment above about the "behind the card" fill) — the card looks
    the same whether the row is selected or not; the selection cue is
    the fill surrounding it. }
  { From the LEFTMOST icon slot, which is the archive button now — not
    the pin. }
  TitleRight := ArchiveR.Left - GAP;
  S := ChatTimeStr(R.LastDate);
  if S <> '' then begin
    Cv.Font.Style  := [];
    Cv.Font.Height := -11;
    Cv.Font.Color := clGrayText;
    W := Cv.TextWidth(S);
    Cv.TextOut(TitleRight - W, Header.Top + (CHATROW_HEADER_BAR_H - Cv.TextHeight(S)) div 2, S);
    Dec(TitleRight, W + GAP);

    { The read receipt sits to the left of the time, outgoing messages
      only. }
    Rec := ReceiptBitmap(ChatReceipt(R), False);
    if Rec <> nil then begin
      Rec.Draw(Cv, TitleRight - Rec.Width, Header.Top + (CHATROW_HEADER_BAR_H - Rec.Height) div 2, False);
      Dec(TitleRight, Rec.Width + 3);
    end;
  end;

  { --- name --- }
  Cv.Font.Style  := [fsBold];
  Cv.Font.Height := -13;
  Cv.Font.Color := Accent;
  { TDLib hands over an empty name for a deleted account (first_name
    and last_name both blank, see tdchats.IsDeletedUser), so the card
    would carry no name at all — a stand-in is written instead. }
  if FModel.IsDeletedUser(R) then begin
    S := DELETED_ACCOUNT_TITLE;
  end
  else begin
    S := String(R.Title);
  end;
  { No entity data is captured for chat titles (see the comment on
    A.Preview's own DrawEmojiLine call below) — nil. NameLeft, not
    IconR.Right + MSG_ICON_GAP directly: the crown above may have
    pushed it further right. }
  NameEndX := DrawEmojiLine(Cv, Rect(NameLeft, Header.Top, TitleRight, Header.Bottom),
    NameLeft, Header.Top + (CHATROW_HEADER_BAR_H - Cv.TextHeight(S)) div 2, S, nil);

  { Premium "emoji status" — normally right after the name (NameEndX,
    DrawEmojiLine's own return value). When the list is too narrow for
    that to fit before TitleRight (the receipt/time boundary), it
    "sticks" there instead of disappearing: clamped to TitleRight minus
    its own width, drawn on top of whatever tail of the (already
    clipped) name ends up underneath it — glued to the edge and
    overlapping if it must, rather than a fit-or-hide check that could
    make it vanish. }
  if R.EmojiStatusCustomEmojiId <> 0 then begin
    StatusSize := Cv.TextHeight(S);
    StatusBmp := CustomEmojiStaticBitmapFor(R.EmojiStatusCustomEmojiId, StatusSize);
    if StatusBmp <> nil then begin
      if NameEndX + MSG_ICON_GAP + StatusBmp.Width <= TitleRight then begin
        StatusX := NameEndX + MSG_ICON_GAP;
      end else begin
        StatusX := TitleRight - StatusBmp.Width;
      end;
      { Backed with the header's own fill (HeaderFill, same color as the
        strip behind it) BEFORE drawing the glyph — in the clamped case
        above it sits on top of the name's own (still-visible) tail, and
        without this the glyph's transparent edges would let that text
        show through right behind it, reading as smeared into it rather
        than a separate badge. }
      Cv.Brush.Style := bsSolid;
      Cv.Brush.Color := HeaderFill;
      Cv.FillRect(Rect(StatusX, Header.Top + (CHATROW_HEADER_BAR_H - StatusBmp.Height) div 2,
        StatusX + StatusBmp.Width, Header.Top + (CHATROW_HEADER_BAR_H - StatusBmp.Height) div 2 + StatusBmp.Height));
      Cv.Brush.Style := bsClear;
      StatusBmp.Draw(Cv, StatusX, Header.Top + (CHATROW_HEADER_BAR_H - StatusBmp.Height) div 2, False);
    end;
  end;

  { --- last-message preview + unread counter ---
    The counter now sits in the card's bottom right corner, with the
    same margin the avatar has on the left (by direct request), rather
    than centered on the content area. Two things follow from that: the
    preview line above is no longer shortened by it at all (it runs the
    full width of the card), and the badge shares its line with the
    folder chip instead — which is what FolderChipLimit is for. }
  Cv.Brush.Style := bsClear;
  PrevRight := Content.Right - MSG_PAD_H;
  BadgeR := UnreadBadgeRect(R, Content);
  if BadgeR.Right > BadgeR.Left then begin
    if R.UnreadCount > 0 then begin
      S := IntToStr(R.UnreadCount);
    end
    else begin
      S := '';
    end;
    Badge := BadgeBitmap(S, False);
    if Badge <> nil then begin
      Badge.Draw(Cv, BadgeR.Left, BadgeR.Top, False);
    end;
  end;

  Cv.Font.Style  := [];
  Cv.Font.Height := -12;
  Cv.Font.Color := clGrayText;
  S := String(R.LastText);
  GlyphShift := 0;
  if R.LastIsOutgoing and (S <> '') then begin
    S := 'You: ' + S;
    GlyphShift := Length('You: ');
  end;
  { R.LastGlyphs (tdchats.TPreviewGlyph, no LCL dependency there) ->
    emojiassets.TCustomGlyphSpan, shifted by the "You: " prefix above if
    it was added — same byte-offset-shift idea as MessagePreview's own
    CaptionOr prefix (tdchats.pas), just applied here instead, since
    "You: " is a framechats.pas-only presentation detail the model
    itself knows nothing about. }
  SetLength(PrevGlyphs, Length(R.LastGlyphs));
  for GI := 0 to High(R.LastGlyphs) do begin
    PrevGlyphs[GI].ByteStart := R.LastGlyphs[GI].ByteStart + GlyphShift;
    PrevGlyphs[GI].ByteLen := R.LastGlyphs[GI].ByteLen;
    PrevGlyphs[GI].CustomEmojiId := R.LastGlyphs[GI].CustomEmojiId;
  end;
  { Starts right after the avatar (which lives here now, see AvatarR/
    ChatRowRects) and level with its top edge — the line no longer sits
    centered on the avatar, because it now shares those 44px with the
    folder chip underneath it (by direct request; see
    CHATROW_LINE_INSET). The clip rectangle ends where the chip begins
    so an over-long preview can't run into it. }
  ChipCap := FolderChipCaption(R);
  ChipR := FolderChipRect(AvatarR, FolderChipLimit(R, Content), ChipCap);
  DrawEmojiLine(Cv, Rect(AvatarR.Right + MSG_ICON_GAP, Content.Top,
    PrevRight, ChipR.Top),
    AvatarR.Right + MSG_ICON_GAP, AvatarR.Top + CHATROW_LINE_INSET, S,
    PrevGlyphs);

  { --- folder chip ---
    A pill in the chat's own accent color when it belongs to a folder,
    grey when it doesn't — outline and text. The fill is HeaderFill,
    the very same color as the card's header strip (direct request):
    the chip reads as a button that way instead of as a hole in the
    card, and it can't be mistaken for the body tint underneath it,
    which is the weaker SENDER_BG_OPACITY blend. A chat in no folder
    gets a fixed grey instead (CHATROW_FOLDER_NONE_FILL) — there is no
    folder accent to echo. }
  if FModel.RowFolderId(R) <> 0 then begin
    ChipColor := Accent;
    ChipFill  := HeaderFill;
  end
  else begin
    ChipColor := clGrayText;
    ChipFill  := CHATROW_FOLDER_NONE_FILL;
  end;
  PaintCardRoundRect(Cv, ChipR, CHATROW_FOLDER_RADIUS, [], ChipFill, ChipColor);
  Cv.Brush.Style := bsClear;
  Cv.Font.Style  := [];
  Cv.Font.Height := CHATROW_FOLDER_FONT_H;
  Cv.Font.Color  := ChipColor;
  { TextRect, not TextOut: a folder name wider than the room left on
    the row is clipped to the chip instead of spilling across the card.
    DrawEmojiLine isn't used here — a chatFolderName may only carry
    custom emoji entities (schema), and those aren't fetched for folder
    titles. }
  Cv.TextRect(Rect(ChipR.Left + CHATROW_FOLDER_PAD_H, ChipR.Top,
      ChipR.Right - CHATROW_FOLDER_PAD_H, ChipR.Bottom),
    ChipR.Left + CHATROW_FOLDER_PAD_H,
    ChipR.Top + (CHATROW_FOLDER_H - Cv.TextHeight(ChipCap)) div 2, ChipCap);

  { --- card outline — drawn last, on top of the content --- }
  PaintCardRoundRect(Cv, Card, CHATROW_CORNER_RADIUS, [], clNone, BorderCol);
end;

{ ---------------- selection and menu ---------------- }

function TFrameChats.CurrentRow: TChatRow;
begin
  Result := ChatAt(Grid.Row);
end;

procedure TFrameChats.GridSelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
var
  R: TChatRow;
begin
  CanSelect := True;
  { A programmatic re-sync of Grid.Row to the actually-open chat after
    a list reorder (see ModelChanged/FActiveChatId) — checked FIRST,
    ahead of FSuppressSelect/FSwitchingMode: the move must succeed
    (CanSelect stays True) and must not be treated as a new user
    selection (FOnSelect not called), regardless of whatever state
    those other two flags are still in from an unrelated earlier
    click — this isn't a user gesture, it owns its own start/end (see
    FResyncingSelection's own comment), it doesn't defer to them. }
  if FResyncingSelection then begin
    Exit;
  end;
  { The click landed on an icon/avatar — selection doesn't move at all,
    the chat isn't opened. The flag is NOT reset here — see its own
    declaration for why a self-resetting, one-shot version didn't work
    (Grid.RowCount:=... in ModelChanged can, independently of
    Grid.Row:=0, synchronously re-fire this same event again via
    CheckPosition in LCL — there's no way to know in advance how many
    times). }
  if FSuppressSelect then begin
    CanSelect := False;
    Exit;
  end;
  if (not FReady) or (FModel = nil) then begin
    Exit;
  end;
  if ARow < ARCHIVE_ROWS then begin
    { The header is handled in GridMouseDown — reaching here only
      happens on keyboard selection. }
    Exit;
  end;
  if FSwitchingMode then begin
    { A list-mode switch is in progress (GridMouseDown/chaHeader) —
      CanSelect stays True (see above) — the new list's own header
      ("Archive"/"All chats") should become selected, not the old row
      from the previous list — but the chat is not opened. }
    Exit;
  end;
  R := ChatAt(ARow);
  { A genuine user selection — remembered by id, not by index, so
    ModelChanged can find it again after the list reorders. }
  if R <> nil then begin
    FActiveChatId := R.Id;
  end;
  if Assigned(FOnSelect) then begin
    FOnSelect(Self, R);
  end;
end;

function TFrameChats.HitArea(X, Y: Integer; out ARow: TChatRow): TChatHitArea;
var
  C, Row: Integer;
  Cell:   TRect;
  Card, Header, Content, IconR, AvatarR, MuteR, PinR, ArchiveR: TRect;
  P: TPoint;
begin
  Result := chaNone;
  ARow   := nil;
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Exit;
  end;

  Grid.MouseToCell(X, Y, C, Row);
  if (Row >= 0) and (Row < ARCHIVE_ROWS) then begin
    { The header is clicked as a whole, not by individual zones. }
    Result := chaHeader;
    Exit;
  end;
  ARow := ChatAt(Row);
  if ARow = nil then begin
    Exit;
  end;

  { Coordinates within a row are local, so the card geometry is
    computed for (0,0,Width,Height) of the same cell, using the same
    ChatRowRects as drawing (only there ARect is the real, absolute
    one). }
  Cell := Grid.CellRect(C, Row);
  P    := Point(X - Cell.Left, Y - Cell.Top);
  Card := ChatRowRects(Rect(0, 0, Cell.Right - Cell.Left, Cell.Bottom - Cell.Top),
    FMode <> clmArchive, not FModel.IsSelfChat(ARow), not FModel.IsSelfChat(ARow),
    Header, Content, IconR, AvatarR, MuteR, PinR, ArchiveR);

  if PtInRect(MuteR, P) then begin
    Result := chaBell;
    Exit;
  end;
  if PtInRect(PinR, P) then begin
    Result := chaPin;
    Exit;
  end;
  if PtInRect(ArchiveR, P) then begin
    Result := chaArchive;
    Exit;
  end;
  if PtInRect(AvatarR, P) then begin
    Result := chaAvatar;
    Exit;
  end;
  { The chip's width depends on its caption, so it is measured the same
    way it is drawn (FolderChipRect) rather than guessed at — including
    the same right-hand limit, which is the unread badge's left edge
    when there is one: the two share this line. }
  if PtInRect(FolderChipRect(AvatarR, FolderChipLimit(ARow, Content),
       FolderChipCaption(ARow)), P) then begin
    Result := chaFolder;
    Exit;
  end;
end;

procedure TFrameChats.GridMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  R:    TChatRow;
  Area: TChatHitArea;
  Want: TCursor;
  Tip:  String;
begin
  if (not FReady) or (Grid = nil) then begin
    Exit;
  end;
  Area := HitArea(X, Y, R);
  if Area = chaNone then begin
    Want := crDefault;
  end
  else begin
    Want := crHandPoint;
  end;
  { Assigned only on change: OnMouseMove fires often, and setting the
    cursor pokes the widget set. }
  if Grid.Cursor <> Want then begin
    Grid.Cursor := Want;
  end;

  { Tooltips for the three icon buttons. Each one says what the CLICK
    WILL DO, not what the current state is — that is what the icon
    itself already shows. A grid is one control with one Hint, so the
    text is swapped as the pointer moves; Application.CancelHint is
    needed because a hint already on screen keeps its old text
    otherwise. }
  Tip := '';
  if R <> nil then begin
    case Area of
      chaBell:
        if R.IsMuted then begin
          Tip := 'Unmute';
        end
        else begin
          Tip := 'Mute';
        end;
      chaPin:
        if R.IsPinned then begin
          Tip := 'Unpin';
        end
        else begin
          Tip := 'Pin';
        end;
      chaArchive:
        if FMode = clmArchive then begin
          Tip := 'Move to main list';
        end
        else begin
          Tip := 'Archive';
        end;
    end;
  end;
  if Grid.Hint <> Tip then begin
    Grid.Hint := Tip;
    Grid.ShowHint := Tip <> '';
    Application.CancelHint;
  end;
end;

procedure TFrameChats.GridMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  R: TChatRow;
begin
  FSuppressSelect := False;
  FSwitchingMode := False;
  if Button <> mbLeft then begin
    Exit;
  end;

  { It matters that LCL calls inherited MouseDown as the FIRST line:
    our handler runs before selection actually changes. }
  case HitArea(X, Y, R) of
    chaHeader: begin
      { FSwitchingMode (unlike FSuppressSelect for chaBell/chaPin/
        chaAvatar below) does NOT block selection from moving — it
        MUST move to the new list's header, see FSwitchingMode/
        GridSelectCell. It stays True until the start of the NEXT real
        MouseDown, not consumed once per call — both Grid.Row:=0 and
        Grid.RowCount:=... inside SetMode/ModelChanged CAN,
        independently of each other, synchronously re-fire
        GridSelectCell again (CheckPosition in LCL re-checks the
        current cell on each such assignment) — there's no way to know
        in advance how many times. }
      FSwitchingMode := True;
      if FMode = clmArchive then begin
        SetMode(clmMain);
      end
      else begin
        SetMode(clmArchive);
      end;
    end;
    chaBell: begin
      FSuppressSelect := True;
      FModel.SetMuted(R, not R.IsMuted);
    end;
    chaPin: begin
      FSuppressSelect := True;
      FModel.SetPinned(R, not R.IsPinned);
    end;
    chaArchive: begin
      { Which way it goes follows the list being shown, not a flag on
        the row: the archive list can only un-archive, the main list can
        only archive. The row leaves the list on its own once TDLib
        reports the new position — nothing to update here. }
      FSuppressSelect := True;
      FModel.SetArchived(R, FMode <> clmArchive);
    end;
    chaAvatar: begin
      FSuppressSelect := True;
      if Assigned(FOnAvatar) then begin
        FOnAvatar(Self, R);
      end;
    end;
    chaFolder: begin
      { Same as the icons above: the chip is a button, clicking it
        doesn't open the chat. }
      FSuppressSelect := True;
      ShowFolderMenu(R, Grid.ClientToScreen(Point(X, Y)));
    end;
  end;
end;

procedure TFrameChats.GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
var
  C, R: Integer;
begin
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Handled := True;
    Exit;
  end;
  Grid.MouseToCell(MousePos.X, MousePos.Y, C, R);
  { The archive doesn't have its own menu yet. }
  if (R < ARCHIVE_ROWS) or (R >= RowsCount + ARCHIVE_ROWS) then begin
    Handled := True;
    Exit;
  end;
  Grid.Row := R;
  FMenuRow := ChatAt(R);
  BuildMenu(FMenuRow);
end;

procedure TFrameChats.BuildMenu(ARow: TChatRow);

  procedure Add(const ACaption: String; ATag: Integer);
  var
    MI: TMenuItem;
  begin
    MI     := TMenuItem.Create(mnuChat);
    MI.Caption := ACaption;
    MI.Tag := ATag;
    MI.OnClick := @MenuItemClick;
    mnuChat.Items.Add(MI);
  end;

begin
  { The menu is rebuilt from scratch for the specific chat: the set of
    items depends on its type and state. }
  mnuChat.Items.Clear;
  if ARow = nil then begin
    Exit;
  end;

  Add(String(ARow.Title), MI_NONE);
  mnuChat.Items[0].Enabled := False;
  Add('-', MI_NONE);

  if (ARow.UnreadCount > 0) or ARow.IsMarkedAsUnread then begin
    Add('Mark as read', MI_READ);
  end
  else begin
    Add('Mark as unread', MI_UNREAD);
  end;

  { Pinning isn't allowed in the archive — the same restriction as on
    the row's pin icon (GridDrawCell/ChatRowRects), just on the context
    menu's side: leaving the menu item in would be inconsistent with
    the icon already being removed. }
  if FMode <> clmArchive then begin
    if ARow.IsPinned then begin
      Add('Unpin', MI_UNPIN);
    end
    else begin
      Add('Pin', MI_PIN);
    end;
  end;

  if ARow.InArchive then begin
    Add('Move to main list', MI_UNARCHIVE);
  end
  else begin
    Add('Archive', MI_ARCHIVE);
  end;

  Add('-', MI_NONE);
  Add('Copy id (' + IntToStr(ARow.Id) + ')', MI_COPY_ID);

  if ARow.Kind in [ckSupergroup, ckChannel, ckBasicGroup] then begin
    Add('-', MI_NONE);
    Add('Leave', MI_LEAVE);
  end;
end;

procedure TFrameChats.MenuItemClick(Sender: TObject);
var
  R: TChatRow;
begin
  { The row is captured locally: while a confirmation dialog is up, the
    model could have rebuilt and FMenuRow might no longer point to it. }
  R := FMenuRow;
  if (R = nil) or (FModel = nil) then begin
    Exit;
  end;

  case TMenuItem(Sender).Tag of
    MI_READ:
      FModel.MarkAsRead(R);
    MI_UNREAD:
      FModel.MarkAsUnread(R);
    MI_PIN:
      FModel.SetPinned(R, True);
    MI_UNPIN:
      FModel.SetPinned(R, False);
    MI_ARCHIVE:
      FModel.SetArchived(R, True);
    MI_UNARCHIVE:
      FModel.SetArchived(R, False);
    MI_COPY_ID:
      Clipboard.AsText := IntToStr(R.Id);
    MI_LEAVE: begin
      if MessageDlg('Leave chat',
        Format('Leave "%s"?', [String(R.Title)]),
        mtConfirmation, [mbYes, mbNo], 0) = mrYes then begin
        FModel.LeaveChat(R);
      end;
    end;
  end;
end;

{ ---------------- folder chip ---------------- }

{ Characters, not bytes: chatFolderName's 1-12 limit is counted in
  characters by the server, and a Cyrillic folder name is two bytes per
  character. Counting continuation bytes out (10xxxxxx) is all that
  takes, and it saves pulling LazUTF8 in for one call — nothing else in
  this project uses it. }
function Utf8Chars(const S: String): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Length(S) do begin
    if (Byte(S[I]) and $C0) <> $80 then begin
      Inc(Result);
    end;
  end;
end;

function TFrameChats.UnreadBadgeRect(ARow: TChatRow; const AContent: TRect): TRect;
var
  S: String;
  B: TBGRABitmap;
begin
  { The anchor corner itself, zero-sized — see the declaration. }
  Result := Rect(AContent.Right - MSG_PAD_V, AContent.Bottom - MSG_PAD_V,
    AContent.Right - MSG_PAD_V, AContent.Bottom - MSG_PAD_V);
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.UnreadCount <= 0) and (not ARow.IsMarkedAsUnread) then begin
    Exit;
  end;
  if ARow.UnreadCount > 0 then begin
    S := IntToStr(ARow.UnreadCount);
  end
  else begin
    { Marked as unread by hand — a dot, no number. }
    S := '';
  end;
  B := BadgeBitmap(S, False);
  if B = nil then begin
    Exit;
  end;
  Result.Left := Result.Right - B.Width;
  Result.Top := Result.Bottom - B.Height;
end;

function TFrameChats.FolderChipLimit(ARow: TChatRow; const AContent: TRect): Integer;
begin
  { Min() covers both cases in one line: with no badge the "empty"
    rect's Left is the corner anchor itself, which is further right
    than the text padding edge, so the padding edge wins. }
  Result := Min(AContent.Right - MSG_PAD_H,
    UnreadBadgeRect(ARow, AContent).Left - GAP);
end;

function TFrameChats.FolderChipCaption(ARow: TChatRow): String;
var
  Id: Integer;
begin
  Result := CHATROW_FOLDER_NONE;
  if (ARow = nil) or (FModel = nil) then begin
    Exit;
  end;
  Id := FModel.RowFolderId(ARow);
  if Id = 0 then begin
    Exit;
  end;
  Result := String(FModel.FolderTitle(Id));
  if Result = '' then begin
    { The chat is in a folder the model has an id for but no name —
      updateChatFolders hasn't arrived (or has just replaced the list).
      "no folder" is the honest thing to show; it corrects itself on
      the next repaint. }
    Result := CHATROW_FOLDER_NONE;
  end;
end;

function TFrameChats.FolderChipRect(const AAvatarR: TRect; ARight: Integer;
  const ACaption: String): TRect;
var
  Cv: TCanvas;
  W, SaveH: Integer;
  SaveStyle: TFontStyles;
begin
  Cv := Grid.Canvas;
  SaveH := Cv.Font.Height;
  SaveStyle := Cv.Font.Style;
  Cv.Font.Height := CHATROW_FOLDER_FONT_H;
  Cv.Font.Style := [];
  W := Cv.TextWidth(ACaption) + 2 * CHATROW_FOLDER_PAD_H;
  Cv.Font.Height := SaveH;
  Cv.Font.Style := SaveStyle;

  { Left-aligned with the preview line above it (both start after the
    avatar), and anchored to the avatar's BOTTOM edge — see
    CHATROW_LINE_INSET. }
  Result := Rect(AAvatarR.Right + MSG_ICON_GAP,
    AAvatarR.Bottom - CHATROW_LINE_INSET - CHATROW_FOLDER_H,
    AAvatarR.Right + MSG_ICON_GAP + W,
    AAvatarR.Bottom - CHATROW_LINE_INSET);
  if Result.Right > ARight then begin
    Result.Right := ARight;
  end;
end;

procedure TFrameChats.ShowFolderMenu(ARow: TChatRow; const AScreenPos: TPoint);
var
  I, Cur: Integer;
  F: TChatFolder;
  MI: TMenuItem;

  { ARadio marks the folder entries only: they are one choice out of a
    set and the current one carries the dot. The separator and the two
    actions below it are neither, and making them radio items too would
    indent them into the same column for no reason.
    AIcon = -1 means no image — which is every folder entry, see
    ShowFolderMenu's own comment below. }
  procedure AddItem(const ACaption: String; ATag: Integer; ARadio, AChecked: Boolean;
    AIcon: Integer = -1; AEnabled: Boolean = True);
  begin
    MI := TMenuItem.Create(FFolderMenu);
    MI.Caption := ACaption;
    MI.Tag := ATag;
    MI.RadioItem := ARadio;
    MI.Checked := AChecked;
    MI.ImageIndex := AIcon;
    MI.Enabled := AEnabled;
    MI.OnClick := @FolderMenuClick;
    FFolderMenu.Items.Add(MI);
  end;

begin
  if (ARow = nil) or (FModel = nil) then begin
    Exit;
  end;
  FFolderRow := ARow;
  { The two actions at the bottom carry icons, so the menu needs an
    image list. The FOLDERS themselves carry none, and can't: TDLib
    describes a folder's icon by NAME only — chatFolderIcon is a string
    out of a fixed set ("Work", "Airplane", "Custom"...), never a
    picture, so showing them would mean shipping one icon per name.
    Checked against td_api.tl and against this project's own
    tdlib_raw.log, where all six real folders arrive as exactly that. }
  FFolderMenu.Images := ImageList1;
  FFolderMenu.Items.Clear;
  Cur := FModel.RowFolderId(ARow);
  for I := 0 to FModel.FolderCount - 1 do begin
    F := FModel.Folders[I];
    { Tag = folder id, which TDLib never assigns as 0 or negative —
      that leaves both FOLDER_MENU_* values free, no separate flag. }
    AddItem(String(F.Title), F.Id, True, F.Id = Cur);
  end;
  if FModel.FolderCount > 0 then begin
    AddItem('-', FOLDER_MENU_NEW, False, False);
  end;
  { Disabled rather than dropped when the chat is in no folder: the
    menu keeps the same shape wherever it opens, so the item the user
    is reaching for doesn't move from row to row. }
  AddItem('Remove from folder', FOLDER_MENU_REMOVE, False, False,
    FOLDER_MENU_ICON_REMOVE, Cur <> 0);
  AddItem('New folder', FOLDER_MENU_NEW, False, False, FOLDER_MENU_ICON_NEW);
  FFolderMenu.PopUp(AScreenPos.X, AScreenPos.Y);
end;

procedure TFrameChats.FolderMenuClick(Sender: TObject);
var
  R: TChatRow;
  Id: Integer;
  { Not "Name": that one is TComponent's own published property, and a
    local of the same name inside a method of a component shadows it
    into a compile error (5002), not just a warning. }
  FolderName: String;
begin
  { Captured locally, exactly as MenuItemClick does it: the model can
    rebuild while the menu (or the dialog below) is up. }
  R := FFolderRow;
  if (R = nil) or (FModel = nil) then begin
    Exit;
  end;
  Id := TMenuItem(Sender).Tag;
  if Id = FOLDER_MENU_REMOVE then begin
    FModel.RemoveChatFromFolders(R);
    Exit;
  end;
  if Id <> FOLDER_MENU_NEW then begin
    { A real folder. Picking the one the chat is already in would
      otherwise send a pointless addChatToList. }
    if Id <> FModel.RowFolderId(R) then begin
      FModel.MoveChatToFolder(R, Id);
    end;
    Exit;
  end;

  FolderName := '';
  if not InputQuery('New folder',
    Format('Folder name (up to %d characters):', [CHATROW_FOLDER_NAME_MAX]),
    FolderName) then begin
    Exit;
  end;
  FolderName := Trim(FolderName);
  if FolderName = '' then begin
    Exit;
  end;
  { Checked here rather than left to the server: createChatFolder would
    refuse the whole request, and the reply would surface as a bare
    error code in the status bar with nothing pointing at the name. }
  if Utf8Chars(FolderName) > CHATROW_FOLDER_NAME_MAX then begin
    MessageDlg('New folder',
      Format('A folder name can be at most %d characters long.',
        [CHATROW_FOLDER_NAME_MAX]), mtError, [mbOK], 0);
    Exit;
  end;
  FModel.CreateFolderWithChat(Utf8string(FolderName), R);
end;

end.
