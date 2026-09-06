unit mediaviewer;

{$mode objfpc}{$H+}

{ Встроенный полноэкранный просмотрщик фото/видео — по прямому запросу
  пользователя (2026-09-06), вместе с уменьшением инлайн-превью в чате:
  клик по фото/видео теперь открывает ЭТУ панель вместо системного
  просмотрщика (фото) или ничего (видео — раньше отдельного "покрупнее"
  не было, только инлайн play/pause).

  Один экземпляр на всё приложение (TFormMain.MediaViewer), родитель —
  сама главная форма, во весь её клиентский прямоугольник. В обычном
  состоянии Visible=False — LCL не рисует и не диспетчерит мышь/клавиши
  невидимому контролу вовсе, этого достаточно для "прозрачна для
  курсора, пока не активирована" (аналог pointer-events:none) без
  каких-либо доп. трюков.

  Фото — свой, независимый от TPhotoWidget путь показа: тот вписывает
  превью в PHOTO_MAX_WIDTH/HEIGHT (маленький потолок инлайн-карточки в
  чате) ВСЕГДА, даже если передать больший AMaxW — см. её же
  ComputePhotoPreviewSize (msglayout.pas), она не переиспользуется
  здесь по этой же причине. Вместо этого — тот же переиспользуемый
  TPhotoDecodeThread (photodecoder.pas, уже умеет декод+ресемпл в
  фоновом потоке в ЛЮБОЙ явно заданный размер), но целевой размер
  считается от размера ОКНА просмотрщика (FitToBox ниже, без верхнего
  потолка вовсе — только не увеличивает маленькие фото сверх
  натурального размера, тот же принцип, что уже принят у превью в
  чате). Показывается ОРИГИНАЛ (PhotoBestLocalPath), не инлайн-превью.

  Видео — переиспользован TVideoWidget (framehistory.pas) целиком, тот
  же внешний вид/контролы play/pause/seek, что и в чате, но через новый
  SetVideoSized (тоже в обход ComputePhotoPreviewSize/AMaxW-потолка —
  см. её комментарий в framehistory.pas). Проигрывание — СВОЙ,
  независимый TMediaPlayer (mediaplayer.pas) — инлайн-проигрывания видео
  в чате больше нет вовсе (по прямому запросу пользователя, 2026-09-06;
  см. framehistory.pas, TMsgScroller.VideoBodyClick/VideoPlayClick — там
  виджет теперь просто кликабельное превью, своего плеера не имеет), так
  что этот плеер — единственный на всё приложение, конфликтовать не с
  чем. Схема (один активный плеер, FDonePlayer/WaitFor — не освобождать
  TThread изнутри его же Synchronize, StopPlayback перед Free) — та же,
  что раньше держал чат для своего (ныне убранного) инлайн-плеера, здесь
  — на один слот (в просмотрщике одновременно показывается только одно
  видео), а не на пул виджетов. }

interface

uses
  Classes, SysUtils, Types, Math, Controls, Forms, Graphics, ExtCtrls, LCLType,
  BGRABitmap, BGRABitmapTypes, constants, tdmessages, framehistory, mediaplayer,
  photodecoder;

