unit chatheader;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Math, Forms, Controls, Graphics, StdCtrls, ExtCtrls,
  Buttons, ImgList, Clipbrd, cardpaint, constants, tdchats, tdcore, tdaccentcolors,
  avatarcache, BGRABitmap, BGRABitmapTypes;

type
  { Raised when the user picks/clears a filter button or runs a text
    search. AFilterType is a TDLib SearchMessagesFilter constructor
    name (TD_MSG_FILTER_*, constants.pas) or '' for "no type
    restriction"; AQuery is the search box's text. BOTH empty means
    "back to the ordinary history".

    An event rather than a direct call into framehistory for the usual
    reason: that unit already uses this one, so a call the other way
    would be a unit cycle. }
  TChatHeaderFilterEvent = procedure(Sender: TObject;
    const AFilterType, AQuery: utf8string) of object;

  { TChatHeaderPanel

    The chat info bar above the message history — visually the SAME card
    as one row of the chat list (framechats), by direct request: same
    outer gap, corner radius, header strip on top, content area below,
    and the same inner paddings (MSG_PAD_H/MSG_PAD_V/GAP). None of
    those numbers are duplicated here — this unit reads the chat list's
    own constants, so the two can't drift apart.

    Everything in the header strip (chat-type icon, premium badge,
    title, numeric id, pin, mute) plus the avatar is PAINTED,
    not built from child controls, exactly as the chat list paints its
    own rows: an earlier pass made each of these a TSpeedButton/TLabel
    and it neither looked nor behaved like the reference (buttons where
    the reference has a bare glyph, native button chrome where it has a
    flat framed box, and three separate ELayoutException crashes from
    LCL's AutoSize fighting explicitly-set bounds). Clicks on the
    painted parts are hit-tested in MouseDown against rects computed
    during Paint, the same approach framechats.HitArea uses.

    Real child controls remain only where one is genuinely needed: the
    magnifier (it wants hover feedback) and the search TEdit (text
    input). The filter toggles were twelve 32x32 TSpeedButtons until
    they were asked to become painted 12x12 glyphs: no button frame, no
    hover highlight, drawn exactly the way the chat list draws the pin
    and bell on one of its own rows. Their clickable rects join the
    hit-test list above.

    The right-hand side of the content area is three stacked rows,
    centred on the avatar and all ending at the same right edge as the
    header strip above them: the eleven filter toggles on top, spread
    evenly across the search box's width, the search box itself in the
    middle, and the similar-channels and info-panel buttons underneath.

    Nine of the eleven toggles plus the search box drive ONE request —
    searchChatMessages with a different SearchMessagesFilter (see
    TD_MSG_FILTER_* and TTdMessages.SetSearchFilter) — and are wired up
    through OnFilterChanged. At most ONE is on at a time (FActiveFilter,
    and turning on a second turns off the first): that is not a UI
    preference but the API's shape — searchChatMessages takes exactly
    one filter, so several at once would mean running several searches
    and merging them by hand, which was explicitly not wanted. Clicking
    the active one again turns it off and, with an empty search box,
    returns to the ordinary history. Filter and query COMBINE rather
    than replace each other, exactly as the TDLib request itself takes
    both.

    The other two — gifts and saved — are still stubs, and not because
    they were forgotten: TDLib answers those with receivedGifts and a
    savedMessagesTopic history, neither of which are messages, so
    neither can go through the message list the other nine reuse.
    FilterTypeFor returning '' is what marks a toggle as a stub, and it
    is the one place that decides; such a toggle can never be the
    active one. Similar-channels is the same kind of stub (a list of
    chat ids) but is not part of this row at all any more — it sits in
    the bottom row, shown only for channels.

    The info-panel button next to it is a stub of a different kind: the
    details side panel does not exist yet, so this bar holds the
    open/closed state itself (SetInfoPanelOpen is the hook the real
    panel will call once there is one) and the arrow only says what a
    click will do — right to open, left to close.

    The bar hides itself by collapsing to Height=0 (Refresh(0), or no
    chat found for the id) rather than toggling Visible — the same
    "collapse to zero, don't hide" rule the chat list already applies
    to individual row icons, and it keeps this control out of the
    Align-ordering machinery that misplaced an earlier version of this
    bar entirely.

    A real TFrame with a paired chatheader.lfm, same as msginput.pas —
    so the magnifier and the search edit are ordinary published fields
    streamed from the .lfm and can be edited in the Lazarus Designer
    (that is what the .lfm is FOR here: their Hints are meant to be set
    visually, not in code). TFrame
    still descends from TCustomControl (TCustomFrame ->
    TCustomDesignControl -> TScrollingWinControl -> TCustomControl,
    checked in the LCL source, not assumed), so Canvas/Paint below work
    exactly as they did before the conversion.

    Two .lfm properties this bar's looks depend on, in case they ever
    get flipped in the Designer by accident: ParentColor=True (Paint
    fills everything outside the card with Color, which must be the
    frame around it — white here draws a white band around the card)
    and ParentBackground=False.

    The two child controls' positions in the .lfm are design-time only:
    DoLayout re-places them from the card's geometry on every resize,
    and computes the painted icons' rects in the same pass. }
  TChatHeaderPanel = class(TFrame)
    { Streamed from chatheader.lfm — the only two child controls left,
      the magnifier and the search box. The filter toggles used to live
      here too and are painted now, see the class comment. }
    btnSearch:  TSpeedButton;
    edtSearch:  TEdit;
    procedure SearchGo(Sender: TObject);
    procedure SearchKeyPress(Sender: TObject; var Key: char);
  private
    FChatId:       Int64;
    FTypeIcons:    TCustomImageList;
    FPremiumIcons: TCustomImageList;
    FDeletedIcons: TCustomImageList;
    FFilterIcons:  TCustomImageList;
    FAvatarPath:   utf8string;
    FAvatarBmp:    TBGRABitmap;
    FCardBg:       TColor;

    { Everything Paint needs about the current chat, read once per
      Refresh — Paint itself never touches the model. }
    FTitle:       string;
    FDeleted:     boolean;
    FIdText:      string;
    FTypeIconIdx: integer;
    FPremium:     boolean;
    FPinned:      boolean;
    FMuted:       boolean;
    FHasMute:     boolean;

    { Clickable areas of the PAINTED parts, computed by Paint (it's the
      only place the text widths are known) and read by MouseDown/
      MouseMove — the same "paint computes it, hit test reuses it"
      split framechats uses, just without a separate Rects function
      since there's exactly one row here, not a grid of them. }
    FPinRect:        TRect;
    FMuteRect:       TRect;
    FIdRect:         TRect;
    FAvatarRect:     TRect;
    { The search field's frame — edtSearch sits inset inside it and the
      magnifier inside its right end, so it's neither control's own
      bounds and has to be remembered for Paint. }
    FSearchSlotRect: TRect;

    { The filter toggles' own clickable rects, indexed by
      CHAT_HEADER_FILTER_*, plus the two buttons of the bottom row.
      Unlike the header strip's rects these depend on no text width, so
      DoLayout computes them (Paint and MouseDown both just read them)
      — the same place the two real child controls are positioned, so
      the three rows can't drift apart. FSimilarRect collapses to zero
      width outside a channel rather than carrying a "visible" flag,
      the same rule the header strip's own icons follow. }
    FFilterRects:  array[0..CHAT_HEADER_FILTER_COUNT - 1] of TRect;
    FSimilarRect:  TRect;
    FPanelRect:    TRect;

    { Which toggle is on, or -1 for none — see the class comment for
      why one and not a set. }
    FActiveFilter:   integer;
    { Channels only, per direct request — every other chat kind gets a
      collapsed FSimilarRect instead. }
    FSimilarVisible: boolean;
    { The details side panel's state. Owned here only until that panel
      exists — see SetInfoPanelOpen. }
    FInfoPanelOpen:     boolean;
    FOnToggleInfoPanel: TNotifyEvent;
    FOnFilterChanged:   TChatHeaderFilterEvent;

    { The TDLib SearchMessagesFilter name for one CHAT_HEADER_FILTER_*
      index, or '' for the two toggles that aren't a message filter at
      all (gifts/saved — see the class comment). }
    function FilterTypeFor(AIndex: integer): utf8string;
    { The FilterButtons12 frame for one toggle: its index doubled, plus
      one when it is the active one (grey pair member first, black
      second — see CHAT_HEADER_FILTER_ICON_*). The only place that
      arithmetic is written down. }
    function FilterIconIndex(AIndex: integer): integer;
    { Which toggle/button a point falls on, or -1 — one function so
      MouseDown and MouseMove can't disagree about what is clickable. }
    function FilterAt(const APoint: TPoint): integer;
    { The tooltip for whatever FilterAt just returned, '' for nothing.
      These used to be Designer-set Hints on twelve real buttons; with
      the buttons painted there is one control and so one Hint, swapped
      as the mouse moves — the same thing TFrameChats does for the
      icons on its own rows. }
    function FilterHint(AHit: integer): string;
    { Gathers the current filter+query from the controls and raises
      OnFilterChanged. One place, so a click on a filter button and a
      run of the search box can't end up asking for different things. }
    procedure ApplyFilter;

    { The card's own rectangle inside this control — the single source
      of truth for both Paint and DoLayout, so the two can't drift
      apart; the same CHATROW_GAP inset the chat list applies to its
      own rows (half above and below, the whole of it left and right). }
    function CardRect: TRect;
    function ChatHeaderTypeIcon(ARow: TChatRow): integer;
    { This bar's accent color — the SAME contact color the chat list row
      and this contact's message blocks already use (accent_color_id via
      TdAccentColorList, SENDER_PALETTE hash as fallback). An
      independent copy of framehistory.ResolveAccentColor/framechats.
      ChatAccentColor: this unit can't import framehistory (that one
      imports this one — a cycle) and framechats' copy is private. }
    function HeaderAccentColor: TColor;
    { Same ColorToRGB-safe blend as framehistory.BlendWithBackground —
      another independent copy, same reason. }
    function BlendColor(AFg, ABg: TColor; AOpacity: double): TColor;
    { Thin wrapper over cardpaint.PaintRounded — this bar is part of
      the frame AROUND the message history, so it answers "antialiased
      or not" with SMOOTH_CHROME_CORNERS (on), not the history's own
      SMOOTH_CORNERS (off). Used to be a line-for-line copy of
      framechats.PaintCardRoundRect, which was itself a copy of
      framehistory's; all three now share one implementation. }
    procedure PaintCard(const ABox: TRect; ARadius: integer;
      AOptions: TRoundRectangleOptions; AFillColor, ABorderColor: TColor);
    procedure DoLayout;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { ATypeIcons — icons12 (CHATROW_ICON_* indices: the type/pin/mute
      icons, the same list and indices the chat list itself draws).
      APremiumIcons — ImageList1 (PREMIUM_CROWN_ICON). AFilterIcons —
      FilterButtons12, the 12x12 list: the toggles' grey/black pairs
      plus the similar-channels and info-panel glyphs, see
      FilterIconIndex and CHAT_HEADER_ICON12_*. ASearchIcons/
      ASearchIconIndex — the magnifier (Actions16, index 2 as the
      project stands) — passed in rather than hard-coded, this unit has
      no access to TFrameHistory's own LFM components. ADeletedIcons —
      ImageListBig (DELETED_ACCOUNT_ICON), for the same reason. }
    procedure SetImageLists(ATypeIcons, APremiumIcons, AFilterIcons, ASearchIcons,
      ADeletedIcons: TCustomImageList; ASearchIconIndex: integer);
    { AChatId=0, or no such chat in TdChatList, collapses the bar to
      Height=0 — see the class comment for why Height, not Visible.
      Switching to a DIFFERENT chat also clears the filter buttons and
      the search box, matching TTdMessages.Clear, which drops the
      filter on every chat switch. }
    procedure Refresh(AChatId: Int64);
    { Turns off the active toggle and empties the search box WITHOUT
      raising OnFilterChanged — for putting the bar back in step with a
      model whose filter was dropped elsewhere, not for changing it. }
    procedure ClearFilterUI;
    { The hook for the details side panel that does not exist yet: it
      calls this with its real state, the bar flips the arrow. Until
      there is one, the bar toggles this itself on every click (see
      MouseDown) so the button still visibly does something — which is
      the whole of what the stub was asked to do. }
    procedure SetInfoPanelOpen(AOpen: boolean);
    property InfoPanelOpen: boolean read FInfoPanelOpen;
    { Raised on every click of the info-panel button, after the state
      above has already flipped. Nothing listens yet. }
    property OnToggleInfoPanel: TNotifyEvent
      read FOnToggleInfoPanel write FOnToggleInfoPanel;
    property OnFilterChanged: TChatHeaderFilterEvent
      read FOnFilterChanged write FOnFilterChanged;
  end;

implementation

{$R *.lfm}

const
  { What FilterAt returns for the two buttons of the bottom row, which
    are not filter toggles and so have no CHAT_HEADER_FILTER_* index of
    their own. Negative so they can share one function's result with
    the toggles' indices, and -1 stays free for "nothing here". }
  CHAT_HEADER_HIT_SIMILAR = -2;
  CHAT_HEADER_HIT_PANEL   = -3;

function TChatHeaderPanel.CardRect: TRect;
begin
  { One constant per side (see their own comment) — left is flush with
    the control's edge, so the card lines up with the message history
    area underneath rather than being indented from it. The chat list's
    own rows are inset on all four sides instead
    (framechats.ChatRowRects); this bar is not a row in a list, it's
    the top edge of the history pane. }
  Result := Rect(0, CHAT_HEADER_CARD_MARGIN_TOP,
    Width - CHAT_HEADER_CARD_MARGIN_RIGHT, Height - CHAT_HEADER_CARD_MARGIN_BOTTOM);
end;

{ Same 4-way case as TFrameChats.TypeIconIndex (private there, so this
  is an independent copy — the same arrangement this file already has
  for the accent color and the blend). }
function TChatHeaderPanel.ChatHeaderTypeIcon(ARow: TChatRow): integer;
begin
  Result := -1;
  if (ARow = nil) or (TdChatList = nil) then begin
    Exit;
  end;
  case ARow.Kind of
    ckChannel:
      Result := CHATROW_ICON_CHANNEL;
    ckBasicGroup, ckSupergroup:
      Result := CHATROW_ICON_GROUP;
    ckPrivate, ckSecret: begin
      if TdChatList.IsBotChat(ARow) then begin
        Result := CHATROW_ICON_BOT;
      end else begin
        Result := CHATROW_ICON_PRIVATE;
      end;
    end;
  end;
end;

function TChatHeaderPanel.HeaderAccentColor: TColor;
var
  Row: TChatRow;
  AC: TTdAccentColors;
  Id: Int64;
begin
  Result := SENDER_PALETTE[0];
  if (TdChatList = nil) or (FChatId = 0) then begin
    Exit;
  end;
  Row := TdChatList.Lookup(FChatId);
  if Row = nil then begin
    Exit;
  end;
  if Row.AccentColorId >= 0 then begin
    AC := TdAccentColorList;
    if (AC <> nil) and AC.TryGetColor(Row.AccentColorId, Result) then begin
      Exit;
    end;
  end;
  Id := Row.Id;
  if Id = 0 then begin
    Id := 1;
  end;
  Result := SENDER_PALETTE[Abs(Id) mod Length(SENDER_PALETTE)];
end;

function TChatHeaderPanel.BlendColor(AFg, ABg: TColor; AOpacity: double): TColor;
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

procedure TChatHeaderPanel.PaintCard(const ABox: TRect; ARadius: integer;
  AOptions: TRoundRectangleOptions; AFillColor, ABorderColor: TColor);
begin
  PaintRounded(Canvas, ABox, ARadius, AOptions, AFillColor, ABorderColor,
    SMOOTH_CHROME_CORNERS);
end;

constructor TChatHeaderPanel.Create(AOwner: TComponent);
begin
  { Streams chatheader.lfm — both child controls below already exist
    (and already carry their Designer-set Hint) once this returns. }
  inherited Create(AOwner);
  FTypeIconIdx := -1;
  FActiveFilter := -1;
  Height := 0;   { no chat open yet — see the class comment }
end;

destructor TChatHeaderPanel.Destroy;
begin
  FAvatarBmp.Free;
  inherited Destroy;
end;

procedure TChatHeaderPanel.SetImageLists(ATypeIcons, APremiumIcons, AFilterIcons, ASearchIcons,
  ADeletedIcons: TCustomImageList; ASearchIconIndex: integer);
begin
  FTypeIcons := ATypeIcons;
  FPremiumIcons := APremiumIcons;
  FDeletedIcons := ADeletedIcons;
  FFilterIcons := AFilterIcons;
  btnSearch.Images := ASearchIcons;
  btnSearch.ImageIndex := ASearchIconIndex;
end;

{ Places the two REAL child controls (the magnifier and the search
  edit) and computes the rects of everything painted in the content
  area — the avatar and the three right-hand rows. Geometry copied from
  framechats.ChatRowRects: header strip of CHATROW_HEADER_BAR_H on top,
  content area below, MSG_PAD_H in from the card's edges, MSG_PAD_V
  down from the content area's top. Only the HEADER strip's own rects
  are left to Paint, because those depend on text widths it is the only
  place to know. }
procedure TChatHeaderPanel.DoLayout;
const
  { Fixed, never read back from edtSearch itself — an earlier version
    derived the frame's size from edtSearch.Width/.Height and then
    shrank edtSearch to fit inside it, so every later pass read back
    the already-shrunk size and shrank it again, all the way to
    Width=0 (a real ELayoutException, not a hypothetical). }
  SearchW     = 200;
  SearchH     = 24;
  SearchInset = 3;
  MagnifierW  = 22;
var
  Card, Content: TRect;
  X, RightX, RowsTop, BlockH, BlockTop, Span, I, SearchY, EditL, EditR: integer;
begin
  if (Width <= 0) or (Height <= 0) then begin
    Exit;
  end;
  { Streaming chatheader.lfm assigns this frame's OWN properties
    (Height among them) before it has created a single child control,
    and every one of those assignments fires Resize -> here with
    btnSearch/edtSearch still nil — a real access violation on
    the first chat opened (TFrameNavigator builds TFrameHistory, and
    with it this bar, lazily), not a hypothetical. There is nothing to
    place until loading has finished anyway; Create's own Height := 0
    and every Refresh both run after it and lay the bar out properly.
    The nil check is a second line of defence for the case where one of
    the controls is deleted in the Designer rather than merely moved. }
  if (csLoading in ComponentState) or (btnSearch = nil) or (edtSearch = nil) then begin
    Exit;
  end;

  Card := CardRect;
  Content := Rect(Card.Left, Card.Top + CHATROW_HEADER_BAR_H, Card.Right, Card.Bottom);

  FAvatarRect := Rect(Content.Left + MSG_PAD_H, Content.Top + MSG_PAD_V,
    Content.Left + MSG_PAD_H + CHAT_HEADER_AVATAR_SIZE,
    Content.Top + MSG_PAD_V + CHAT_HEADER_AVATAR_SIZE);
  { All three rows end at the same right edge, and so does the header
    strip above them (see Paint) — MSG_PAD_H, the card's own inner
    padding. The block of three is centred on the avatar rather than
    stretched to its height — with the gaps pinned at
    CHAT_HEADER_ROW_GAP_V by direct request, its height is fixed at
    12 + 6 + 24 + 6 + 12, which is 4 short of the avatar's 64. }
  RightX := Content.Right - MSG_PAD_H;
  RowsTop := FAvatarRect.Top;
  BlockH := 2 * (CHAT_HEADER_FILTER_SIZE + CHAT_HEADER_ROW_GAP_V) + SearchH;
  BlockTop := RowsTop + (CHAT_HEADER_AVATAR_SIZE - BlockH) div 2;

  { --- middle row: the search field, one framed box (Paint draws the
        frame at FSearchSlotRect) with two children inside it, the text
        edit filling its left part and the magnifier inside its right
        end --- }
  SearchY := BlockTop + CHAT_HEADER_FILTER_SIZE + CHAT_HEADER_ROW_GAP_V;
  FSearchSlotRect := Rect(RightX - SearchW, SearchY, RightX, SearchY + SearchH);
  btnSearch.SetBounds(FSearchSlotRect.Right - SearchInset - MagnifierW, SearchY + SearchInset,
    MagnifierW, SearchH - 2 * SearchInset);
  EditL := FSearchSlotRect.Left + SearchInset + MSG_ICON_GAP;
  EditR := FSearchSlotRect.Right - SearchInset - MagnifierW;
  edtSearch.SetBounds(EditL, SearchY + SearchInset, EditR - EditL, SearchH - 2 * SearchInset);

  { --- top row: the filter toggles, spread EVENLY across the search
        box's width by direct request — first flush with its left
        edge, last flush with its right. Hence no gap constant here:
        the leftovers of 200 minus eleven 12s divided by ten gaps do
        not come out whole, so the position is computed per icon (with
        rounding, +Span div 2 before the divide) rather than by adding
        a fixed step, which would let the error pile up and leave the
        last icon short of the edge. --- }
  Span := (FSearchSlotRect.Right - FSearchSlotRect.Left) - CHAT_HEADER_FILTER_SIZE;
  for I := 0 to CHAT_HEADER_FILTER_COUNT - 1 do begin
    X := FSearchSlotRect.Left
      + (Span * I + (CHAT_HEADER_FILTER_COUNT - 1) div 2) div (CHAT_HEADER_FILTER_COUNT - 1);
    FFilterRects[I] := Rect(X, BlockTop, X + CHAT_HEADER_FILTER_SIZE,
      BlockTop + CHAT_HEADER_FILTER_SIZE);
  end;

  { --- bottom row: similar channels (channels only) and the info panel
        toggle, right-aligned with the search box --- }
  X := RightX - CHAT_HEADER_FILTER_SIZE;
  FPanelRect := Rect(X, SearchY + SearchH + CHAT_HEADER_ROW_GAP_V,
    X + CHAT_HEADER_FILTER_SIZE,
    SearchY + SearchH + CHAT_HEADER_ROW_GAP_V + CHAT_HEADER_FILTER_SIZE);
  Dec(X, CHAT_HEADER_FILTER_GAP);
  if FSimilarVisible then begin
    Dec(X, CHAT_HEADER_FILTER_SIZE);
    FSimilarRect := Rect(X, FPanelRect.Top, X + CHAT_HEADER_FILTER_SIZE, FPanelRect.Bottom);
  end else begin
    FSimilarRect := Rect(X, FPanelRect.Top, X, FPanelRect.Bottom);
  end;
end;

procedure TChatHeaderPanel.Resize;
begin
  inherited Resize;
  DoLayout;
end;

{ The same three-layer card as one chat list row, in the same order:
  body fill, header strip over it (more opaque, bottom corners squared
  off), content, outline last. Everything in the strip plus the avatar
  is drawn here rather than being a child control — see the class
  comment. Along the way this records the clickable rects
  (FPinRect/FMuteRect/FIdRect) that MouseDown hit-tests against, since
  their positions depend on text widths only known here; the content
  area's rects come ready-made from DoLayout instead. }
procedure TChatHeaderPanel.Paint;
var
  Accent, HeaderFill, Border: TColor;
  Card, Header, Content: TRect;
  IconY, RightX, TitleX, TextY, I, Idx: integer;
begin
  inherited Paint;
  if (FChatId = 0) or (Height <= 0) then begin
    Exit;
  end;

  Accent := HeaderAccentColor;
  FCardBg := BlendColor(Accent, clWindow, SENDER_BG_OPACITY);
  HeaderFill := BlendColor(Accent, clWindow, SENDER_HEADER_OPACITY);
  Border := BlendColor(Accent, clWindow, SENDER_BORDER_OPACITY);

  { Color, not clWindow — this bar sits on the frame's own background
    (grey), and the card is a floating panel on top of it; filling white
    here drew a white band around the card instead. ParentColor (set in
    the constructor) keeps Color equal to the frame's. }
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Color;
  Canvas.Pen.Style := psClear;
  Canvas.FillRect(ClientRect);

  Card := CardRect;
  Header := Rect(Card.Left, Card.Top, Card.Right, Card.Top + CHATROW_HEADER_BAR_H);
  Content := Rect(Card.Left, Header.Bottom, Card.Right, Card.Bottom);

  PaintCard(Card, CHATROW_CORNER_RADIUS, [], FCardBg, clNone);
  PaintCard(Header, CHATROW_CORNER_RADIUS, [rrBottomLeftSquare, rrBottomRightSquare],
    HeaderFill, clNone);

  { --- header strip, left to right: type icon, premium, title --- }
  IconY := Header.Top + (CHATROW_HEADER_BAR_H - CHATROW_ICON_SIZE) div 2;
  TitleX := Header.Left + MSG_PAD_H;
  if (FTypeIcons <> nil) and (FTypeIconIdx >= 0) and (FTypeIconIdx < FTypeIcons.Count) then begin
    FTypeIcons.Draw(Canvas, TitleX, IconY, FTypeIconIdx, True);
    Inc(TitleX, CHATROW_ICON_SIZE + MSG_ICON_GAP);
  end;
  if FPremium and (FPremiumIcons <> nil) and (PREMIUM_CROWN_ICON < FPremiumIcons.Count) then begin
    FPremiumIcons.Draw(Canvas, TitleX,
      Header.Top + (CHATROW_HEADER_BAR_H - FPremiumIcons.Height) div 2, PREMIUM_CROWN_ICON, True);
    Inc(TitleX, FPremiumIcons.Width + MSG_ICON_GAP);
  end;

  { --- header strip, right to left: mute, pin, id. "more..." used to
        start this list and is gone: it was the details panel's button,
        and that moved down to the bottom row of the content area, next
        to similar-channels. The margin is MSG_PAD_H, the same one
        DoLayout gives the three rows below, because these were asked
        to line up with the search box — writing it as the same
        constant is what keeps them lined up. --- }
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Style := [];
  RightX := Header.Right - MSG_PAD_H;

  if FHasMute and (FTypeIcons <> nil) then begin
    Dec(RightX, CHATROW_ICON_SIZE);
    FMuteRect := Rect(RightX, IconY, RightX + CHATROW_ICON_SIZE, IconY + CHATROW_ICON_SIZE);
    if FMuted then begin
      FTypeIcons.Draw(Canvas, FMuteRect.Left, FMuteRect.Top, CHATROW_ICON_NOTIFY_OFF, True);
    end else begin
      FTypeIcons.Draw(Canvas, FMuteRect.Left, FMuteRect.Top, CHATROW_ICON_NOTIFY_ON, True);
    end;
    Dec(RightX, GAP);
  end else begin
    { Collapsed to a zero-width point at the current edge, not just
      "not drawn" — the same rule framechats.ChatRowRects follows, so
      whatever comes next butts flush against the freed slot and
      MouseDown can never hit a bell that isn't there. }
    FMuteRect := Rect(RightX, IconY, RightX, IconY + CHATROW_ICON_SIZE);
  end;

  if FTypeIcons <> nil then begin
    Dec(RightX, CHATROW_ICON_SIZE);
    FPinRect := Rect(RightX, IconY, RightX + CHATROW_ICON_SIZE, IconY + CHATROW_ICON_SIZE);
    if FPinned then begin
      FTypeIcons.Draw(Canvas, FPinRect.Left, FPinRect.Top, CHATROW_ICON_PIN, True);
    end else begin
      FTypeIcons.Draw(Canvas, FPinRect.Left, FPinRect.Top, CHATROW_ICON_UNPIN, True);
    end;
    Dec(RightX, GAP);
  end;

  Canvas.Brush.Style := bsClear;
  Canvas.Font.Style := [];
  Canvas.Font.Color := clHighlight;
  TextY := Header.Top + (CHATROW_HEADER_BAR_H - Canvas.TextHeight(FIdText)) div 2;
  Dec(RightX, Canvas.TextWidth(FIdText));
  FIdRect := Rect(RightX, Header.Top, RightX + Canvas.TextWidth(FIdText),
    Header.Top + CHATROW_HEADER_BAR_H);
  Canvas.TextOut(RightX, TextY, FIdText);
  Dec(RightX, GAP);

  { The title fills what's left, in the chat's own accent color (same
    as the chat list paints its row title), clipped so a long name
    can't run into the id. }
  if RightX > TitleX then begin
    Canvas.Font.Style := [fsBold];
    Canvas.Font.Color := Accent;
    Canvas.TextRect(Rect(TitleX, Header.Top, RightX, Header.Bottom), TitleX,
      Header.Top + (CHATROW_HEADER_BAR_H - Canvas.TextHeight(FTitle)) div 2, FTitle);
    Canvas.Font.Style := [];
  end;

  { --- content area: the avatar and the three right-hand rows of
        icons; the search box is a real child control and paints itself
        on top --- }
  if FAvatarBmp <> nil then begin
    FAvatarBmp.Draw(Canvas, FAvatarRect.Left, FAvatarRect.Top, False);
  end;
  { A deleted account has neither a photo nor initials to fall back on
    (its name is empty, which is why FTitle is substituted too), so the
    avatar is a bare colored disc — the skull goes ON it, leaving the
    chat's own color around the edges. Centered: the disc is 48 and the
    frame is 32, and centering keeps it right if either is retuned. }
  if FDeleted and (FDeletedIcons <> nil)
     and (DELETED_ACCOUNT_ICON < FDeletedIcons.Count) then begin
    FDeletedIcons.Draw(Canvas,
      FAvatarRect.Left + (CHAT_HEADER_AVATAR_SIZE - FDeletedIcons.Width) div 2,
      FAvatarRect.Top + (CHAT_HEADER_AVATAR_SIZE - FDeletedIcons.Height) div 2,
      DELETED_ACCOUNT_ICON, True);
  end;

  { The three right-hand rows. Bare glyphs, no frame and no hover
    highlight, by direct request — exactly how framechats draws the
    pin and bell on one of its rows, and the reason these stopped being
    TSpeedButtons. The zero-width check is what hides a collapsed rect
    (FSimilarRect outside a channel, and anything DoLayout ever
    collapses later) without a separate "visible" flag. }
  if FFilterIcons <> nil then begin
    for I := 0 to CHAT_HEADER_FILTER_COUNT - 1 do begin
      if FFilterRects[I].Right <= FFilterRects[I].Left then begin
        Continue;
      end;
      Idx := FilterIconIndex(I);
      if (Idx >= 0) and (Idx < FFilterIcons.Count) then begin
        FFilterIcons.Draw(Canvas, FFilterRects[I].Left, FFilterRects[I].Top, Idx, True);
      end;
    end;
    if FSimilarVisible and (CHAT_HEADER_ICON12_SIMILAR < FFilterIcons.Count) then begin
      FFilterIcons.Draw(Canvas, FSimilarRect.Left, FSimilarRect.Top,
        CHAT_HEADER_ICON12_SIMILAR, True);
    end;
    { The arrow says what a click will DO, not what the panel is: right
      while it is closed (click to open), left while it is open. }
    if FInfoPanelOpen then begin
      Idx := CHAT_HEADER_ICON12_PANEL_CLOSE;
    end else begin
      Idx := CHAT_HEADER_ICON12_PANEL_OPEN;
    end;
    if Idx < FFilterIcons.Count then begin
      FFilterIcons.Draw(Canvas, FPanelRect.Left, FPanelRect.Top, Idx, True);
    end;
  end;

  PaintCard(FSearchSlotRect, Min(CHATROW_CORNER_RADIUS,
    (FSearchSlotRect.Bottom - FSearchSlotRect.Top) div 2), [], clWindow, Border);

  { Outline last, over the content — same order as the chat row. }
  PaintCard(Card, CHATROW_CORNER_RADIUS, [], clNone, Border);
end;

procedure TChatHeaderPanel.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  P: TPoint;
  Row: TChatRow;
  Hit: integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or (FChatId = 0) or (TdChatList = nil) then begin
    Exit;
  end;
  P := Point(X, Y);

  if PtInRect(FIdRect, P) then begin
    { Same convention as the chat list's own "Copy id" menu item. }
    if FIdText <> '' then begin
      Clipboard.AsText := FIdText;
    end;
    Exit;
  end;

  { --- the content area's three rows. None of them need the chat row,
        so they are handled before it is looked up. --- }
  Hit := FilterAt(P);
  if Hit = CHAT_HEADER_HIT_PANEL then begin
    { Stub while there is no details panel: the bar is its own source of
      truth, so the arrow at least flips. Once the panel exists it will
      answer the event with SetInfoPanelOpen and take that role over. }
    SetInfoPanelOpen(not FInfoPanelOpen);
    if Assigned(FOnToggleInfoPanel) then begin
      FOnToggleInfoPanel(Self);
    end;
    Exit;
  end;
  if Hit = CHAT_HEADER_HIT_SIMILAR then begin
    { Stub, same as it was as a button — getChatSimilarChats answers
      with a list of chat ids, which is not something the message list
      can show. }
    Exit;
  end;
  if Hit >= 0 then begin
    { Gifts and saved have nothing to switch to and must not clear
      whatever filter IS active — FilterTypeFor is the one place that
      knows which those are. }
    if FilterTypeFor(Hit) <> '' then begin
      { Clicking the active one again turns it off; "off" plus an empty
        search box is how the bar asks for the plain history back. }
      if FActiveFilter = Hit then begin
        FActiveFilter := -1;
      end else begin
        FActiveFilter := Hit;
      end;
      Invalidate;
      ApplyFilter;
    end;
    Exit;
  end;

  Row := TdChatList.Lookup(FChatId);
  if Row = nil then begin
    Exit;
  end;

  if PtInRect(FPinRect, P) then begin
    { Only the request is sent here — the row's own IsPinned doesn't
      change until TDLib's update comes back, which reaches this bar
      through TFrameChats.OnRowsChanged (see framehistory), the same
      path that keeps it in step when the click happens on the chat
      list side instead. }
    TdChatList.SetPinned(Row, not Row.IsPinned);
    Exit;
  end;
  if FHasMute and PtInRect(FMuteRect, P) then begin
    TdChatList.SetMuted(Row, not Row.IsMuted);
    Exit;
  end;
end;

procedure TChatHeaderPanel.MouseMove(Shift: TShiftState; X, Y: integer);
var
  P: TPoint;
  Hit: integer;
  NewHint: string;
begin
  inherited MouseMove(Shift, X, Y);
  P := Point(X, Y);
  Hit := FilterAt(P);
  if PtInRect(FIdRect, P) or PtInRect(FPinRect, P) or (Hit <> -1)
     or (FHasMute and PtInRect(FMuteRect, P)) then begin
    Cursor := crHandPoint;
  end else begin
    Cursor := crDefault;
  end;

  { One control, one Hint, swapped as the mouse moves over the painted
    icons. CancelHint is not optional: a hint window already on screen
    does not re-read the text by itself, so without it the previous
    icon's tooltip stays up over the new one. ShowHint stays as the
    .lfm set it — an empty Hint is enough to suppress the window, and
    flipping ShowHint here would reach the two child controls too
    (their ParentShowHint is the default True) and could leave the
    search box without its own tooltip. }
  NewHint := FilterHint(Hit);
  if NewHint <> Hint then begin
    Application.CancelHint;
    Hint := NewHint;
  end;
end;

procedure TChatHeaderPanel.Refresh(AChatId: Int64);
var
  Row: TChatRow;
  ChatChanged: boolean;
begin
  if AChatId = 0 then begin
    Height := 0;
    FChatId := 0;
    Exit;
  end;

  Row := nil;
  if TdChatList <> nil then begin
    Row := TdChatList.Lookup(AChatId);
  end;
  if Row = nil then begin
    Height := 0;
    Exit;
  end;

  { Header strip + content area + the card's own top and bottom margins
    (see CardRect). }
  Height := CHATROW_HEADER_BAR_H + CHAT_HEADER_CONTENT_H
    + CHAT_HEADER_CARD_MARGIN_TOP + CHAT_HEADER_CARD_MARGIN_BOTTOM;

  ChatChanged := FChatId <> AChatId;
  FChatId := AChatId;

  if ChatChanged then begin
    FTypeIconIdx := ChatHeaderTypeIcon(Row);
    FPremium := TdChatList.IsPremiumUser(Row);
    FIdText := IntToStr(Row.Id);
    { Only meaningful for channels — hidden for every other chat kind,
      per direct request. }
    FSimilarVisible := Row.Kind = ckChannel;
    { A different chat's avatar may be a completely different image.
      Dropping the bitmap, not just the remembered path, is what makes
      the check below correct: a chat with NO photo has PhotoPath = '',
      which compares equal to a reset path, so the render was skipped
      and the PREVIOUS chat's avatar stayed on screen (and a chat that
      never had one — a deleted account — got no disc at all). With the
      bitmap gone, nil is the "nothing rendered yet" state. }
    FAvatarPath := '';
    FreeAndNil(FAvatarBmp);
    { The model drops its filter on every chat switch (TTdMessages.
      Clear), so the buttons have to follow, or a pressed one would
      claim a filter that isn't applied to what's on screen. Silent by
      design — ClearFilterUI raises no event, and re-applying an empty
      filter from here would fight the history load OpenChat has just
      started. }
    ClearFilterUI;
  end;

  { Pin/mute change without a chat switch too (a click here, a click in
    the chat list, or another client) — read every call, not gated
    behind ChatChanged. Mute has no effect on Saved Messages
    (TTdChats.IsSelfChat) — hidden, the same treatment the chat list
    row gives it. }
  FPinned := Row.IsPinned;
  FMuted := Row.IsMuted;
  FHasMute := not TdChatList.IsSelfChat(Row);

  { Read on every call, not once per chat switch, for the same reason
    as the three above: the deleted flag comes from a SEPARATE
    updateUser, which routinely lands after the chat was opened — held
    behind ChatChanged the header would keep a blank name until the
    user switched away and back. Hence the title here as well. }
  FDeleted := TdChatList.IsDeletedUser(Row);
  if FDeleted then begin
    FTitle := DELETED_ACCOUNT_TITLE;
  end
  else begin
    FTitle := string(Row.Title);
  end;

  { The avatar is re-rendered only when the chat changed (the bitmap
    was dropped above) or its photo path did — RenderAvatarBmp decodes
    a real JPEG when a downloaded photo exists, and Refresh runs on
    every ModelChanged, several times a second while messages stream
    in. }
  if (FAvatarBmp = nil) or (Row.PhotoPath <> FAvatarPath) then begin
    FAvatarPath := Row.PhotoPath;
    if TdChatList <> nil then begin
      TdChatList.EnsureAvatar(Row);
    end;
    FreeAndNil(FAvatarBmp);
    FAvatarBmp := RenderAvatarBmp(Row.PhotoPath, Row.Minithumb, Row.Title, Row.Id,
      CHAT_HEADER_AVATAR_SIZE, True);
  end;

  DoLayout;
  { Explicit, not left to whatever side effect Height/DoLayout happen to
    trigger — switching between two chats that are both already at full
    Height is a same-value assignment LCL may not treat as a resize, so
    nothing would otherwise repaint the card in the new chat's color. }
  Invalidate;
end;

function TChatHeaderPanel.FilterTypeFor(AIndex: integer): utf8string;
begin
  case AIndex of
    CHAT_HEADER_FILTER_PHOTOS: Result := TD_MSG_FILTER_PHOTO;
    CHAT_HEADER_FILTER_VIDEOS: Result := TD_MSG_FILTER_VIDEO;
    CHAT_HEADER_FILTER_FILES:  Result := TD_MSG_FILTER_DOCUMENT;
    CHAT_HEADER_FILTER_AUDIO:  Result := TD_MSG_FILTER_AUDIO;
    CHAT_HEADER_FILTER_LINKS:  Result := TD_MSG_FILTER_URL;
    CHAT_HEADER_FILTER_POLLS:  Result := TD_MSG_FILTER_POLL;
    CHAT_HEADER_FILTER_VOICE:  Result := TD_MSG_FILTER_VOICE;
    CHAT_HEADER_FILTER_GIF:    Result := TD_MSG_FILTER_ANIMATION;
    CHAT_HEADER_FILTER_PINNED: Result := TD_MSG_FILTER_PINNED;
  else
    { Gifts and saved — not message filters at all, see the class
      comment. '' is what marks a toggle as a stub, and MouseDown reads
      the same function before touching FActiveFilter, so neither of
      them can ever become the active one (and so can never be picked
      up by ApplyFilter below either). }
    Result := '';
  end;
end;

{ Grey frame for an idle toggle, black for the active one — the pairs
  sit next to each other in FilterButtons12, in CHAT_HEADER_FILTER_*
  order. }
function TChatHeaderPanel.FilterIconIndex(AIndex: integer): integer;
begin
  Result := 2 * AIndex + CHAT_HEADER_FILTER_ICON_OFF;
  if AIndex = FActiveFilter then begin
    Result := 2 * AIndex + CHAT_HEADER_FILTER_ICON_ON;
  end;
end;

function TChatHeaderPanel.FilterAt(const APoint: TPoint): integer;
var
  I: integer;
begin
  { The bottom row first. FSimilarRect collapses to zero width outside
    a channel and PtInRect never matches an empty rect, so there is no
    "is it visible" flag to check here — that is the whole point of
    collapsing it rather than hiding it. }
  if PtInRect(FPanelRect, APoint) then begin
    Result := CHAT_HEADER_HIT_PANEL;
    Exit;
  end;
  if PtInRect(FSimilarRect, APoint) then begin
    Result := CHAT_HEADER_HIT_SIMILAR;
    Exit;
  end;
  for I := 0 to CHAT_HEADER_FILTER_COUNT - 1 do begin
    if PtInRect(FFilterRects[I], APoint) then begin
      Result := I;
      Exit;
    end;
  end;
  Result := -1;
end;

function TChatHeaderPanel.FilterHint(AHit: integer): string;
begin
  case AHit of
    CHAT_HEADER_HIT_PANEL: begin
      if FInfoPanelOpen then begin
        Result := 'Hide chat info';
      end else begin
        Result := 'Show chat info';
      end;
    end;
    CHAT_HEADER_HIT_SIMILAR:   Result := 'Similar channels';
    CHAT_HEADER_FILTER_GIFTS:  Result := 'Gifts';
    CHAT_HEADER_FILTER_SAVED:  Result := 'Saved messages';
    CHAT_HEADER_FILTER_PHOTOS: Result := 'Photos';
    CHAT_HEADER_FILTER_VIDEOS: Result := 'Videos';
    CHAT_HEADER_FILTER_FILES:  Result := 'Files';
    CHAT_HEADER_FILTER_AUDIO:  Result := 'Music';
    CHAT_HEADER_FILTER_LINKS:  Result := 'Links';
    CHAT_HEADER_FILTER_POLLS:  Result := 'Polls';
    CHAT_HEADER_FILTER_VOICE:  Result := 'Voice messages';
    CHAT_HEADER_FILTER_GIF:    Result := 'GIFs';
    CHAT_HEADER_FILTER_PINNED: Result := 'Pinned messages';
  else
    Result := '';
  end;
end;

procedure TChatHeaderPanel.SetInfoPanelOpen(AOpen: boolean);
begin
  if FInfoPanelOpen = AOpen then begin
    Exit;
  end;
  FInfoPanelOpen := AOpen;
  Invalidate;
end;

procedure TChatHeaderPanel.ApplyFilter;
var
  FilterType: utf8string;
begin
  if not Assigned(FOnFilterChanged) then begin
    Exit;
  end;
  FilterType := '';
  if FActiveFilter >= 0 then begin
    FilterType := FilterTypeFor(FActiveFilter);
  end;
  { Filter and query go out TOGETHER, not one instead of the other:
    searchChatMessages takes both, so "photos" plus a word narrows to
    photos whose caption matches. Both empty = ordinary history. }
  FOnFilterChanged(Self, FilterType, utf8string(Trim(edtSearch.Text)));
end;

procedure TChatHeaderPanel.ClearFilterUI;
begin
  FActiveFilter := -1;
  edtSearch.Text := '';
  Invalidate;
end;

procedure TChatHeaderPanel.SearchGo(Sender: TObject);
begin
  ApplyFilter;
end;

procedure TChatHeaderPanel.SearchKeyPress(Sender: TObject; var Key: char);
begin
  if Key = #13 then begin
    Key := #0;
    ApplyFilter;
    Exit;
  end;
  if Key = #27 then begin
    { Escape clears the query and re-runs — dropping back to the plain
      history if no filter button is pressed either. The key is
      swallowed so it doesn't travel on to anything that treats Escape
      as "close". }
    Key := #0;
    edtSearch.Text := '';
    ApplyFilter;
  end;
end;

end.
