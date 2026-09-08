unit lottieplayer;

{$mode objfpc}{$H+}

{ Looped playback of a single TGS sticker (Lottie vector animation,
  gzip-compressed JSON) — the same decoder-thread plus shared frame
  buffer approach as TAnimationPlayer (videoplayer.pas, GIFs), using
  rlottie instead of FFmpeg (see rlottie.pas). Unlike video decoding,
  Lottie needs no container/packets: the whole animation is already
  parsed in memory (lottie_animation_from_data), and a frame is
  rendered by NUMBER directly (lottie_animation_render) — random
  access, not sequential reading. The loop is simply "render frame N,
  wait 1/framerate, N := (N+1) mod totalframes", with none of a video
  decoder's seek/flush concerns.

  Output format is ARGB32_Premultiplied (see rlottie.pas) — the widget
  (framehistory.pas, DrawPremultipliedArgbBuffer) composites it via
  GDI AlphaBlend, not SetDIBitsToDevice (which, like the GIF path,
  just replaces pixels with no alpha — stickers, unlike video, are
  almost always transparent).

  FreeOnTerminate=True, for the same reason as TAnimationPlayer: any
  number of stickers can be on screen at once, each with its own
  independent widget/thread, and Stop is called often while scrolling
  — a synchronous WaitFor from the UI thread is not acceptable. }

interface

uses
  Classes, SysUtils, SyncObjs, Math, Windows, MMSystem, zstream, rlottie;

const
  { Rendering directly at the display size (typically
    STICKER_MAX_SIZE=170) loses fine detail: the rasterizer drops
    small dots, outlines, and edges at such a small target size. The
    fix, the same approach already used for photo/audio-cover
    thumbnails in this project: render at a LARGER internal
    resolution, then downscale to the display size by averaging
    blocks (BoxDownscaleArgb below), instead of feeding the rasterizer
    a small target grid directly. }
  RENDER_SCALE = 3;
  RENDER_MAX_DIM = 512;

type
  TLottiePlayer = class(TThread)
  private
    FFilePath: utf8string;
    FTargetW, FTargetH: integer;
    { SyncObjs.TCriticalSection is qualified explicitly: Windows (in
      uses for GetTickCount64) declares its own, incompatible
      TCriticalSection (an internal RTL type, not a class with
      Enter/Leave/Create). }
    FLock: SyncObjs.TCriticalSection;
    FFrameBuf: PByte;         { ARGB32_Premultiplied, FTargetW*FTargetH*4 bytes, guarded by FLock }
    FFrameVersion: cardinal;
    FStopRequested: boolean;
    FFailed: boolean;
    { Decompresses the .tgs (gzip) file entirely into memory —
      TGZFileStream (paszlib, part of FPC, no external zlib.dll) reads
      the file by name and parses the gzip header itself. Read in
      growing chunks rather than pre-sizing the buffer, since the
      gzip header does not store the exact uncompressed payload size. }
    function LoadJson: utf8string;
    procedure ExecuteInner;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFilePath: utf8string; ATargetW, ATargetH: integer);
    destructor Destroy; override;
    procedure StopPlayback;
    { Same contract as TAnimationPlayer.TryGetFrame. }
    function TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    property Failed: boolean read FFailed;
  end;

implementation

constructor TLottiePlayer.Create(const AFilePath: utf8string; ATargetW, ATargetH: integer);
begin
  inherited Create(True);
  FFilePath := AFilePath;
  FTargetW := ATargetW;
  FTargetH := ATargetH;
  FLock := SyncObjs.TCriticalSection.Create;
  FreeOnTerminate := True;
  Start;
end;

destructor TLottiePlayer.Destroy;
begin
  if FFrameBuf <> nil then begin
    FreeMem(FFrameBuf);
  end;
  FLock.Free;
  inherited Destroy;
end;

procedure TLottiePlayer.StopPlayback;
begin
  FStopRequested := True;
end;

function TLottiePlayer.TryGetFrame(ADst: PByte; var AKnownVersion: cardinal): boolean;
begin
  Result := False;
  FLock.Enter;
  try
    if (FFrameBuf <> nil) and (FFrameVersion <> 0) and (FFrameVersion <> AKnownVersion) then begin
      Move(FFrameBuf^, ADst^, cardinal(FTargetW) * cardinal(FTargetH) * 4);
      AKnownVersion := FFrameVersion;
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

