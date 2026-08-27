unit framechats;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, Controls, Forms, Graphics, Grids, Menus, StdCtrls, ExtCtrls,
  BGRABitmap, BGRABitmapTypes,
  tdauth, tdcore, tdchats, uiframe, avatarcache;

type
  TChatSelectEvent = procedure(Sender: TObject; ARow: TChatRow) of object;

  { TFrameChats

    Список чатов на TDrawGrid: у сетки нет собственной коллекции строк,
    поэтому модель остаётся единственным хранилищем данных, а
    перестановка чата — это просто Invalidate. }

  TFrameChats = class(TFrameBase)
    Grid: TDrawGrid;
    pnlBottom: TPanel;
    lblStatus: TLabel;
    mnuChat: TPopupMenu;
    procedure GridDrawCell(Sender: TObject; ACol, ARow: integer;
      ARect: TRect; AState: TGridDrawState);
    procedure GridSelectCell(Sender: TObject; ACol, ARow: integer;
      var CanSelect: boolean);
    procedure GridTopLeftChanged(Sender: TObject);
    procedure GridContextPopup(Sender: TObject; MousePos: TPoint;
      var Handled: boolean);
  protected
    { Resize — виртуальный метод TControl, доступен всегда и не зависит
      от того, опубликовано ли одноимённое событие у потомка.
      У TDrawGrid оно НЕ опубликовано. }
    procedure Resize; override;
  private
    FCache: TAvatarCache;
    FReady: boolean;
    FMenuRow: TChatRow;
    FOnSelect: TChatSelectEvent;
    procedure ModelChanged(Sender: TObject);
    procedure LoadingChanged(Sender: TObject);
    procedure MaybeLoadMore;
    procedure BuildMenu(ARow: TChatRow);
    procedure MenuItemClick(Sender: TObject);
    function CurrentRow: TChatRow;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    property Selected: TChatRow read CurrentRow;
    property OnSelect: TChatSelectEvent read FOnSelect write FOnSelect;
  end;

implementation

{$R *.lfm}

const
  ROW_HEIGHT   = 56;
  PAD          = 8;
  AV_LEFT      = 8;
  TEXT_LEFT    = AV_LEFT + AVATAR_SIZE + 10;
  BADGE_H      = 18;
  { За сколько строк до конца просить следующую порцию. }
  PREFETCH_ROWS = 6;

{ ---------------- жизненный цикл ---------------- }

constructor TFrameChats.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FCache := TAvatarCache.Create;

  Grid.ColCount := 1;
  Grid.FixedCols := 0;
  Grid.FixedRows := 0;
  Grid.RowCount := 0;
  Grid.DefaultRowHeight := ROW_HEIGHT;

  TdChatList.OnChanged := @ModelChanged;
  TdChatList.OnLoadingChanged := @LoadingChanged;

  { Флаг ставится последним: до него любой ранний вызов
    (Resize во время чтения .lfm) обязан ничего не делать. }
  FReady := True;
  ModelChanged(nil);
  LoadingChanged(nil);
end;

destructor TFrameChats.Destroy;
begin
  FReady := False;
  { Модель живёт дольше фрейма — обязательно отцепиться, но только
    от своих обработчиков: чужие затирать нельзя. }
  if TdChatList <> nil then begin
    if TMethod(TdChatList.OnChanged).Data = Pointer(Self) then begin
      TdChatList.OnChanged := nil;
    end;
    if TMethod(TdChatList.OnLoadingChanged).Data = Pointer(Self) then begin
      TdChatList.OnLoadingChanged := nil;
    end;
  end;
  FCache.Free;
  inherited Destroy;
end;

{ ---------------- связь с моделью ---------------- }

procedure TFrameChats.ModelChanged(Sender: TObject);
begin
  if (not FReady) or (Grid = nil) then begin
    Exit;
  end;
  Grid.RowCount := TdChatList.Count;
  Grid.Invalidate;
  { Если чатов меньше, чем помещается в окно, докачиваем сразу:
    прокрутки, которая обычно это запускает, не будет. }
  MaybeLoadMore;
end;

