unit tdtimer;

{$mode objfpc}{$H+}

{ The server's timer without LCL — a replacement for TTimer (ExtCtrls).

  It repeats the behaviour of TCustomTimer (lcl/customtimer.pas) the core's
  code relies on:
  - Enabled = True, Interval = 1000 by default;
  - it ticks only when Enabled, Interval > 0 and OnTimer is set;
  - changing Interval or OnTimer of an enabled timer, like enabling it,
    starts the interval anew; setting Enabled := True on an already
    enabled one does not;
  - OnTimer is called on the MAIN thread, an exception from it does not
    bring the program down.

  How it works: one background thread sleeps until the nearest due time
  and queues the processing of the timers that fired on the main thread
  (TThread.Queue). CheckSynchronize drains it: in the window — the LCL
  message loop (it sets WakeMainThread itself), in the console server —
  our own loop (srvloop.pas). Only the main thread touches the timer list
  and their due times; the scheduler thread sees only the nearest due time
  under a lock. }

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TTdTimer = class(TComponent)
  private
    FInterval: cardinal;
    FEnabled: boolean;
    FOnTimer: TNotifyEvent;
    FArmed: boolean;
    FDue: QWord;
    procedure SetEnabled(AValue: boolean);
    procedure SetInterval(AValue: cardinal);
    procedure SetOnTimer(AValue: TNotifyEvent);
    procedure Rearm;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property Enabled: boolean read FEnabled write SetEnabled;
    property Interval: cardinal read FInterval write SetInterval;
    property OnTimer: TNotifyEvent read FOnTimer write SetOnTimer;
  end;

  TTdTimerError = procedure(E: Exception);

var
  { Where an exception from OnTimer goes. By default — to stderr if there
    is one (the console); the window has none, there the exception is
    simply swallowed, as the HandleException dialog would, only silently. }
  TdTimerError: TTdTimerError = nil;

implementation

type
  TTicker = class(TThread)
  protected
    procedure Execute; override;
  public
    procedure Fire;
  end;

var
  GTimers: TFPList = nil;
  GLock: TCriticalSection = nil;
  GWake: TEventObject = nil;
  GTicker: TTicker = nil;
  { Under GLock: the nearest due time (0 — no armed timer) and the flag
    that Fire is already queued and has not started yet. }
  GNextDue: QWord = 0;
  GFirePending: boolean = False;

procedure ReportError(E: Exception);
begin
  if Assigned(TdTimerError) then begin
    TdTimerError(E);
  end else if IsConsole then begin
    WriteLn(ErrOutput, 'timer: ', E.ClassName, ': ', E.Message);
  end;
end;

{ Main thread only. }
procedure Reschedule;
var
  I: integer;
  T: TTdTimer;
  Next: QWord;
begin
  Next := 0;
  for I := 0 to GTimers.Count - 1 do begin
    T := TTdTimer(GTimers[I]);
    if T.FArmed and ((Next = 0) or (T.FDue < Next)) then begin
      Next := T.FDue;
    end;
  end;
  GLock.Enter;
  try
    GNextDue := Next;
  finally
    GLock.Leave;
  end;
  GWake.SetEvent;
end;

procedure EnsureTicker;
begin
  if GTicker = nil then begin
    GTicker := TTicker.Create(False);
  end;
end;

{ ---------------- TTicker ---------------- }

procedure TTicker.Execute;
var
  Next, Now: QWord;
  Pending: boolean;
  Wait: cardinal;
begin
  while not Terminated do begin
    GLock.Enter;
    try
      Next := GNextDue;
      Pending := GFirePending;
    finally
      GLock.Leave;
    end;
    { While Fire is queued, it recomputes the due times itself and wakes us. }
    if (Next = 0) or Pending then begin
      Wait := INFINITE;
    end else begin
      Now := GetTickCount64;
      if Next <= Now then begin
        GLock.Enter;
        try
          GFirePending := True;
        finally
          GLock.Leave;
        end;
        { A method of our own thread: when the thread is destroyed an
          unexecuted entry is removed from the queue (TThread.Destroy). }
        Queue(@Fire);
        Continue;
      end;
      Wait := cardinal(Next - Now);
    end;
    GWake.WaitFor(Wait);
    GWake.ResetEvent;
  end;
end;

{ Main thread. After every call — searching from the start: the handler
  may enable, disable and free any timers, its own included. A timer that
  fired gets its new due time BEFORE the call, so it cannot fire twice in
  one pass. }
procedure TTicker.Fire;
var
  I: integer;
  T, Found: TTdTimer;
  Now: QWord;
begin
  GLock.Enter;
  try
    GFirePending := False;
  finally
    GLock.Leave;
  end;
  Now := GetTickCount64;
  repeat
    Found := nil;
    for I := 0 to GTimers.Count - 1 do begin
      T := TTdTimer(GTimers[I]);
      if T.FArmed and (T.FDue <= Now) then begin
        Found := T;
        Break;
      end;
    end;
    if Found = nil then begin
      Break;
    end;
    Found.FDue := Now + Found.FInterval;
    try
      Found.FOnTimer(Found);
    except
      on E: Exception do begin
        ReportError(E);
      end;
    end;
  until False;
  Reschedule;
end;

{ ---------------- TTdTimer ---------------- }

constructor TTdTimer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FInterval := 1000;
  FEnabled := True;
  GTimers.Add(Self);
  EnsureTicker;
end;

destructor TTdTimer.Destroy;
begin
  GTimers.Remove(Self);
  if FArmed then begin
    FArmed := False;
    Reschedule;
  end;
  inherited Destroy;
end;

procedure TTdTimer.Rearm;
begin
  FArmed := FEnabled and (FInterval > 0) and Assigned(FOnTimer);
  if FArmed then begin
    FDue := GetTickCount64 + FInterval;
  end;
  Reschedule;
end;

procedure TTdTimer.SetEnabled(AValue: boolean);
begin
  if AValue <> FEnabled then begin
    FEnabled := AValue;
    Rearm;
  end;
end;

procedure TTdTimer.SetInterval(AValue: cardinal);
begin
  if AValue <> FInterval then begin
    FInterval := AValue;
    Rearm;
  end;
end;

procedure TTdTimer.SetOnTimer(AValue: TNotifyEvent);
begin
  if (TMethod(AValue).Code <> TMethod(FOnTimer).Code)
    or (TMethod(AValue).Data <> TMethod(FOnTimer).Data) then begin
    FOnTimer := AValue;
    Rearm;
  end;
end;

initialization
  GTimers := TFPList.Create;
  GLock := TCriticalSection.Create;
  GWake := TEventObject.Create(nil, True, False, '');

finalization
  if GTicker <> nil then begin
    GTicker.Terminate;
    GWake.SetEvent;
    GTicker.WaitFor;
    FreeAndNil(GTicker);
  end;
  FreeAndNil(GWake);
  FreeAndNil(GLock);
  FreeAndNil(GTimers);
end.