function TLottiePlayer.LoadJson: utf8string;
var
  Gz: TGZFileStream;
  Chunk: array[0..65535] of byte;
  N: longint;
  Mem: TMemoryStream;
begin
  Result := '';
  Gz := nil;
  Mem := TMemoryStream.Create;
  try
    try
      Gz := TGZFileStream.Create(FFilePath, gzopenread);
    except
      { Creation failed (missing file/corrupt gzip) — Gz stays nil and
        is never touched below; Exit unwinds through the outer
        try/finally (Mem.Free), which frees Mem exactly once. }
      Exit;
    end;
    try
      repeat
        N := Gz.Read(Chunk, SizeOf(Chunk));
        if N > 0 then begin
          Mem.WriteBuffer(Chunk, N);
        end;
      until N < SizeOf(Chunk);
    finally
      Gz.Free;
    end;
    if Mem.Size > 0 then begin
      SetLength(Result, Mem.Size);
      Mem.Position := 0;
      Mem.ReadBuffer(Result[1], Mem.Size);
    end;
  finally
    Mem.Free;
  end;
end;

procedure TLottiePlayer.Execute;
begin
  try
    ExecuteInner;
  except
    on E: Exception do begin
      FFailed := True;
    end;
  end;
end;

{ Downscales ASrc (ARGB32_Premultiplied, ASrcW x ASrcH) to ADst (ADstW
  x ADstH) by averaging a rectangular block of source pixels per
  output pixel — a simple box filter, not bilinear/Lanczos, which is
  unnecessary precision for this purpose. Averaging is done DIRECTLY
  on the premultiplied ARGB channels, without un-premultiplying and
  back: for premultiplied alpha this is mathematically correct (the
  average of premultiplied values equals alpha-weighted blending) and
  also the cheapest option. Each source pixel is visited exactly once
  in total across all outputs — O(ASrcW*ASrcH). }
procedure BoxDownscaleArgb(ASrc: PByte; ASrcW, ASrcH: integer; ADst: PByte; ADstW, ADstH: integer);
var
  X, Y, SX, SY, SX0, SX1, SY0, SY1: integer;
  SumB, SumG, SumR, SumA, Cnt: cardinal;
  SP, DP: PByte;
begin
  { The rlottie build in use here writes pixels as R,G,B,A rather than
    B,G,R,A, which is what the rest of the pipeline expects
    (DrawPremultipliedArgbBuffer/GDI AlphaBlend, built for a standard
    Windows DIB). The channels are swapped here, while reading the
    source — the Move below (into FFrameBuf/AlphaBlend) stays
    unchanged. }

  for Y := 0 to ADstH - 1 do begin
    SY0 := (Y * ASrcH) div ADstH;
    SY1 := ((Y + 1) * ASrcH) div ADstH;
    if SY1 <= SY0 then begin
      SY1 := SY0 + 1;
    end;
    for X := 0 to ADstW - 1 do begin
      SX0 := (X * ASrcW) div ADstW;
      SX1 := ((X + 1) * ASrcW) div ADstW;
      if SX1 <= SX0 then begin
        SX1 := SX0 + 1;
      end;
      SumB := 0;
      SumG := 0;
      SumR := 0;
      SumA := 0;
      Cnt := 0;
      for SY := SY0 to SY1 - 1 do begin
        for SX := SX0 to SX1 - 1 do begin
          SP := ASrc + (cardinal(SY) * cardinal(ASrcW) + cardinal(SX)) * 4;
          Inc(SumB, SP[2]);   { source stores R here — see the comment above }
          Inc(SumG, SP[1]);
          Inc(SumR, SP[0]);   { source stores B here }
          Inc(SumA, SP[3]);
          Inc(Cnt);
        end;
      end;
      DP := ADst + (cardinal(Y) * cardinal(ADstW) + cardinal(X)) * 4;
      DP[0] := SumB div Cnt;
      DP[1] := SumG div Cnt;
      DP[2] := SumR div Cnt;
      DP[3] := SumA div Cnt;
    end;
  end;
end;

procedure TLottiePlayer.ExecuteInner;
var
  Json: utf8string;
  Anim: PLottieAnimation;
  TotalFrames: SizeUInt;
  FrameRate: double;
  FrameNum: SizeUInt;
  TmpBuf: PByte;
  RenderBuf: PByte;
  RenderW, RenderH: integer;
  AnchorTick, TargetTick, NowTick: QWord;
  CycleMs: QWord;
  SleepMs: integer;
