unit srvloop;

{$mode objfpc}{$H+}

{ The console server's event loop — what Application.Run does in the
  window.

  The whole core lives on the main thread: TDLib answers (tdrecv), page
  commands (webapi) and timers (tdtimer) reach it through TThread.Queue,
  and CheckSynchronize drains the queue. It spins here until asked to
  stop: Ctrl+C, Ctrl+Break, closing the console window, logging off
  (Windows) or SIGINT/SIGTERM (Unix). Then — a proper shutdown of the
  TDLib clients, as when the window closes (TTdCore.BeginShutdown):
  without it the TDLib database closes dirty. }

interface

{ Until a stop is requested. }
procedure RunUntilStopped;
{ A stop has been requested already (Ctrl+C, closing the console, SIGTERM). }
function StopRequested: boolean;
{ Closes the TDLib clients and waits for confirmation (TTdCore itself
  caps the wait at SHUTDOWN_TIMEOUT). }
procedure ShutdownCore;
{ The program's last step: releases the console close handler, which
  Windows holds while we are closing. }
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
  { The loop step: CheckSynchronize wakes earlier as soon as something is
    in the queue; the timeout is only needed to notice the stop flag. }
  LOOP_WAIT_MS = 100;
  { Margin over SHUTDOWN_TIMEOUT in case the core's callback never comes. }
  SHUTDOWN_SLACK_MS = 2000;
  {$IFDEF WINDOWS}
  { Windows waits for a CTRL_CLOSE_EVENT handler about 5 s, then kills the
    process itself. }
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
{ Called by the system on its own thread. On console close, log-off and
  shutdown the process lives only until the handler returns — so here we
  wait for the main thread to finish. }
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