type
  TMediaViewerKind = (mvkNone, mvkPhoto, mvkVideo);

  TMediaViewerPanel = class(TCustomControl)
  private
    FModel: TTdMessages;
    FKind: TMediaViewerKind;
    FMessageId: Int64;
    FImages: TImageList;
    FAudioDeviceName: utf8string;

    { Фото }
    FPhotoBmp: TBGRABitmap;
    FPhotoW, FPhotoH: integer;
    FDecodeThread: TPhotoDecodeThread;
    FHasPrev, FHasNext: boolean;

    { Видео — один слот, не пул (см. шапку юнита). }
    FVideoWidget: TVideoWidget;
    FPlayer: TMediaPlayer;
    FDonePlayer: TMediaPlayer;
    FVideoTimer: TTimer;
    FVideoFrameKnownVersion: cardinal;

    { Опрос "файл уже докачался?" — пока EnsurePhotoBestFile/
      EnsureVideoFile отрабатывают асинхронно; TTdMessages.OnChanged —
      однослушательский TNotifyEvent, уже занят TMsgScroller чата (тот
      же класс ограничения, что документирован для TdChatList.OnChanged
      в CLAUDE.md) — подписаться на него так же нельзя, не толкая
      существующую цепочку. Простой поллинг вместо этого — дёшево,
      никаких новых точек связи с остальным кодом. }
    FPollTimer: TTimer;

    FCloseBtnRect, FPrevBtnRect, FNextBtnRect: TRect;

    procedure Layout;
    procedure GetAvailArea(out AW, AH: integer);
    function PhotoRect: TRect;
    procedure DrawIconButton(const ARect: TRect; AIconIndex: integer);

    procedure OpenRow(ARow: TMsgRow);
    procedure ClearPhoto;
    procedure StartPhotoDecode(ARow: TMsgRow);
    procedure PhotoDecodeDone(Sender: TObject);
    procedure UpdateNavFlags(ACurrentId: Int64);
    procedure NavigatePhoto(ADirection: integer);
    function FindAdjacentPhotoId(AFromId: Int64; ADirection: integer): Int64;

    procedure StopVideoInternal;
    procedure FlushDonePlayer;
    procedure StartVideoPlayer(ARow: TMsgRow; AStartPositionSec: double = 0);
    procedure VideoPlayerStateChanged(Sender: TObject);
    procedure VideoTick(Sender: TObject);
    procedure VideoWidgetPlayClick(Sender: TObject);
    procedure VideoWidgetSeek(Sender: TObject; AFraction: double);

    procedure PollTick(Sender: TObject);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: integer); override;
    procedure KeyDown(var Key: word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Единая точка входа — сама решает фото/видео по ARow.Kind.
      AImages — ImageList с кадрами play/pause для встроенного
      TVideoWidget (тот же список, что уже использует чат, см.
      TMsgScroller.FAudioImages) — для фото не используется, безопасно
      передать тот же список всегда. AAudioDeviceName — см.
      FormMain.AudioDeviceName, тем же приёмом передаётся явно, чтобы
      этот юнит не тянул main.pas (циклическая зависимость). }
    procedure ShowMessage(AModel: TTdMessages; AMessageId: Int64;
      AImages: TImageList; const AAudioDeviceName: utf8string = '');
    procedure CloseViewer;
  end;

implementation

const
  MVIEW_MARGIN = 48;
  { Кнопки — теперь настоящие значки ImageList1 (VIEWER_ICON_*,
    constants.pas), не рисованный текст-глиф в кружке — размер кнопки
    ровно AUDIO_BUTTON_SIZE, тот же, что и у самих значков. }
  MVIEW_BTN    = AUDIO_BUTTON_SIZE;

{ Вписывает натуральный размер в бокс, СОХРАНЯЯ пропорции, БЕЗ
  увеличения сверх натурального (Scale никогда не растёт выше 1) — в
  отличие от ComputePhotoPreviewSize (msglayout.pas), у которой всегда
  есть фиксированный верхний потолок PHOTO_MAX_WIDTH/HEIGHT: здесь его
  нет вовсе, доступная область — это реальный размер окна просмотрщика,
  не размер строки в чате. }
procedure FitToBox(ANatW, ANatH, AMaxW, AMaxH: integer; out AOutW, AOutH: integer);
var
  Scale: double;
begin
  if (ANatW <= 0) or (ANatH <= 0) then begin
    AOutW := Max(1, AMaxW);
    AOutH := Max(1, AMaxH);
    Exit;
  end;
  Scale := 1.0;
  if (AMaxW > 0) and (ANatW > AMaxW) then begin
    Scale := Min(Scale, AMaxW / ANatW);
  end;
  if (AMaxH > 0) and (ANatH > AMaxH) then begin
    Scale := Min(Scale, AMaxH / ANatH);
  end;
  AOutW := Max(1, Round(ANatW * Scale));
  AOutH := Max(1, Round(ANatH * Scale));
end;

