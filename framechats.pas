unit framechats;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  avatarcache, BGRABitmap, BGRABitmapTypes,
  Classes, Clipbrd, customemoji,
  Controls, constants, DateUtils, Dialogs, emojiassets, ExtCtrls, Forms, Graphics, Grids,
  Menus, StdCtrls, SysUtils, tdaccentcolors, tdauth, tdchats, tdcore, Types, uiframe;

type
  { Clickable areas within a row. }
  TChatHitArea = (chaNone, chaBell, chaAvatar, chaHeader, chaPin);

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
    pnlBottom: TPanel;
    lblStatus: TLabel;
    mnuChat:   TPopupMenu;
    { Chat-type icons. Placed on the frame in the designer; the name
      must match the one in the .lfm. }
    ImageList1: TImageList;
    { No longer read by code since the "Archive"/"All chats" pseudo-rows
      were redesigned to look like a card (those now take their icon
      from icons12, see CHATROW_ICON_ARCHIVE/ALLCHATS) — the field is
      deliberately left in place: the component is still declared in
      the .lfm, and removing a typed field for a component that's
      already there in the designer is a risk not worth taking without
      a clear need (not a case where the payoff is worth risking the
      streaming). }
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
    FOnSelect: TChatSelectEvent;
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
    { Same idea as TMsgScroller.FCustomEmojiTimer (framehistory.pas),
      but for a different reason: this frame has no direct notification
      path at all from a custom emoji resolving in TTdMessages (a
      different model, opened chat's history) to itself — Touch there
      reaches the message scroller, never the chat list. A slower poll
      (this list doesn't need animation-grade smoothness, just eventual
      consistency once something resolves) that calls
      customemoji.AnyPendingWork and invalidates the grid if true. }
    FCustomEmojiTimer: TTimer;
    procedure CustomEmojiAnimTick(Sender: TObject);
    procedure BindModel;
    procedure UnbindModel;
    { The archive is not a chat: row index 0 is reserved for it, chats
      are shifted by one. A fake TChatRow would drag it into the
      context menu and chat-opening logic, which it must not be part
      of. }
    function ChatAt(AGridRow: Integer): TChatRow;
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
      collapses APinR to zero width at MuteR's left edge, rather than
      simply not drawing it: TitleRight (the time text's right boundary
      in GridDrawCell) is computed from PinR.Left, and without actually
      shrinking this rectangle the time would overlap the empty space
      where the pin icon used to be. }
    function ChatRowRects(const ARect: TRect; AHasPin: Boolean; out AHeader, AContent,
      AIconR, AAvatarR, AMuteR, APinR: TRect): TRect;
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
    procedure LoadingChanged(Sender: TObject);
    procedure MaybeLoadMore;
    procedure BuildMenu(ARow: TChatRow);
    procedure MenuItemClick(Sender: TObject);
    function CurrentRow: TChatRow;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;

    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
    property Selected: TChatRow read CurrentRow;
    property OnSelect: TChatSelectEvent read FOnSelect write FOnSelect;
    property Mode: TChatListMode read FMode write SetMode;
    property OnListMode: TListModeEvent read FOnListMode write FOnListMode;
    property OnAvatar: TAvatarClickEvent read FOnAvatar write FOnAvatar;
  end;

implementation

{$R *.lfm}

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

{ Rounded fill/outline for a row card — its own, trimmed-down copy of
  PaintRoundRectAA (framehistory.pas, the SMOOTH_CORNERS=False branch):
  same reason for an independent copy as ChatAccentColor above, and the
  same choice of drawing method — the chat list scrolls exactly as
  often as the message history, and the same lesson about the cost of
  BGRA antialiasing on every frame applies here identically — plain GDI
  Canvas.RoundRect, no TBGRABitmap at all.
  AOptions/[rrBottomLeftSquare, rrBottomRightSquare] is the same
  "square off the bottom" trick used for the card header as with
  messages. }