procedure TFrameChats.LoadingChanged(Sender: TObject);
begin
  if (not FReady) or (lblStatus = nil) then begin
    Exit;
  end;
  if TdChatList.Loading then begin
    lblStatus.Caption := 'Загрузка...';
  end else if TdChatList.AllLoaded then begin
    lblStatus.Caption := Format('чатов: %d', [TdChatList.Count]);
  end else begin
    lblStatus.Caption := Format('чатов: %d (есть ещё)', [TdChatList.Count]);
  end;
end;

procedure TFrameChats.MaybeLoadMore;
var
  LastVisible: integer;
begin
  { Resize срабатывает ещё во время чтения .lfm, когда Grid — nil.
    Любой перекрытый виртуальный метод обязан это учитывать. }
  if (not FReady) or (Grid = nil) then begin
    Exit;
  end;
  if TdChatList.AllLoaded or TdChatList.Loading then begin
    Exit;
  end;
  LastVisible := Grid.TopRow + (Grid.ClientHeight div ROW_HEIGHT);
  if LastVisible >= TdChatList.Count - PREFETCH_ROWS then begin
    TdChatList.LoadMore;
  end;
end;

procedure TFrameChats.GridTopLeftChanged(Sender: TObject);
begin
  MaybeLoadMore;
end;

procedure TFrameChats.Resize;
begin
  inherited Resize;
  { Ширину колонки держит AutoFillColumns у сетки. Здесь остаётся
    только догрузка: окно выросло — стало видно больше строк. }
  MaybeLoadMore;
end;

{ ---------------- отрисовка ---------------- }

procedure TFrameChats.GridDrawCell(Sender: TObject; ACol, ARow: integer;
  ARect: TRect; AState: TGridDrawState);
var
  R: TChatRow;
  Cv: TCanvas;
  Bmp: TBGRABitmap;
  Y, BadgeW, TextRight: integer;
  Sel: boolean;
  S: string;
begin
  { FCache создаётся в теле конструктора, то есть уже после стриминга.
    Если сетка успеет запросить отрисовку раньше — здесь nil. }
  if (not FReady) or (FCache = nil) then begin
    Exit;
  end;
  R := TdChatList[ARow];
  Cv := Grid.Canvas;

  Sel := gdSelected in AState;
  if Sel then begin
    Cv.Brush.Color := clHighlight;
  end else begin
    Cv.Brush.Color := clWindow;
  end;
  Cv.Brush.Style := bsSolid;
  Cv.FillRect(ARect);

  if R = nil then begin
    Exit;
  end;

  { Аватарку просим только для строк, которые реально рисуются, —
    это и есть ленивость: качается лишь видимое. }
  TdChatList.EnsureAvatar(R);
  Bmp := FCache.Get(R);
  if Bmp <> nil then begin
    { Opaque=False — смешивание по альфе поверх уже залитого фона.
      Именно это даёт мягкий край на любом фоне, включая выделение. }
    Bmp.Draw(Cv, ARect.Left + AV_LEFT,
             ARect.Top + (ROW_HEIGHT - AVATAR_SIZE) div 2, False);
  end;

  TextRight := ARect.Right - PAD;

  { Счётчик непрочитанных справа. }
  if (R.UnreadCount > 0) or R.IsMarkedAsUnread then begin
    if R.UnreadCount > 0 then begin
      S := IntToStr(R.UnreadCount);
    end else begin
      S := ' ';
    end;
    Cv.Font.Style := [fsBold];
    Cv.Font.Height := -11;
    BadgeW := Cv.TextWidth(S) + 12;
    if BadgeW < BADGE_H then begin
      BadgeW := BADGE_H;
    end;
    Y := ARect.Top + (ROW_HEIGHT - BADGE_H) div 2;
    Cv.Brush.Color := clHighlight;
    Cv.Pen.Color := clHighlight;
    Cv.RoundRect(TextRight - BadgeW, Y, TextRight, Y + BADGE_H, BADGE_H, BADGE_H);
    Cv.Brush.Style := bsClear;
    Cv.Font.Color := clWindow;
    Cv.TextOut(TextRight - BadgeW + (BadgeW - Cv.TextWidth(S)) div 2,
               Y + (BADGE_H - Cv.TextHeight(S)) div 2, S);
    Dec(TextRight, BadgeW + 6);
  end;

  Cv.Brush.Style := bsClear;

  { Заголовок. }
  Cv.Font.Style := [fsBold];
  Cv.Font.Height := -13;
  if Sel then begin
    Cv.Font.Color := clHighlightText;
  end else begin
    Cv.Font.Color := clWindowText;
  end;
  S := string(R.Title);
  if R.IsPinned then begin
    S := '📌 ' + S;
  end;
  Cv.TextRect(Rect(ARect.Left + TEXT_LEFT, ARect.Top + 8, TextRight, ARect.Top + 26),
              ARect.Left + TEXT_LEFT, ARect.Top + 8, S);

  { Превью последнего сообщения. }
  Cv.Font.Style := [];
  Cv.Font.Height := -12;
  if Sel then begin
    Cv.Font.Color := clHighlightText;
  end else begin
    Cv.Font.Color := clGrayText;
  end;
  S := string(R.LastText);
  if R.LastIsOutgoing and (S <> '') then begin
    S := 'Вы: ' + S;
  end;
  Cv.TextRect(Rect(ARect.Left + TEXT_LEFT, ARect.Top + 29, TextRight, ARect.Top + 48),
              ARect.Left + TEXT_LEFT, ARect.Top + 29, S);