constructor TMediaViewerPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := clBlack;
  DoubleBuffered := True;
  TabStop := True;
  Visible := False;

  FVideoWidget := TVideoWidget.Create(Self);
  FVideoWidget.Parent := Self;
  FVideoWidget.Visible := False;
  { Без скругления и без обводки — теперь одинаково с чатом (см.
    TVideoWidget.Paint, свойство Rounded убрано целиком, обе стороны
    рисуют одинаково). }
  FVideoWidget.OnPlayClick := @VideoWidgetPlayClick;
  FVideoWidget.OnSeek := @VideoWidgetSeek;

  FVideoTimer := TTimer.Create(Self);
  FVideoTimer.Interval := 33;
  FVideoTimer.OnTimer := @VideoTick;
  FVideoTimer.Enabled := False;

  FPollTimer := TTimer.Create(Self);
  FPollTimer.Interval := 300;
  FPollTimer.OnTimer := @PollTick;
  FPollTimer.Enabled := False;
end;

destructor TMediaViewerPanel.Destroy;
begin
  StopVideoInternal;
  FlushDonePlayer;
  ClearPhoto;
  inherited Destroy;
end;

{ ---------------- геометрия/рисование ---------------- }

procedure TMediaViewerPanel.Layout;
begin
  { MVIEW_BTN = AUDIO_BUTTON_SIZE (32) — те же кадры ImageList1, что и
    play/pause/download у аудио/видео-виджетов, см. VIEWER_ICON_*
    (constants.pas) — хит-зона кнопки ровно под размер значка, без
    лишнего запаса. }
  FCloseBtnRect := Rect(ClientWidth - MVIEW_BTN - 12, 12, ClientWidth - 12, 12 + MVIEW_BTN);
  FPrevBtnRect := Rect(12, (ClientHeight - MVIEW_BTN) div 2,
    12 + MVIEW_BTN, (ClientHeight - MVIEW_BTN) div 2 + MVIEW_BTN);
  FNextBtnRect := Rect(ClientWidth - MVIEW_BTN - 12, (ClientHeight - MVIEW_BTN) div 2,
    ClientWidth - 12, (ClientHeight - MVIEW_BTN) div 2 + MVIEW_BTN);
end;

procedure TMediaViewerPanel.GetAvailArea(out AW, AH: integer);
begin
  AW := Max(50, ClientWidth - 2 * MVIEW_MARGIN);
  AH := Max(50, ClientHeight - 2 * MVIEW_MARGIN);
end;

function TMediaViewerPanel.PhotoRect: TRect;
var
  X, Y: integer;
begin
  X := (ClientWidth - FPhotoW) div 2;
  Y := (ClientHeight - FPhotoH) div 2;
  Result := Rect(X, Y, X + FPhotoW, Y + FPhotoH);
end;

{ Значки из ImageList1 (framehistory.TFrameHistory), тот же список, что
  play/pause/download у аудио/видео-виджетов в чате — пользователь
  добавил в него ещё три кадра (VIEWER_ICON_PREV/NEXT/CLOSE,
  constants.pas) специально под просмотрщик. По прямому запросу
  пользователя заменили рисованный текст-глиф в кружке (первая версия)
  на настоящие значки — не рисуем никакой подложки под ними (тот же
  приём, что и у play/pause в TAudioWidget/TVideoWidget — сам значок
  уже полностью самодостаточен). }
procedure TMediaViewerPanel.DrawIconButton(const ARect: TRect; AIconIndex: integer);
begin
  if (FImages = nil) or (AIconIndex < 0) or (AIconIndex >= FImages.Count) then begin
    Exit;
  end;
  FImages.Draw(Canvas, ARect.Left, ARect.Top, AIconIndex, True);
end;

