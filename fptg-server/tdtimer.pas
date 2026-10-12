unit tdtimer;

{$mode objfpc}{$H+}

{ Таймер сервера без LCL — замена TTimer (ExtCtrls).

  Повторяет поведение TCustomTimer (lcl/customtimer.pas), на которое
  опирается код ядра:
  - по умолчанию Enabled = True, Interval = 1000;
  - тикает, только когда Enabled, Interval > 0 и задан OnTimer;
  - смена Interval или OnTimer у включённого таймера, как и включение,
    отсчитывает интервал заново; повторное Enabled := True у уже
    включённого — нет;
  - OnTimer вызывается в ГЛАВНОМ потоке, исключение из него не роняет
    программу.

  Устройство: один фоновый поток спит до ближайшего срока и ставит
  разбор сработавших в очередь главного потока (TThread.Queue). Её
  разбирает CheckSynchronize: в окне — цикл сообщений LCL (он сам
  ставит WakeMainThread), в консольном сервере — свой цикл
  (srvloop.pas). Список таймеров и их сроки трогает только главный
  поток; поток-планировщик видит лишь ближайший срок под замком. }

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
  { Куда деть исключение из OnTimer. По умолчанию — в stderr, если он
    есть (консоль); у окна его нет, там исключение просто глотается,
    как глотал бы его диалог HandleException, только молча. }
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
  { Под GLock: ближайший срок (0 — ни одного взведённого таймера) и
    признак, что Fire уже стоит в очереди и ещё не начался. }
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

{ Только главный поток. }
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
    { Пока Fire в очереди, сроки пересчитает он сам и разбудит. }
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
        { Метод своего потока: при уничтожении потока невыполненная
          запись снимается из очереди (TThread.Destroy). }
        Queue(@Fire);
        Continue;
      end;
      Wait := cardinal(Next - Now);
    end;
    GWake.WaitFor(Wait);
    GWake.ResetEvent;
  end;
end;

{ Главный поток. После каждого вызова — поиск с начала: обработчик
  волен включать, выключать и освобождать любые таймеры, включая
  свой. Сработавший получает новый срок ДО вызова, поэтому за один
  проход дважды не сработает. }
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
