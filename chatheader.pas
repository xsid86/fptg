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
    title, numeric id, pin, mute, "more") plus the avatar is PAINTED,
    not built from child controls, exactly as the chat list paints its
    own rows: an earlier pass made each of these a TSpeedButton/TLabel
    and it neither looked nor behaved like the reference (buttons where
    the reference has a bare glyph, native button chrome where it has a
    flat framed box, and three separate ELayoutException crashes from
    LCL's AutoSize fighting explicitly-set bounds). Clicks on the
    painted parts are hit-tested in MouseDown against rects computed
    during Paint, the same approach framechats.HitArea uses.

    Real child controls remain only where one is genuinely needed: the
    12 filter buttons and the magnifier (they want hover feedback and
    native icon drawing) and the search TEdit (text input).

    Nine of the twelve filter buttons plus the search box drive ONE
    request — searchChatMessages with a different SearchMessagesFilter
    (see TD_MSG_FILTER_* and TTdMessages.SetSearchFilter) — and are
    wired up through OnFilterChanged. They behave as one radio group
    (GroupIndex/AllowAllUp, set in Create — see there for why not in
    the .lfm): the pressed one is the active filter, pressing it again
    releases it and, with an empty search box, returns to the ordinary
    history. Filter and query COMBINE rather than replace each other,
    exactly as the TDLib request itself takes both.

    The other three — gifts, saved and similar-channels — are still
    stubs, and not because they were forgotten: TDLib answers those
    with receivedGifts / a savedMessagesTopic history / a list of chat
    ids, none of which are messages, so none of them can go through the
    message list the other nine reuse. They are also kept out of the
    radio group, so they can't look "active". "more" is a stub too (no
    details panel exists yet).

    The bar hides itself by collapsing to Height=0 (Refresh(0), or no
    chat found for the id) rather than toggling Visible — the same
    "collapse to zero, don't hide" rule the chat list already applies
    to individual row icons, and it keeps this control out of the
    Align-ordering machinery that misplaced an earlier version of this
    bar entirely.

    A real TFrame with a paired chatheader.lfm, same as msginput.pas —
    so the 13 buttons and the search edit are ordinary published fields
    streamed from the .lfm and can be edited in the Lazarus Designer
    (that is what the .lfm is FOR here: the Hint on each button, and
    their order, are meant to be set visually, not in code). TFrame
    still descends from TCustomControl (TCustomFrame ->
    TCustomDesignControl -> TScrollingWinControl -> TCustomControl,
    checked in the LCL source, not assumed), so Canvas/Paint below work
    exactly as they did before the conversion.

    Two .lfm properties this bar's looks depend on, in case they ever
    get flipped in the Designer by accident: ParentColor=True (Paint
    fills everything outside the card with Color, which must be the
    frame around it — white here draws a white band around the card)
    and ParentBackground=False.

    The buttons' positions in the .lfm are design-time only: DoLayout
    re-places all of them from the card's geometry on every resize. }
  TChatHeaderPanel = class(TFrame)
    { Streamed from chatheader.lfm — the 12 filter buttons in
      CHAT_HEADER_FILTER_* order (Create wires them into FFilters by
      that index; changing their ORDER on screen is a matter of moving
      them in FFilters, not of renaming anything here), the magnifier
      and the search box. }
    btnGifts:   TSpeedButton;
    btnSaved:   TSpeedButton;
    btnPhotos:  TSpeedButton;
    btnVideos:  TSpeedButton;
    btnFiles:   TSpeedButton;
    btnAudio:   TSpeedButton;
    btnLinks:   TSpeedButton;
    btnPolls:   TSpeedButton;
    btnVoice:   TSpeedButton;
    btnGif:     TSpeedButton;
    btnSimilar: TSpeedButton;
    btnPinned:  TSpeedButton;
    btnSearch:  TSpeedButton;
    edtSearch:  TEdit;
    procedure FilterClick(Sender: TObject);
    procedure SearchGo(Sender: TObject);
    procedure SearchKeyPress(Sender: TObject; var Key: char);
  private
    FChatId:       Int64;
    FTypeIcons:    TCustomImageList;
    FPremiumIcons: TCustomImageList;
    FDeletedIcons: TCustomImageList;
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
    FMoreRect:       TRect;
    FAvatarRect:     TRect;
    { The search field's frame — edtSearch sits inset inside it and the
      magnifier inside its right end, so it's neither control's own
      bounds and has to be remembered for Paint. }
    FSearchSlotRect: TRect;

    { The 12 published filter buttons above, indexed by
      CHAT_HEADER_FILTER_* — filled once in Create. A published field
      can't be an array (the streaming system addresses components by
      name), so the array is built from the named fields rather than
      the other way round. }
    FFilters: array[0..11] of TSpeedButton;
    FOnFilterChanged: TChatHeaderFilterEvent;

    { The TDLib SearchMessagesFilter name for one CHAT_HEADER_FILTER_*
      index, or '' for the three buttons that aren't a message filter
      at all (gifts/saved/similar — see the class comment). }
    function FilterTypeFor(AIndex: integer): utf8string;
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
      FilterButtons (CHAT_HEADER_FILTER_* indices). ASearchIcons/
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
    { Releases every filter button and empties the search box WITHOUT
      raising OnFilterChanged — for putting the bar back in step with a
      model whose filter was dropped elsewhere, not for changing it. }
    procedure ClearFilterUI;
    property OnFilterChanged: TChatHeaderFilterEvent
      read FOnFilterChanged write FOnFilterChanged;
  end;