procedure TMediaViewerPanel.Paint;
var
  PR: TRect;
  S: string;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clBlack;
  Canvas.FillRect(ClientRect);

  case FKind of
    mvkPhoto: begin
      if FPhotoBmp <> nil then begin
        PR := PhotoRect;
        FPhotoBmp.Draw(Canvas, PR.Left, PR.Top, False);
      end else begin
        S := 'Loading…';
        Canvas.Brush.Style := bsClear;
        Canvas.Font.Color := clWhite;
        Canvas.TextOut((ClientWidth - Canvas.TextWidth(S)) div 2,
          (ClientHeight - Canvas.TextHeight(S)) div 2, S);
      end;
      if FHasPrev then begin
        DrawIconButton(FPrevBtnRect, VIEWER_ICON_PREV);
      end;
      if FHasNext then begin
        DrawIconButton(FNextBtnRect, VIEWER_ICON_NEXT);
      end;
    end;
    mvkVideo: begin
      if (FVideoWidget = nil) or (not FVideoWidget.Visible) then begin
        S := 'Loading…';
        Canvas.Brush.Style := bsClear;
        Canvas.Font.Color := clWhite;
        Canvas.TextOut((ClientWidth - Canvas.TextWidth(S)) div 2,
          (ClientHeight - Canvas.TextHeight(S)) div 2, S);
      end;
    end;
  end;

  DrawIconButton(FCloseBtnRect, VIEWER_ICON_CLOSE);
end;

procedure TMediaViewerPanel.Resize;
var
  Idx: integer;
  Row: TMsgRow;
  AvailW, AvailH, TgtW, TgtH: integer;
  Pos: double;
begin
  inherited Resize;
  Layout;
  if (not Visible) or (FModel = nil) then begin
    Exit;
  end;
  Idx := FModel.IndexOfId(FMessageId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];
  case FKind of
    mvkPhoto: begin
      if FPhotoBmp <> nil then begin
        StartPhotoDecode(Row);
      end;
    end;
    mvkVideo: begin
      if (FPlayer <> nil) and (FVideoWidget <> nil) then begin
        GetAvailArea(AvailW, AvailH);
        FitToBox(Row.VideoWidth, Row.VideoHeight, AvailW, AvailH, TgtW, TgtH);
        if (Abs(TgtW - FVideoWidget.TargetWidth) > 10) or (Abs(TgtH - FVideoWidget.TargetHeight) > 10) then begin
          { Реальная смена размера — перезапускаем плеер под новое
            разрешение (swscale внутри TMediaPlayer декодирует в
            ФИКСИРОВАННЫЙ на момент Create размер, "просто растянуть"
            уже готовый кадр нельзя) с той же позиции, тем же приёмом,
            что и обычная перемотка (VideoWidgetSeek). }
          Pos := FPlayer.PositionSec;
          StartVideoPlayer(Row, Pos);
        end else begin
          FVideoWidget.SetBounds((ClientWidth - FVideoWidget.TargetWidth) div 2,
            (ClientHeight - FVideoWidget.TargetHeight) div 2,
            FVideoWidget.TargetWidth, FVideoWidget.TargetHeight);
        end;
      end;
    end;
  end;
end;

{ ---------------- ввод ---------------- }

procedure TMediaViewerPanel.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  P: TPoint;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then begin
    Exit;
  end;
  P := Point(X, Y);
  if PtInRect(FCloseBtnRect, P) then begin
    CloseViewer;
    Exit;
  end;
  if FKind = mvkPhoto then begin
    if FHasPrev and PtInRect(FPrevBtnRect, P) then begin
      NavigatePhoto(-1);
      Exit;
    end;
    if FHasNext and PtInRect(FNextBtnRect, P) then begin
      NavigatePhoto(1);
      Exit;
    end;
    if (FPhotoBmp <> nil) and PtInRect(PhotoRect, P) then begin
      { Клик по самому изображению — ничего не делает (не закрывать,
        не листать) — тот же выбор, что у большинства просмотрщиков. }
      Exit;
    end;
  end;
  { Клик по чёрному фону (или, в режиме видео, по чему угодно за
    пределами встроенного TVideoWidget — тот сам разбирает клики по
    себе, сюда они не долетают) — закрыть. }
  CloseViewer;
end;

procedure TMediaViewerPanel.MouseMove(Shift: TShiftState; X, Y: integer);
var
  P: TPoint;
  OverBtn: boolean;