procedure PaintCardRoundRect(ACanvas: TCanvas; const ABox: TRect; ARadius: single;
  AOptions: TRoundRectangleOptions; AFillColor, ABorderColor: TColor;
  ABorderWidth: single = 1);
var
  IRadius: Integer;
begin
  if (ABox.Right - ABox.Left <= 0) or (ABox.Bottom - ABox.Top <= 0) then begin
    Exit;
  end;
  IRadius := Round(ARadius);
  ACanvas.Pen.Style := psClear;
  if ABorderColor <> clNone then begin
    ACanvas.Pen.Style := psSolid;
    ACanvas.Pen.Color := ABorderColor;
    ACanvas.Pen.Width := Round(ABorderWidth);
  end;
  if AFillColor <> clNone then begin
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := AFillColor;
  end else begin
    ACanvas.Brush.Style := bsClear;
  end;
  ACanvas.RoundRect(ABox.Left, ABox.Top, ABox.Right, ABox.Bottom, IRadius * 2, IRadius * 2);
  if (AFillColor <> clNone) and (rrBottomLeftSquare in AOptions) and
    (rrBottomRightSquare in AOptions) then begin
    ACanvas.Pen.Style := psClear;
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := AFillColor;
    ACanvas.FillRect(Rect(ABox.Left, ABox.Bottom - IRadius, ABox.Right, ABox.Bottom));
  end;
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

  FMeasure := TBGRABitmap.Create(1, 1);
  FMeasure.FontName := 'default';
  FMeasure.FontHeight := BADGE_FONT_H;
  FMeasure.FontStyle := [fsBold];
  FMeasure.FontQuality := fqFineAntialiasing;

  Grid.ColCount  := 1;
  Grid.FixedCols := 0;
  Grid.FixedRows := 0;
  Grid.RowCount  := 0;
  Grid.DefaultRowHeight := ROW_HEIGHT;
  Grid.MouseWheelOption := mwGrid;
  Grid.FocusRectVisible := False;

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
  M.OnLoadingChanged := @LoadingChanged;
  M.OnActionError := @ActionError;
  ModelChanged(nil);
  LoadingChanged(nil);
end;

