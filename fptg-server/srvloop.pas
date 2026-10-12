unit srvloop;

{$mode objfpc}{$H+}

{ Цикл событий консольного сервера — то, что в окне делает
  Application.Run.

  Всё ядро живёт в главном потоке: ответы TDLib (tdrecv), команды
  страницы (webapi) и таймеры (tdtimer) попадают в него через
  TThread.Queue, а разбирает очередь CheckSynchronize. Здесь он и
  крутится, пока не попросили остановиться: Ctrl+C, Ctrl+Break,
  закрытие окна консоли, выход из системы (Windows) или SIGINT/SIGTERM
  (Unix). Потом — штатное закрытие клиентов TDLib, как при закрытии
  окна (TTdCore.BeginShutdown): без него база TDLib закрывается
  грязно. }

interface

{ До запроса остановки. }
procedure RunUntilStopped;
{ Остановку уже попросили (Ctrl+C, закрытие консоли, SIGTERM). }
function StopRequested: boolean;
{ Закрывает клиентов TDLib и ждёт подтверждения (сам TTdCore
  ограничивает ожидание SHUTDOWN_TIMEOUT). }
procedure ShutdownCore;
{ Последний шаг программы: отпускает обработчик закрытия консоли,
  который держит Windows, пока мы закрываемся. }
procedure ShutdownFinished;

implementation

uses
  {$IFDEF WINDOWS}
  Windows,
  {$ELSE}
  BaseUnix,
  {$ENDIF}
  Classes, SysUtils, constants, tdcore;

const
  { Шаг цикла: CheckSynchronize просыпается раньше, как только в
    очереди что-то появилось; таймаут нужен только чтобы заметить
    флаг остановки. }
  LOOP_WAIT_MS = 100;
  { Запас поверх SHUTDOWN_TIMEOUT на случай, если обратный вызов ядра
    так и не пришёл. }
  SHUTDOWN_SLACK_MS = 2000;
  {$IFDEF WINDOWS}
  { Windows ждёт обработчик CTRL_CLOSE_EVENT около 5 с, потом убивает
    процесс сам. }
  CONSOLE_CLOSE_WAIT_MS = 4500;
  {$ENDIF}

type
  TShutdownRelay = class
    Done: boolean;
    procedure Complete(Sender: TObject);
  end;

var
  GStop: longint = 0;
  {$IFDEF WINDOWS}
  GFinished: THandle = 0;
  {$ENDIF}

procedure TShutdownRelay.Complete(Sender: TObject);
begin
  Done := True;
end;

{$IFDEF WINDOWS}
{ Зовётся системой в своём потоке. На закрытие консоли, выход из
  системы и выключение процесс живёт, только пока обработчик не
  вернулся, — поэтому здесь ждём, пока главный поток закончит. }
function ConsoleCtrl(ACtrlType: DWORD): BOOL; stdcall;
begin
  InterLockedExchange(GStop, 1);
  case ACtrlType of
    CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT: begin
      WaitForSingleObject(GFinished, CONSOLE_CLOSE_WAIT_MS);
    end;
  end;
  Result := True;
end;
{$ELSE}
procedure OnSignal(ASig: cint); cdecl;
begin
  GStop := 1;
end;
{$ENDIF}

procedure InstallHandlers;
{$IFNDEF WINDOWS}
var
  Act: SigActionRec;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  GFinished := CreateEvent(nil, True, False, nil);
  SetConsoleCtrlHandler(@ConsoleCtrl, True);
  {$ELSE}
  FillChar(Act, SizeOf(Act), 0);
  Act.sa_handler := SigActionHandler(@OnSignal);
  FpSigAction(SIGINT, @Act, nil);
  FpSigAction(SIGTERM, @Act, nil);
  {$ENDIF}
end;

function StopRequested: boolean;
begin
  Result := GStop <> 0;
end;

procedure RunUntilStopped;
begin
  InstallHandlers;
  while GStop = 0 do begin
    CheckSynchronize(LOOP_WAIT_MS);
  end;
end;

procedure ShutdownCore;
var
  Relay: TShutdownRelay;
  Deadline: QWord;
begin
  Relay := TShutdownRelay.Create;
  try
    if not TdApp.BeginShutdown(@Relay.Complete) then begin
      Deadline := GetTickCount64 + SHUTDOWN_TIMEOUT + SHUTDOWN_SLACK_MS;
      while (not Relay.Done) and (GetTickCount64 < Deadline) do begin
        CheckSynchronize(LOOP_WAIT_MS);
      end;
    end;
  finally
    Relay.Free;
  end;
end;

procedure ShutdownFinished;
begin
  {$IFDEF WINDOWS}
  if GFinished <> 0 then begin
    SetEvent(GFinished);
  end;
  {$ENDIF}
end;

end.