begin
  inherited MouseMove(Shift, X, Y);
  P := Point(X, Y);
  OverBtn := PtInRect(FCloseBtnRect, P) or
    ((FKind = mvkPhoto) and FHasPrev and PtInRect(FPrevBtnRect, P)) or
    ((FKind = mvkPhoto) and FHasNext and PtInRect(FNextBtnRect, P));
  if OverBtn then begin
    Cursor := crHandPoint;
  end else begin
    Cursor := crDefault;
  end;
end;

procedure TMediaViewerPanel.KeyDown(var Key: word; Shift: TShiftState);
begin
  case Key of
    VK_ESCAPE: begin
      CloseViewer;
      Key := 0;
    end;
    VK_LEFT: begin
      if (FKind = mvkPhoto) and FHasPrev then begin
        NavigatePhoto(-1);
        Key := 0;
      end;
    end;
    VK_RIGHT: begin
      if (FKind = mvkPhoto) and FHasNext then begin
        NavigatePhoto(1);
        Key := 0;
      end;
    end;
  end;
  inherited KeyDown(Key, Shift);
end;

{ ---------------- фото ---------------- }

procedure TMediaViewerPanel.ClearPhoto;
begin
  if FDecodeThread <> nil then begin
    FDecodeThread.Cancel;
    FDecodeThread := nil;
  end;
  FreeAndNil(FPhotoBmp);
  FPhotoW := 0;
  FPhotoH := 0;
end;

procedure TMediaViewerPanel.StartPhotoDecode(ARow: TMsgRow);
var
  AvailW, AvailH, TgtW, TgtH: integer;
begin
  if FDecodeThread <> nil then begin
    FDecodeThread.Cancel;
    FDecodeThread := nil;
  end;
  GetAvailArea(AvailW, AvailH);
  FitToBox(ARow.PhotoWidth, ARow.PhotoHeight, AvailW, AvailH, TgtW, TgtH);
  FDecodeThread := TPhotoDecodeThread.Create(ARow.PhotoBestLocalPath, TgtW, TgtH, @PhotoDecodeDone);
end;

procedure TMediaViewerPanel.PhotoDecodeDone(Sender: TObject);
begin
  FreeAndNil(FPhotoBmp);
  FPhotoBmp := TPhotoDecodeThread(Sender).TakeResult;
  if FPhotoBmp <> nil then begin
    FPhotoW := FPhotoBmp.Width;
    FPhotoH := FPhotoBmp.Height;
  end;
  FDecodeThread := nil;
  Invalidate;
end;

function TMediaViewerPanel.FindAdjacentPhotoId(AFromId: Int64; ADirection: integer): Int64;
var
  Idx: integer;
begin
  Result := 0;
  if FModel = nil then begin
    Exit;
  end;
  Idx := FModel.IndexOfId(AFromId);
  if Idx < 0 then begin
    Exit;
  end;
  Inc(Idx, ADirection);
  while (Idx >= 0) and (Idx < FModel.Count) do begin
    if FModel[Idx].Kind = mckPhoto then begin
      Result := FModel[Idx].Id;
      Exit;
    end;
    Inc(Idx, ADirection);
  end;
end;

procedure TMediaViewerPanel.UpdateNavFlags(ACurrentId: Int64);
begin
  FHasPrev := FindAdjacentPhotoId(ACurrentId, -1) <> 0;
  FHasNext := FindAdjacentPhotoId(ACurrentId, 1) <> 0;
end;

procedure TMediaViewerPanel.NavigatePhoto(ADirection: integer);
var
  NewId: Int64;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  NewId := FindAdjacentPhotoId(FMessageId, ADirection);
  if NewId = 0 then begin
    Exit;
  end;
  Idx := FModel.IndexOfId(NewId);
  if Idx < 0 then begin
    Exit;
  end;
  FMessageId := NewId;
  OpenRow(FModel[Idx]);
end;

{ ---------------- видео ---------------- }

procedure TMediaViewerPanel.FlushDonePlayer;
begin
  if FDonePlayer <> nil then begin
    FDonePlayer.WaitFor;
    FDonePlayer.Free;
    FDonePlayer := nil;
  end;