procedure TFrameChats.UnbindModel;
begin
  { Detaches only OUR handlers — someone else's must not be clobbered. }
  if FModel <> nil then begin
    if TMethod(FModel.OnChanged).Data = Pointer(Self) then begin
      FModel.OnChanged := nil;
    end;
    if TMethod(FModel.OnLoadingChanged).Data = Pointer(Self) then begin
      FModel.OnLoadingChanged := nil;
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
begin
  if (not FReady) or (Grid = nil) or (FModel = nil) then begin
    Exit;
  end;
  Grid.RowCount := RowsCount + ARCHIVE_ROWS;
  Grid.Invalidate;
  { If there are fewer chats than fit in the window, load more right
    away: the scrolling that would normally trigger this won't happen. }
  MaybeLoadMore;
end;

procedure TFrameChats.LoadingChanged(Sender: TObject);
var
  Busy, Done: Boolean;
begin
  if (not FReady) or (lblStatus = nil) or (FModel = nil) then begin
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

  if Busy then begin
    lblStatus.Caption := 'Loading...';
  end
  else if Done then begin
    lblStatus.Caption := Format('%d chats', [RowsCount]);
  end
  else begin
    lblStatus.Caption := Format('%d chats (more)', [RowsCount]);
  end;
end;

procedure TFrameChats.ActionError(Sender: TObject; ACode: Integer; const AMessage, AAction: Utf8string);
begin
  { A TDLib refusal on a menu action must not be silent: without this,
    "Pin" on a full list would just appear to do nothing. }
  if lblStatus <> nil then begin
    lblStatus.Caption := Format('Error %d: %s', [ACode, String(AMessage)]);
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

procedure TFrameChats.GridTopLeftChanged(Sender: TObject);
begin
  MaybeLoadMore;
end;

procedure TFrameChats.Resize;
begin
  inherited Resize;
  { Column width is handled by the grid's AutoFillColumns. All that's
    left here is loading more: a bigger window means more rows visible. }
  MaybeLoadMore;
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
  LoadingChanged(nil);
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

function TFrameChats.ChatRowRects(const ARect: TRect; AHasPin: Boolean; out AHeader, AContent,
  AIconR, AAvatarR, AMuteR, APinR: TRect): TRect;
var
  IconY: Integer;
begin
  { The card is ARect inset by CHATROW_GAP left/right (from the list's
    edge) and, vertically, by HALF of CHATROW_GAP on both top AND
    bottom — the whole 4px gap used to go entirely to the bottom (the
    same idea as MSG_GAP for messages, "after the block"), which made
    the card visually start right at the top edge of the list row; the
    card's total height is unchanged, the 4px still goes entirely to
    the gap, just split evenly between both sides instead of only the
    bottom. }
  Result := Rect(ARect.Left + CHATROW_GAP, ARect.Top + CHATROW_GAP div 2,
    ARect.Right - CHATROW_GAP, ARect.Bottom - CHATROW_GAP div 2);

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
    constants.pas). }
  AAvatarR := Rect(AContent.Left + MSG_PAD_H, AContent.Top + MSG_PAD_V,
    AContent.Left + MSG_PAD_H + AVATAR_SIZE, AContent.Top + MSG_PAD_V + AVATAR_SIZE);

  { Right to left: the notification bell (at the very edge), then the
    pin to its left. Further left (checkmark/time) is variable width,
    computed at the point of drawing, and not part of the hit test
    (not clickable). }
  AMuteR := Rect(AHeader.Right - MSG_PAD_H - CHATROW_ICON_SIZE, IconY,
    AHeader.Right - MSG_PAD_H, IconY + CHATROW_ICON_SIZE);
  if AHasPin then begin
    APinR := Rect(AMuteR.Left - GAP - CHATROW_ICON_SIZE, IconY,
      AMuteR.Left - GAP, IconY + CHATROW_ICON_SIZE);
  end
  else begin
    { Pinning isn't allowed in the archive — collapsed to zero width at
      MuteR's left edge, not simply "not drawn": TitleRight in
      GridDrawCell is computed from PinR.Left, and the time needs to
      butt right up against MuteR, as if the pin slot had never
      existed. }
    APinR := Rect(AMuteR.Left, IconY, AMuteR.Left, IconY + CHATROW_ICON_SIZE);
  end;
end;

