unit mediaviewer;

{$mode objfpc}{$H+}

{ Built-in full-screen photo/video viewer: clicking a photo/video in the
  chat opens this panel instead of the system viewer (photo) or nothing
  (video — there used to be no "bigger" view at all, only inline
  play/pause).

  One instance for the whole application (TFormMain.MediaViewer),
  parented to the main form itself, covering its entire client rect. In
  the normal state Visible=False — LCL doesn't paint or dispatch
  mouse/keyboard to a hidden control at all, which is enough for
  "transparent to the cursor until activated" (the equivalent of
  pointer-events:none) without any extra tricks.

  Photo display uses its own path, independent of TPhotoWidget: that
  widget always fits its preview into PHOTO_MAX_WIDTH/HEIGHT (the small
  cap for an inline chat card), even given a larger AMaxW — see its
  ComputePhotoPreviewSize (msglayout.pas), which is not reused here for
  the same reason. Instead, the same reusable TPhotoDecodeThread
  (photodecoder.pas, already able to decode+resample in a background
  thread to any explicitly given size) is used, but with a target size
  computed from the VIEWER WINDOW's size (FitToBox below, with no upper
  cap at all — it only avoids upscaling small photos past their natural
  size, the same principle already used for the inline chat preview).
  The ORIGINAL is shown (PhotoBestLocalPath), not the inline-preview
  copy.

  Video reuses TVideoWidget (framehistory.pas) wholesale — the same
  look/play/pause/seek controls as in the chat, but through a new
  SetVideoSized (also bypassing ComputePhotoPreviewSize/the AMaxW cap —
  see its comment in framehistory.pas). Playback uses its OWN,
  independent TMediaPlayer (mediaplayer.pas) — inline video playback in
  the chat no longer exists at all (see framehistory.pas,
  TMsgScroller.VideoBodyClick/VideoPlayClick — the widget there is now
  just a clickable preview with no player of its own), so this player
  is the only one in the whole application and has nothing to conflict
  with. The scheme (one active player, FDonePlayer/WaitFor — don't free
  a TThread from inside its own Synchronize, StopPlayback before Free)
  is the same one the chat used to hold for its own (now removed)
  inline player, just scaled down to a single slot here (the viewer
  only ever shows one video at a time) rather than a widget pool. }

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
    FPlaybackImages: TImageList;
    FAudioDeviceName: utf8string;

    { Photo }
    FPhotoBmp: TBGRABitmap;
    FPhotoW, FPhotoH: integer;
    FDecodeThread: TPhotoDecodeThread;
    FHasPrev, FHasNext: boolean;
    { Same idea, for video — its own pair, not shared with photo
      (different Kind, different scan over FModel, see
      FindAdjacentVideoId). }
    FHasPrevVideo, FHasNextVideo: boolean;

    { Video — a single slot, not a pool (see the unit header). }
    FVideoWidget: TVideoWidget;
    FPlayer: TMediaPlayer;
    FDonePlayer: TMediaPlayer;
    FVideoTimer: TTimer;
    FVideoFrameKnownVersion: cardinal;

    { Polls "has the file finished downloading?" while
      EnsurePhotoBestFile/EnsureVideoFile run asynchronously.
      TTdMessages.OnChanged is a single-listener TNotifyEvent already
      claimed by the chat's TMsgScroller (the same limitation
      documented for TdChatList.OnChanged) — subscribing to it here
      too isn't possible without disturbing the existing chain. Plain
      polling instead is cheap and adds no new coupling to the rest of
      the code. }
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
    { Video transport buttons (TVideoWidget, framehistory.pas). Prev/next
      use the same approach as photo (FindAdjacentPhotoId/NavigatePhoto),
      a separate copy for mckVideo (see the comment on FHasPrevVideo).
      Repeat reads/writes TVideoWidget.RepeatMode (three states — off/
      repeat-all/repeat-one); the auto-action on reaching the end is in
      VideoPlayerStateChanged. }
    procedure UpdateVideoNavFlags(ACurrentId: Int64);
    function FindAdjacentVideoId(AFromId: Int64; ADirection: integer): Int64;
    { "Repeat all" advances to the next video in the chat, wrapping back
      to the first once the last one is reached (a looping scan), not
      just "next or nothing" like the plain NavigateVideo/prev-next. }
    function FindWrappedNextVideoId(AFromId: Int64): Int64;
    procedure NavigateVideo(ADirection: integer);
    procedure VideoWidgetPrevClick(Sender: TObject);
    procedure VideoWidgetNextClick(Sender: TObject);
    procedure VideoWidgetRepeatClick(Sender: TObject);

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
    { Single entry point — resolves photo/video itself from ARow.Kind.
      AImages is the ImageList with play/pause frames for the embedded
      TVideoWidget (the same list the chat already uses, see
      TMsgScroller.FAudioImages) — unused for photos, safe to always
      pass the same list. APlaybackImages is the transport-button row
      under the scrub bar (TMsgScroller.FPlaybackImages) — same
      approach, also unused for photos. AAudioDeviceName mirrors
      FormMain.AudioDeviceName, passed explicitly the same way so this
      unit doesn't need to import main.pas (which would create a
      circular dependency). }
    procedure ShowMessage(AModel: TTdMessages; AMessageId: Int64;
      AImages, APlaybackImages: TImageList; const AAudioDeviceName: utf8string = '');
    procedure CloseViewer;
  end;