end;

procedure TMediaViewerPanel.StopVideoInternal;
begin
  FlushDonePlayer;
  if FPlayer <> nil then begin
    FPlayer.StopPlayback;
    FDonePlayer := FPlayer;
    FPlayer := nil;
  end;
  FVideoTimer.Enabled := False;
  if FVideoWidget <> nil then begin
    FVideoWidget.Visible := False;
  end;
end;

procedure TMediaViewerPanel.StartVideoPlayer(ARow: TMsgRow; AStartPositionSec: double);
var
  AvailW, AvailH, TgtW, TgtH: integer;
begin
  StopVideoInternal;
  GetAvailArea(AvailW, AvailH);
  FitToBox(ARow.VideoWidth, ARow.VideoHeight, AvailW, AvailH, TgtW, TgtH);
  FVideoWidget.Images := FImages;
  FVideoWidget.BackgroundColor := clBlack;
  FVideoWidget.SetVideoSized(ARow.Id, ARow.VideoWidth, ARow.VideoHeight, ARow.VideoThumbLocalPath,
    True, ARow.VideoLocalPath, TgtW, TgtH, ARow.VideoDuration);
  FVideoWidget.SetBounds((ClientWidth - TgtW) div 2, (ClientHeight - TgtH) div 2, TgtW, TgtH);
  FVideoWidget.Visible := True;
  FPlayer := TMediaPlayer.Create(ARow.VideoLocalPath, FAudioDeviceName, TgtW, TgtH, AStartPositionSec);
  FPlayer.OnStateChanged := @VideoPlayerStateChanged;
  FVideoFrameKnownVersion := 0;
  FVideoTimer.Enabled := True;
  FVideoWidget.SetPlayback(True, True, AStartPositionSec);
  Invalidate;
end;

procedure TMediaViewerPanel.VideoPlayerStateChanged(Sender: TObject);
begin
  if (Sender = FPlayer) and ((FPlayer.State = mpsStopped) or (FPlayer.State = mpsError)) then begin
    FDonePlayer := FPlayer;
    FPlayer := nil;
    FVideoTimer.Enabled := False;
    { Без этого виджет оставался бы навсегда в последнем состоянии,
      выставленном VideoTick ДО остановки (FIsActive=True, FPlaying=True
      — тот тик, что был последним перед тем, как таймер выше
      выключился) — застывший кадр с виду "играющего" видео, и клик по
      play/pause ничего не делал (VideoWidgetPlayClick сразу выходит,
      если FPlayer=nil) — реальная причина "не перезапускается" из
      отчёта пользователя (2026-09-07), отдельная от самого зависания
      на хвосте (см. AudioClockSec/mediaplayer.pas). Сброс в неактивное
      состояние — тот же вид, что у ещё не запущенного видео, плюс
      VideoWidgetPlayClick теперь запускает проигрывание заново с нуля,
      если FPlayer=nil. }
    if FVideoWidget <> nil then begin
      FVideoWidget.SetPlayback(False, False, 0);
    end;
  end;
  Invalidate;
end;

procedure TMediaViewerPanel.VideoTick(Sender: TObject);
begin
  FlushDonePlayer;
  if FPlayer = nil then begin
    Exit;
  end;
  if FPlayer.HasVideo and (FVideoWidget <> nil) then begin
    if FPlayer.TryGetFrame(FVideoWidget.FrameBuf, FVideoFrameKnownVersion) then begin
      FVideoWidget.NotifyNewFrame;
    end;
  end;
  { Та же защита от "перетаскивание сбрасывается на следующем же
    тике", что и у LayoutVideoWidgets/LayoutAudioWidgets (framehistory.
    pas) — этот тик дёргается каждые 33мс, чаще, чем пользователь
    успевает довести драг ползунка до MouseUp. }
  if (FVideoWidget <> nil) and (not FVideoWidget.Dragging) then begin
    FVideoWidget.SetPlayback(True, FPlayer.State = mpsPlaying, FPlayer.PositionSec);
  end;
end;