implementation

{$R *.lfm}

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
var
  I: integer;
begin
  { Streams chatheader.lfm — every child control below already exists
    (and already carries its Designer-set Hint) once this returns. }
  inherited Create(AOwner);
  FTypeIconIdx := -1;

  FFilters[CHAT_HEADER_FILTER_GIFTS]   := btnGifts;
  FFilters[CHAT_HEADER_FILTER_SAVED]   := btnSaved;
  FFilters[CHAT_HEADER_FILTER_PHOTOS]  := btnPhotos;
  FFilters[CHAT_HEADER_FILTER_VIDEOS]  := btnVideos;
  FFilters[CHAT_HEADER_FILTER_FILES]   := btnFiles;
  FFilters[CHAT_HEADER_FILTER_AUDIO]   := btnAudio;
  FFilters[CHAT_HEADER_FILTER_LINKS]   := btnLinks;
  FFilters[CHAT_HEADER_FILTER_POLLS]   := btnPolls;
  FFilters[CHAT_HEADER_FILTER_VOICE]   := btnVoice;
  FFilters[CHAT_HEADER_FILTER_GIF]     := btnGif;
  FFilters[CHAT_HEADER_FILTER_SIMILAR] := btnSimilar;
  FFilters[CHAT_HEADER_FILTER_PINNED]  := btnPinned;
  { Tag carries the CHAT_HEADER_FILTER_* index into FilterClick — set
    here rather than in the .lfm so it can't drift out of step with
    FFilters if the buttons are reshuffled in the Designer. }
  for I := 0 to 11 do begin
    FFilters[I].Tag := I;
    { GroupIndex/AllowAllUp deliberately here and NOT in the .lfm: this
      is behavior, not looks, and it has to stay in step with
      FilterTypeFor — a button that maps to a real SearchMessagesFilter
      is part of the one-of-N group, the three that don't are left out
      so they can never appear "active". Setting it from the same loop
      that indexes FFilters makes that impossible to get out of sync,
      and a designer round-trip (reordering the buttons, dropping icons
      on them, editing hints) can't silently drop it — which is exactly
      what happened to an earlier .lfm version of this. }
    if FilterTypeFor(I) <> '' then begin
      FFilters[I].GroupIndex := 1;
      FFilters[I].AllowAllUp := True;
    end;
  end;
  FFilters[CHAT_HEADER_FILTER_SIMILAR].Visible := False;

  Height := 0;   { no chat open yet — see the class comment }
end;

destructor TChatHeaderPanel.Destroy;
begin
  FAvatarBmp.Free;
  inherited Destroy;
end;

procedure TChatHeaderPanel.SetImageLists(ATypeIcons, APremiumIcons, AFilterIcons, ASearchIcons,
  ADeletedIcons: TCustomImageList; ASearchIconIndex: integer);