end;

{ ---------------- выбор и меню ---------------- }

function TFrameChats.CurrentRow: TChatRow;
begin
  Result := TdChatList[Grid.Row];
end;

procedure TFrameChats.GridSelectCell(Sender: TObject; ACol, ARow: integer;
  var CanSelect: boolean);
begin
  CanSelect := True;
  if not FReady then begin
    Exit;
  end;
  if Assigned(FOnSelect) then begin
    FOnSelect(Self, TdChatList[ARow]);
  end;
end;

procedure TFrameChats.GridContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: boolean);
var
  C, R: integer;
begin
  if (not FReady) or (Grid = nil) then begin
    Handled := True;
    Exit;
  end;
  Grid.MouseToCell(MousePos.X, MousePos.Y, C, R);
  if (R < 0) or (R >= TdChatList.Count) then begin
    Handled := True;
    Exit;
  end;
  Grid.Row := R;
  FMenuRow := TdChatList[R];
  BuildMenu(FMenuRow);
end;

procedure TFrameChats.BuildMenu(ARow: TChatRow);

  procedure Add(const ACaption: string; ATag: integer);
  var
    MI: TMenuItem;
  begin
    MI := TMenuItem.Create(mnuChat);
    MI.Caption := ACaption;
    MI.Tag := ATag;
    MI.OnClick := @MenuItemClick;
    mnuChat.Items.Add(MI);
  end;

begin
  { Меню строится заново под конкретный чат: набор пунктов зависит
    от его типа и состояния. }
  mnuChat.Items.Clear;
  if ARow = nil then begin
    Exit;
  end;

  Add(string(ARow.Title), 0);
  mnuChat.Items[0].Enabled := False;
  Add('-', 0);

  if ARow.UnreadCount > 0 then begin
    Add('Отметить прочитанным', 1);
  end else begin
    Add('Отметить непрочитанным', 2);
  end;

  if ARow.IsPinned then begin
    Add('Открепить', 4);
  end else begin
    Add('Закрепить', 3);
  end;

  Add('-', 0);
  Add('Копировать id (' + IntToStr(ARow.Id) + ')', 5);

  if ARow.Kind in [ckSupergroup, ckChannel] then begin
    Add('-', 0);
    Add('Покинуть', 6);
  end;
end;

procedure TFrameChats.MenuItemClick(Sender: TObject);
begin
  if FMenuRow = nil then begin
    Exit;
  end;
  { Действия появятся следующим шагом — сейчас каркас меню. }
  case TMenuItem(Sender).Tag of
    1: ;
    2: ;
    3: ;
    4: ;
    5: ;
    6: ;
  end;
end;

end.