procedure TFrameChats.DrawHeaderRow(ARect: TRect; ASelected: Boolean);
var
  Cv:    TCanvas;
  Badge: TBGRABitmap;
  A:     TArchiveInfo;
  Card, Header, Content, IconR, AvatarR, MuteR, PinR: TRect;
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
    go unused here (this card has none of them). AHasPin doesn't matter
    (False for consistency — there's no icon from that pair here
    either way). }
  Card := ChatRowRects(ARect, False, Header, Content, IconR, AvatarR, MuteR, PinR);

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
  Bmp, Badge, Rec: TBGRABitmap;
  Card, Header, Content, IconR, AvatarR, MuteR, PinR: TRect;
  BaseBg, Accent, BodyFill, HeaderFill, BorderCol: TColor;
  TitleRight, PrevRight, Y, W, MuteIdx, PinIdx: Integer;
  Sel: Boolean;
  S:   String;
  PrevGlyphs: TCustomGlyphSpanArray;
  GlyphShift, GI: Integer;
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
    BaseBg := clWindow;
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
    all, not merely disabled. }
  Card := ChatRowRects(ARect, FMode <> clmArchive, Header, Content, IconR, AvatarR, MuteR, PinR);

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

  DrawIcon12(IconR, TypeIconIndex(R));

  if R.IsMuted then begin
    MuteIdx := CHATROW_ICON_NOTIFY_OFF;
  end
  else begin
    MuteIdx := CHATROW_ICON_NOTIFY_ON;
  end;
  DrawIcon12(MuteR, MuteIdx);

  if FMode <> clmArchive then begin
    if R.IsPinned then begin
      PinIdx := CHATROW_ICON_PIN;
    end
    else begin
      PinIdx := CHATROW_ICON_UNPIN;
    end;
    DrawIcon12(PinR, PinIdx);
  end;

  Cv.Brush.Style := bsClear;

  { --- header: time + read receipt, right to left from the pin ---
    Text colors inside the card no longer depend on Sel (see the
    comment above about the "behind the card" fill) — the card looks
    the same whether the row is selected or not; the selection cue is
    the fill surrounding it. }
  TitleRight := PinR.Left - GAP;
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
  S := String(R.Title);
  { No entity data is captured for chat titles (see the comment on
    A.Preview's own DrawEmojiLine call below) — nil. }
  DrawEmojiLine(Cv, Rect(IconR.Right + MSG_ICON_GAP, Header.Top, TitleRight, Header.Bottom),
    IconR.Right + MSG_ICON_GAP, Header.Top + (CHATROW_HEADER_BAR_H - Cv.TextHeight(S)) div 2, S, nil);

  { --- last-message preview + unread counter --- }
  Cv.Brush.Style := bsClear;
  PrevRight := Content.Right - MSG_PAD_H;
  if (R.UnreadCount > 0) or R.IsMarkedAsUnread then begin
    if R.UnreadCount > 0 then begin
      S := IntToStr(R.UnreadCount);
    end
    else begin
      S := '';
    end;
    Badge := BadgeBitmap(S, False);
    if Badge <> nil then begin
      Y := Content.Top + (CHATROW_CONTENT_H - Badge.Height) div 2;
      Badge.Draw(Cv, PrevRight - Badge.Width, Y, False);
      Dec(PrevRight, Badge.Width + GAP);
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
    ChatRowRects), vertically centered on the same line as the avatar,
    not just "top-aligned with a MSG_PAD_V offset" as it was before the
    avatar moved. }
  DrawEmojiLine(Cv, Rect(AvatarR.Right + MSG_ICON_GAP, Content.Top,
    PrevRight, Content.Bottom),
    AvatarR.Right + MSG_ICON_GAP, Content.Top + (CHATROW_CONTENT_H - Cv.TextHeight(S)) div 2, S,
    PrevGlyphs);

  { --- card outline — drawn last, on top of the content --- }
  PaintCardRoundRect(Cv, Card, CHATROW_CORNER_RADIUS, [], clNone, BorderCol);
end;

{ ---------------- selection and menu ---------------- }

function TFrameChats.CurrentRow: TChatRow;
begin
  Result := ChatAt(Grid.Row);
end;

procedure TFrameChats.GridSelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
begin
  CanSelect := True;
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
  if Assigned(FOnSelect) then begin
    FOnSelect(Self, ChatAt(ARow));
  end;
end;

function TFrameChats.HitArea(X, Y: Integer; out ARow: TChatRow): TChatHitArea;
var
  C, Row: Integer;
  Cell:   TRect;
  Card, Header, Content, IconR, AvatarR, MuteR, PinR: TRect;
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
    FMode <> clmArchive, Header, Content, IconR, AvatarR, MuteR, PinR);

  if PtInRect(MuteR, P) then begin
    Result := chaBell;
    Exit;
  end;
  if PtInRect(PinR, P) then begin
    Result := chaPin;
    Exit;
  end;
  if PtInRect(AvatarR, P) then begin
    Result := chaAvatar;
    Exit;
  end;
end;

procedure TFrameChats.GridMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  R:    TChatRow;
  Want: TCursor;
begin
  if (not FReady) or (Grid = nil) then begin
    Exit;
  end;
  if HitArea(X, Y, R) = chaNone then begin
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
    chaAvatar: begin
      FSuppressSelect := True;
      if Assigned(FOnAvatar) then begin
        FOnAvatar(Self, R);
      end;
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

end.