procedure TMediaViewerPanel.VideoWidgetPlayClick(Sender: TObject);
var
  Idx: integer;
begin
  if FPlayer = nil then begin
    { Уже доиграно естественным образом (см. VideoPlayerStateChanged) —
      клик по play должен запускать заново с начала, не быть no-op'ом,
      тем же путём, что и открытие видео впервые (StartVideoPlayer). }
    if FModel = nil then begin
      Exit;
    end;
    Idx := FModel.IndexOfId(FMessageId);
    if Idx < 0 then begin
      Exit;
    end;
    StartVideoPlayer(FModel[Idx]);
    Exit;
  end;
  if FPlayer.State = mpsPlaying then begin
    FPlayer.Pause;
  end else if FPlayer.State = mpsPaused then begin
    FPlayer.Resume;
  end;
  Invalidate;
end;

procedure TMediaViewerPanel.VideoWidgetSeek(Sender: TObject; AFraction: double);
var
  Idx: integer;
  Row: TMsgRow;
begin
  if (FModel = nil) or (FPlayer = nil) then begin
    Exit;
  end;
  Idx := FModel.IndexOfId(FMessageId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];
  if Row.VideoDuration <= 0 then begin
    Exit;
  end;
  StartVideoPlayer(Row, AFraction * Row.VideoDuration);
end;

{ ---------------- общее ---------------- }

procedure TMediaViewerPanel.PollTick(Sender: TObject);
var
  Idx: integer;
  Row: TMsgRow;
begin
  if FModel = nil then begin
    FPollTimer.Enabled := False;
    Exit;
  end;
  Idx := FModel.IndexOfId(FMessageId);
  if Idx < 0 then begin
    FPollTimer.Enabled := False;
    Exit;
  end;
  Row := FModel[Idx];
  case FKind of
    mvkPhoto: begin
      if Row.PhotoBestLocalPath <> '' then begin
        FPollTimer.Enabled := False;
        StartPhotoDecode(Row);
      end;
    end;
    mvkVideo: begin
      if Row.VideoLocalPath <> '' then begin
        FPollTimer.Enabled := False;
        StartVideoPlayer(Row);
      end;
    end;
  end;
end;

procedure TMediaViewerPanel.OpenRow(ARow: TMsgRow);
begin
  FPollTimer.Enabled := False;
  case ARow.Kind of
    mckPhoto: begin
      FKind := mvkPhoto;
      StopVideoInternal;
      ClearPhoto;
      UpdateNavFlags(ARow.Id);
      if ARow.PhotoBestLocalPath = '' then begin
        FModel.EnsurePhotoBestFile(ARow);
        FPollTimer.Enabled := True;
      end else begin
        StartPhotoDecode(ARow);
      end;
    end;
    mckVideo: begin
      FKind := mvkVideo;
      ClearPhoto;
      if ARow.VideoLocalPath = '' then begin
        FModel.EnsureVideoFile(ARow);
        FPollTimer.Enabled := True;
      end else begin
        StartVideoPlayer(ARow);
      end;
    end;
  else
    Exit;
  end;
  Invalidate;
end;

procedure TMediaViewerPanel.ShowMessage(AModel: TTdMessages; AMessageId: Int64;
  AImages: TImageList; const AAudioDeviceName: utf8string);
var
  Idx: integer;
  Row: TMsgRow;
begin
  if AModel = nil then begin
    Exit;
  end;
  Idx := AModel.IndexOfId(AMessageId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := AModel[Idx];
  if not (Row.Kind in [mckPhoto, mckVideo]) then begin
    Exit;
  end;
  FModel := AModel;
  FMessageId := AMessageId;
  FImages := AImages;
  FAudioDeviceName := AAudioDeviceName;
  Layout;
  OpenRow(Row);
  Visible := True;
  BringToFront;
  SetFocus;
end;

procedure TMediaViewerPanel.CloseViewer;
begin
  FPollTimer.Enabled := False;
  StopVideoInternal;
  FlushDonePlayer;
  ClearPhoto;
  FKind := mvkNone;
  FModel := nil;
  FMessageId := 0;
  Visible := False;
end;

end.
