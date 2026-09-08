unit photodecoder;

{$mode objfpc}{$H+}

{ One-shot (not looping, unlike audioplayer.pas/videoplayer.pas)
  background decode of a single photo file: JPEG decode of an already
  downloaded file (TBGRABitmap.Create) and resample to the target
  preview size (BGRAFilters). Runs off the main thread, since decoding
  a full-size JPEG and resampling it is expensive enough to stall
  scrolling if done synchronously when several new photos become
  visible at once.

  The blur placeholder from the minithumbnail (TPhotoWidget.SetPhoto)
  is not moved here — its source is tiny (~30x40), so the cost of
  decoding and blurring it is negligible and does not warrant a
  separate thread. }

interface

uses
  Classes, SysUtils, BGRABitmap, BGRABitmapTypes;

type
  TPhotoDecodeThread = class(TThread)
  private
    FSourcePath: utf8string;
    FTargetW, FTargetH: integer;
    FResult: TBGRABitmap;
    FOnDone: TNotifyEvent;
    { Written and read ONLY on the main thread (the widget, from its
      own Destroy/reuse path, before Synchronize has run; DoDone, which
      already runs on the main thread inside Synchronize itself) — a
      plain, non-atomic field is sufficient since there is never
      concurrent access to it from two threads, see the Cancel comment. }
    FCanceled: boolean;
    procedure DoDone;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASourcePath: utf8string; ATargetW, ATargetH: integer;
      AOnDone: TNotifyEvent);
    { The caller (widget) must call this from its own Destroy if this
      thread's decode has not finished yet (FDecodeThread <> nil) —
      otherwise DoDone would call AOnDone on an already-destroyed
      object. Safe to call from the main thread at any point before
      AOnDone has actually fired: until Synchronize reaches the
      callback on the main thread, the thread itself is guaranteed
      alive (blocked inside Synchronize, waiting its turn) —
      FreeOnTerminate cannot fire earlier than that. }
    procedure Cancel;
    { Takes ownership of the result (may be nil if decoding failed or
      was canceled) — the caller must free it. Call only from within
      AOnDone. }
    function TakeResult: TBGRABitmap;
    property SourcePath: utf8string read FSourcePath;
  end;

implementation

constructor TPhotoDecodeThread.Create(const ASourcePath: utf8string;
  ATargetW, ATargetH: integer; AOnDone: TNotifyEvent);
begin
  inherited Create(True);
  FSourcePath := ASourcePath;
  FTargetW := ATargetW;
  FTargetH := ATargetH;
  FOnDone := AOnDone;
  FreeOnTerminate := True;
  Start;
end;

procedure TPhotoDecodeThread.Cancel;
begin
  FCanceled := True;
end;

function TPhotoDecodeThread.TakeResult: TBGRABitmap;
begin
  Result := FResult;
  FResult := nil;
end;

procedure TPhotoDecodeThread.DoDone;
begin
  { FCanceled is checked HERE, not in Execute before calling
    Synchronize — this method already runs on the main thread (that is
    the point of Synchronize), so reading a field that only the main
    thread writes (see Cancel) needs no extra synchronization. If
    canceled, the result is freed here — the widget it was meant for
    will never call TakeResult. }
  if FCanceled then begin
    FreeAndNil(FResult);
    Exit;
  end;
  if Assigned(FOnDone) then begin
    FOnDone(Self);
  end;
end;

procedure TPhotoDecodeThread.Execute;
var
  Src: TBGRABitmap;
begin
  Src := nil;
  try
    try
      if FileExists(string(FSourcePath)) then begin
        Src := TBGRABitmap.Create(string(FSourcePath));
        Src.ResampleFilter := rfBestQuality;
        FResult := Src.Resample(FTargetW, FTargetH, rmFineResample);
      end;
    except
      FreeAndNil(FResult);
    end;
  finally
    Src.Free;
  end;
  Synchronize(@DoDone);
end;

end.