begin
  Json := LoadJson;
  if Json = '' then begin
    FFailed := True;
    Exit;
  end;

  Anim := lottie_animation_from_data(PAnsiChar(Json), PAnsiChar(FFilePath), '');
  if Anim = nil then begin
    FFailed := True;
    Exit;
  end;

  TotalFrames := lottie_animation_get_totalframe(Anim);
  FrameRate := lottie_animation_get_framerate(Anim);
  if (TotalFrames = 0) or (FrameRate <= 0) then begin
    FFailed := True;
    lottie_animation_destroy(Anim);
    Exit;
  end;

  RenderW := Min(FTargetW * RENDER_SCALE, RENDER_MAX_DIM);
  RenderH := Min(FTargetH * RENDER_SCALE, RENDER_MAX_DIM);
  if RenderW < FTargetW then begin
    RenderW := FTargetW;
  end;
  if RenderH < FTargetH then begin
    RenderH := FTargetH;
  end;

  GetMem(RenderBuf, cardinal(RenderW) * cardinal(RenderH) * 4);
  GetMem(TmpBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);
  GetMem(FFrameBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);

  { Rendering goes into RenderBuf (internal resolution, HIGHER than
    the display size, see the constants above), downscaling into
    TmpBuf, both OUTSIDE the lock (rendering plus downscaling can take
    a noticeable amount of time; holding the lock for that long would
    stall TryGetFrame, which is polled from the UI thread's timer).
    Only a quick Move of the finished TmpBuf into the shared FFrameBuf
    happens under the lock, the same approach as HandleFrame in
    TAnimationPlayer (videoplayer.pas).

    Windows' Sleep(N) rounds the delay up to the system tick (usually
    ~15.6ms) by default; timeBeginPeriod(1) (winmm.dll, the same
    MMSystem unit already used for audio) corrects this.

    Frame timing is scheduled from a SINGLE fixed anchor point at the
    start of the loop (AnchorTick), not from the start of each
    iteration: the target time for frame N is
    AnchorTick + Round(N * (1000/FrameRate)), and the thread sleeps
    until that MOMENT rather than for a fixed duration counted from
    "now". If a frame is late, the next one wakes up earlier (or does
    not sleep at all), reclaiming exactly the time that was lost — a
    self-correcting scheme where error does not accumulate over many
    loop iterations.

    On each loop wrap (FrameNum back to 0), AnchorTick is advanced by
    the exact duration of one full cycle (CycleMs) rather than
    resampled from GetTickCount64 — this gives the last frame of the
    cycle its own full display interval instead of collapsing it into
    the first frame of the next cycle. The self-correction above still
    applies: if real time has already passed the new target moment,
    TargetTick > NowTick is simply false and the frame is shown
    without waiting. }
  CycleMs := QWord(Round(TotalFrames * (1000.0 / FrameRate)));
  timeBeginPeriod(1);
  try
    FrameNum := 0;
    AnchorTick := GetTickCount64;
    while not FStopRequested do begin
      lottie_animation_render(Anim, FrameNum, PCardinal(RenderBuf), RenderW, RenderH, RenderW * 4);
      BoxDownscaleArgb(RenderBuf, RenderW, RenderH, TmpBuf, FTargetW, FTargetH);

      FLock.Enter;
      try
        Move(TmpBuf^, FFrameBuf^, cardinal(FTargetW) * cardinal(FTargetH) * 4);
        Inc(FFrameVersion);
      finally
        FLock.Leave;
      end;

      Inc(FrameNum);
      if FrameNum >= TotalFrames then begin
        FrameNum := 0;
        Inc(AnchorTick, CycleMs);
      end;

      TargetTick := AnchorTick + QWord(Round(FrameNum * (1000.0 / FrameRate)));
      NowTick := GetTickCount64;
      if TargetTick > NowTick then begin
        SleepMs := integer(TargetTick - NowTick);
        Sleep(SleepMs);
      end;
    end;
  finally
    timeEndPeriod(1);
  end;

  lottie_animation_destroy(Anim);
  FreeMem(TmpBuf);
  FreeMem(RenderBuf);
end;

end.