implementation

const
  MVIEW_MARGIN = 48;
  { Buttons are real ImageList1 icons (VIEWER_ICON_*, constants.pas),
    not a hand-drawn text glyph in a circle — button size matches
    AUDIO_BUTTON_SIZE, the same size as the icons themselves. }
  MVIEW_BTN    = AUDIO_BUTTON_SIZE;

{ Fits a natural size into a box, PRESERVING proportions, with NO
  upscaling past the natural size (Scale never exceeds 1) — unlike
  ComputePhotoPreviewSize (msglayout.pas), which always has a fixed
  upper cap of PHOTO_MAX_WIDTH/HEIGHT: there is no such cap here, the
  available area is the real viewer window size, not a chat row's
  width. }
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
  { No rounding and no outline — matches the chat now (see
    TVideoWidget.Paint; the Rounded property was removed entirely, both
    sides paint the same way). }
  FVideoWidget.OnPlayClick := @VideoWidgetPlayClick;
  FVideoWidget.OnSeek := @VideoWidgetSeek;
  FVideoWidget.OnPrevClick := @VideoWidgetPrevClick;
  FVideoWidget.OnNextClick := @VideoWidgetNextClick;
  FVideoWidget.OnRepeatClick := @VideoWidgetRepeatClick;

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

{ ---------------- geometry / drawing ---------------- }

procedure TMediaViewerPanel.Layout;
begin
  { MVIEW_BTN = AUDIO_BUTTON_SIZE (32) — the same ImageList1 frames as
    play/pause/download on the audio/video widgets, see VIEWER_ICON_*
    (constants.pas) — the hit area matches the icon size exactly, no
    extra margin. }
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

{ Icons from ImageList1 (framehistory.TFrameHistory), the same list
  that provides play/pause/download for the audio/video widgets in the
  chat — extended with three more frames (VIEWER_ICON_PREV/NEXT/CLOSE,
  constants.pas) specifically for the viewer. No backing is drawn
  behind them (the same approach as play/pause in TAudioWidget/
  TVideoWidget — the icon itself is already self-sufficient). }
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
          { A real size change — restart the player at the new
            resolution (swscale inside TMediaPlayer decodes into a
            FIXED size chosen at Create time, an already-decoded frame
            can't just be stretched) from the same position, the same
            approach used for an ordinary seek (VideoWidgetSeek). }
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

{ ---------------- input ---------------- }

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
      { A click on the image itself does nothing (doesn't close, doesn't
        navigate) — the same choice most viewers make. }
      Exit;
    end;
  end;
  { A click on the black background (or, in video mode, anything
    outside the embedded TVideoWidget — that widget handles its own
    clicks, they never reach here) closes the viewer. }
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

{ ---------------- photo ---------------- }

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

{ ---------------- video ---------------- }

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
  FVideoWidget.PlaybackImages := FPlaybackImages;
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
var
  Idx: integer;
  NewId: Int64;
begin
  if (Sender = FPlayer) and ((FPlayer.State = mpsStopped) or (FPlayer.State = mpsError)) then begin
    if (FPlayer.State = mpsStopped) and (FVideoWidget <> nil) and (FModel <> nil) then begin
      { Repeat (the transport-row button, TVideoWidget.RepeatMode, three
        states) acts on its own when the file naturally ends, WITHOUT
        resetting to the "stopped" state — the same path as an ordinary
        play click after stopping (VideoWidgetPlayClick). Only for a
        real end of file (mpsStopped), not mpsError — no point looping
        or auto-advancing past a decode error. Calling
        StartVideoPlayer/OpenRow directly here is safe: we're inside
        FPlayer's own Synchronize, but StopVideoInternal inside them
        only moves FPlayer into FDonePlayer (WaitFor/Free is deferred
        to the next tick/call, not done now) — the same approach used
        throughout this file. }
      case FVideoWidget.RepeatMode of
        vrmOne: begin
          { Repeat one — the same file again. }
          Idx := FModel.IndexOfId(FMessageId);
          if Idx >= 0 then begin
            StartVideoPlayer(FModel[Idx]);
            Exit;
          end;
        end;
        vrmAll: begin
          { Repeat all — the next video in the chat, wrapping to the
            first one after the last (FindWrappedNextVideoId). }
          NewId := FindWrappedNextVideoId(FMessageId);
          if NewId <> 0 then begin
            Idx := FModel.IndexOfId(NewId);
            if Idx >= 0 then begin
              FMessageId := NewId;
              OpenRow(FModel[Idx]);
              Exit;
            end;
          end;
        end;
      end;
      { vrmOff — do nothing, plays through to the ordinary stop below. }
    end;
    FDonePlayer := FPlayer;
    FPlayer := nil;
    FVideoTimer.Enabled := False;
    { Without this the widget would stay forever in whatever state
      VideoTick last set BEFORE stopping (FIsActive=True, FPlaying=True
      — the last tick before the timer above got disabled) — a frozen
      frame that still looks like it's "playing", and clicking
      play/pause would do nothing (VideoWidgetPlayClick returns
      immediately when FPlayer=nil) — the actual cause of "doesn't
      restart", separate from the end-of-playback stall itself (see
      AudioClockSec/mediaplayer.pas). Resetting to the inactive state
      matches how not-yet-started video looks, and VideoWidgetPlayClick
      now restarts playback from scratch when FPlayer=nil. }
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
  { Same guard against "dragging gets reset on the very next tick" as
    LayoutVideoWidgets/LayoutAudioWidgets (framehistory.pas) — this
    tick fires every 33ms, more often than the user can finish
    dragging the thumb down to MouseUp. }
  if (FVideoWidget <> nil) and (not FVideoWidget.Dragging) then begin
    FVideoWidget.SetPlayback(True, FPlayer.State = mpsPlaying, FPlayer.PositionSec);
  end;