var
  I: integer;
begin
  FTypeIcons := ATypeIcons;
  FPremiumIcons := APremiumIcons;
  FDeletedIcons := ADeletedIcons;
  for I := 0 to 11 do begin
    FFilters[I].Images := AFilterIcons;
    FFilters[I].ImageIndex := I;
  end;
  btnSearch.Images := ASearchIcons;
  btnSearch.ImageIndex := ASearchIconIndex;
end;

{ Positions the few REAL child controls (avatar is painted, not a
  control: only the filter buttons, the magnifier and the search edit
  are). Geometry copied from framechats.ChatRowRects — header strip of
  CHATROW_HEADER_BAR_H on top, content area below, MSG_PAD_H in from
  the card's edges, MSG_PAD_V down from the content area's top. The
  painted parts' rects are computed in Paint instead, where the text
  widths they depend on are known. }
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
  X, RightX, I, SearchY, EditL, EditR: integer;
begin
  if (Width <= 0) or (Height <= 0) then begin
    Exit;
  end;
  { Streaming chatheader.lfm assigns this frame's OWN properties
    (Height among them) before it has created a single child control,
    and every one of those assignments fires Resize -> here with
    btnSearch/edtSearch/FFilters still nil — a real access violation on
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
  { The gap from the avatar to the first filter icon is the same
    MSG_PAD_H as from the card's edge to the avatar, by direct
    request — not CHAT_HEADER_FILTER_GAP, which is only the gap
    BETWEEN two filter icons. }
  X := FAvatarRect.Right + MSG_PAD_H;

  { The search field is one framed box (Paint draws the frame at
    FSearchSlotRect) with two children inside it: the text edit filling
    its left part and the magnifier inside its right end. }
  RightX := Content.Right - MSG_PAD_H;
  Dec(RightX, SearchW);
  SearchY := Content.Top + (CHAT_HEADER_CONTENT_H - SearchH) div 2;
  FSearchSlotRect := Rect(RightX, SearchY, RightX + SearchW, SearchY + SearchH);

  btnSearch.SetBounds(FSearchSlotRect.Right - SearchInset - MagnifierW, SearchY + SearchInset,
    MagnifierW, SearchH - 2 * SearchInset);
  EditL := FSearchSlotRect.Left + SearchInset + MSG_ICON_GAP;
  EditR := FSearchSlotRect.Right - SearchInset - MagnifierW;
  edtSearch.SetBounds(EditL, SearchY + SearchInset, EditR - EditL, SearchH - 2 * SearchInset);
  Dec(RightX, CHAT_HEADER_FILTER_GAP);

  for I := 0 to 11 do begin
    if not FFilters[I].Visible then begin
      Continue;
    end;
    { Stops rather than overlaps the search field on a narrow window —
      no wrapping, the remaining filter icons just don't get a slot. }
    if X + CHAT_HEADER_FILTER_SIZE > RightX then begin
      Break;
    end;
    FFilters[I].SetBounds(X, Content.Top + (CHAT_HEADER_CONTENT_H - CHAT_HEADER_FILTER_SIZE) div 2,
      CHAT_HEADER_FILTER_SIZE, CHAT_HEADER_FILTER_SIZE);
    Inc(X, CHAT_HEADER_FILTER_SIZE + CHAT_HEADER_FILTER_GAP);
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
  (FPinRect/FMuteRect/FIdRect/FMoreRect) that MouseDown hit-tests
  against, since their positions depend on text widths only known
  here. }
procedure TChatHeaderPanel.Paint;
var
  Accent, HeaderFill, Border: TColor;
  Card, Header, Content: TRect;
  IconY, RightX, TitleX, TextY, MoreW, MoreH: integer;
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

  { --- header strip, right to left: more, mute, pin, id --- }
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Style := [];
  RightX := Header.Right - MSG_PAD_H;

  MoreW := Canvas.TextWidth('more...') + 2 * GAP;
  MoreH := CHATROW_HEADER_BAR_H - 2 * MSG_PAD_V;
  Dec(RightX, MoreW);
  FMoreRect := Rect(RightX, Header.Top + (CHATROW_HEADER_BAR_H - MoreH) div 2,
    RightX + MoreW, Header.Top + (CHATROW_HEADER_BAR_H - MoreH) div 2 + MoreH);
  { A framed box, like the reference — its radius clamped to half its
    own height, or GDI draws a squashed capsule instead of rounded
    corners (the same "oval artifact" already documented for the
    message header strip elsewhere in this app). }
  PaintCard(FMoreRect, Min(CHATROW_CORNER_RADIUS, MoreH div 2), [], clWindow, Border);
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := clWindowText;
  Canvas.TextOut(FMoreRect.Left + GAP,
    FMoreRect.Top + (MoreH - Canvas.TextHeight('more...')) div 2, 'more...');
  Dec(RightX, GAP);

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

  { --- content area: the avatar (the filter icons and the search box
        are real child controls, they paint themselves on top) --- }
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

  PaintCard(FSearchSlotRect, Min(CHATROW_CORNER_RADIUS,
    (FSearchSlotRect.Bottom - FSearchSlotRect.Top) div 2), [], clWindow, Border);

  { Outline last, over the content — same order as the chat row. }
  PaintCard(Card, CHATROW_CORNER_RADIUS, [], clNone, Border);
end;

procedure TChatHeaderPanel.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  P: TPoint;
  Row: TChatRow;
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
  if PtInRect(FMoreRect, P) then begin
    { Stub, by direct request — the details side panel doesn't exist
      yet. }
    Exit;
  end;
end;

procedure TChatHeaderPanel.MouseMove(Shift: TShiftState; X, Y: integer);
var
  P: TPoint;
begin
  inherited MouseMove(Shift, X, Y);
  P := Point(X, Y);
  if PtInRect(FIdRect, P) or PtInRect(FPinRect, P) or PtInRect(FMoreRect, P)
     or (FHasMute and PtInRect(FMuteRect, P)) then begin
    Cursor := crHandPoint;
  end else begin
    Cursor := crDefault;
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
    FFilters[CHAT_HEADER_FILTER_SIMILAR].Visible := Row.Kind = ckChannel;
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
    { Gifts, saved and similar-channels — not message filters at all,
      see the class comment. '' is what marks a button as a stub, and
      Create reads the same function to decide which buttons join the
      toggle group, so those three can never end up Down and can never
      be picked up by ApplyFilter below either. }
    Result := '';
  end;
end;

procedure TChatHeaderPanel.ApplyFilter;
var
  I: integer;
  FilterType: utf8string;
begin
  if not Assigned(FOnFilterChanged) then begin
    Exit;
  end;
  { At most one can be Down — they share a GroupIndex — so the first
    hit is the answer. }
  FilterType := '';
  for I := 0 to 11 do begin
    if FFilters[I].Down then begin
      FilterType := FilterTypeFor(I);
      Break;
    end;
  end;
  { Filter and query go out TOGETHER, not one instead of the other:
    searchChatMessages takes both, so "photos" plus a word narrows to
    photos whose caption matches. Both empty = ordinary history. }
  FOnFilterChanged(Self, FilterType, utf8string(Trim(edtSearch.Text)));
end;

procedure TChatHeaderPanel.ClearFilterUI;
var
  I: integer;
begin
  for I := 0 to 11 do begin
    if FFilters[I].GroupIndex <> 0 then begin
      FFilters[I].Down := False;
    end;
  end;
  edtSearch.Text := '';
end;

procedure TChatHeaderPanel.FilterClick(Sender: TObject);
begin
  { The three non-filter buttons (gifts/saved/similar) share this
    handler but must not clear whatever filter IS active — they have
    nothing to switch to yet. }
  if (Sender is TSpeedButton) and (FilterTypeFor(TSpeedButton(Sender).Tag) = '') then begin
    Exit;
  end;
  { The button's own Down state has already been toggled by LCL by the
    time OnClick fires (GroupIndex/AllowAllUp), so ApplyFilter reads
    exactly what the user just asked for — including "released it
    again", which with an empty search box means the full history. }
  ApplyFilter;
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