end;

procedure TMediaViewerPanel.VideoWidgetPlayClick(Sender: TObject);
var
  Idx: integer;
begin
  if FPlayer = nil then begin
    { Already finished naturally (see VideoPlayerStateChanged) — a play
      click should restart from the beginning, not be a no-op, the same
      path as opening the video for the first time (StartVideoPlayer). }
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

{ Prev/next video — the same scheme as FindAdjacentPhotoId/NavigatePhoto
  above, a separate copy for mckVideo (see the comment on
  FHasPrevVideo: different Kind, different scan over FModel — separate
  copies are easier to read than one function parameterized by kind). }
function TMediaViewerPanel.FindAdjacentVideoId(AFromId: Int64; ADirection: integer): Int64;
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
    if FModel[Idx].Kind = mckVideo then begin
      Result := FModel[Idx].Id;
      Exit;
    end;
    Inc(Idx, ADirection);
  end;
end;

function TMediaViewerPanel.FindWrappedNextVideoId(AFromId: Int64): Int64;
var
  I: integer;
begin
  Result := FindAdjacentVideoId(AFromId, 1);
  if (Result <> 0) or (FModel = nil) then begin
    Exit;
  end;
  { Reached the last video in the chat (or there is none after this
    one) — "repeat all" wraps back to the first rather than stopping.
    If there's only one video in the chat, this finds AFromId itself,
    which degenerates to "repeat one" — exactly the expected behavior
    for a single-item playlist. }
  for I := 0 to FModel.Count - 1 do begin
    if FModel[I].Kind = mckVideo then begin
      Result := FModel[I].Id;
      Exit;
    end;
  end;
end;

procedure TMediaViewerPanel.UpdateVideoNavFlags(ACurrentId: Int64);
begin
  FHasPrevVideo := FindAdjacentVideoId(ACurrentId, -1) <> 0;
  FHasNextVideo := FindAdjacentVideoId(ACurrentId, 1) <> 0;
  if FVideoWidget <> nil then begin
    FVideoWidget.HasPrevVideo := FHasPrevVideo;
    FVideoWidget.HasNextVideo := FHasNextVideo;
  end;
end;

procedure TMediaViewerPanel.NavigateVideo(ADirection: integer);
var
  NewId: Int64;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  NewId := FindAdjacentVideoId(FMessageId, ADirection);
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

procedure TMediaViewerPanel.VideoWidgetPrevClick(Sender: TObject);
begin
  NavigateVideo(-1);
end;

procedure TMediaViewerPanel.VideoWidgetNextClick(Sender: TObject);
begin
  NavigateVideo(1);
end;

procedure TMediaViewerPanel.VideoWidgetRepeatClick(Sender: TObject);
begin
  if FVideoWidget = nil then begin
    Exit;
  end;
  { Cyclic toggle — off -> repeat all -> repeat one -> off again. A
    sticky toggle for the whole viewer session, not reset when switching
    between videos (see the comment on TVideoWidget.RepeatMode) — the
    auto-action on reaching the end reads this same field, see
    VideoPlayerStateChanged. }
  case FVideoWidget.RepeatMode of
    vrmOff: FVideoWidget.RepeatMode := vrmAll;
    vrmAll: FVideoWidget.RepeatMode := vrmOne;
  else
    FVideoWidget.RepeatMode := vrmOff;
  end;
  FVideoWidget.Invalidate;
end;

{ ---------------- shared ---------------- }

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
      UpdateVideoNavFlags(ARow.Id);
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
  AImages, APlaybackImages: TImageList; const AAudioDeviceName: utf8string);
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
  FPlaybackImages := APlaybackImages;
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
