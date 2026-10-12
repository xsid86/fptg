unit tdjson;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ctypes, SyncObjs, constants;

type
  { Called from TDLib's internal threads. LCL must not be touched
    from here. }
  TTdLogMessageCallback = procedure(verbosity_level: cint; message: pansichar); cdecl;

  { ---- Current API (client id) ---- }

function td_create_client_id: cint; cdecl; external TDJSON_LIB name 'td_create_client_id';

procedure td_send(client_id: cint; request: pansichar); cdecl; external TDJSON_LIB name 'td_send';

function td_receive(timeout: cdouble): pansichar; cdecl; external TDJSON_LIB name 'td_receive';

function td_execute(request: pansichar): pansichar; cdecl; external TDJSON_LIB name 'td_execute';

procedure td_set_log_message_callback(max_verbosity_level: cint; callback: TTdLogMessageCallback); cdecl; external TDJSON_LIB name 'td_set_log_message_callback';

{ ---- Helpers ---- }

{ Copies bytes from a TDLib buffer into a UTF8String without
  re-encoding. Call IMMEDIATELY after td_receive/td_execute. }
function TdCopyToUtf8(P: pansichar): utf8string;

{ Wrappers that return an already-copied string. }
function TdReceive(Timeout: double): utf8string;
function TdExecute(const ARequest: utf8string): utf8string;
procedure TdSend(AClientId: integer; const ARequest: utf8string);

implementation

var
  { Full raw log of everything sent to and received from TDLib, at the
    td_send/td_receive level — below tdrecv.pas and any subscribers.
    Independent of whether the debug screen (TFrameLog) is open, and
    not truncated by line count like its Memo (MAX_LOG_LINES=500). The
    file is recreated on every run (fmCreate), next to the executable. }
  GLogFile: TFileStream = nil;
  GLogLock: TCriticalSection = nil;

procedure TdLogLine(const APrefix, ALine: utf8string);
var
  S: utf8string;
begin
  if GLogLock = nil then begin
    Exit; { finalization has already started }
  end;
  GLogLock.Enter;
  try
    if GLogFile = nil then begin
      try
        GLogFile := TFileStream.Create(
          ExtractFilePath(ParamStr(0)) + 'tdlib_raw.log', fmCreate or fmShareDenyWrite);
      except
        GLogFile := nil;
      end;
      if GLogFile = nil then begin
        Exit;
      end;
    end;
    S := utf8string(FormatDateTime('hh:nn:ss.zzz', Now)) + ' ' + APrefix + ' ' + ALine + LineEnding;
    try
      GLogFile.WriteBuffer(S[1], Length(S));
    except
      { Disk full, file locked, etc. — logging must not crash TDLib. }
    end;
  finally
    GLogLock.Leave;
  end;
end;

function TdCopyToUtf8(P: pansichar): utf8string;
var
  Len: SizeInt;
  Raw: rawbytestring;
begin
  Result := '';
  if P = nil then begin
    Exit;
  end;
  Len := StrLen(P);
  if Len = 0 then begin
    Exit;
  end;
  SetLength(Raw, Len);
  Move(P^, Raw[1], Len);
  { False = only tag the code page, don't touch the bytes }
  SetCodePage(Raw, CP_UTF8, False);
  Result := Raw;
end;

function TdReceive(Timeout: double): utf8string;
begin
  Result := TdCopyToUtf8(td_receive(Timeout));
  if Result <> '' then begin
    TdLogLine('<<', Result);
  end;
end;

function TdExecute(const ARequest: utf8string): utf8string;
begin
  Result := TdCopyToUtf8(td_execute(pansichar(ARequest)));
end;

procedure TdSend(AClientId: integer; const ARequest: utf8string);
begin
  TdLogLine('>>', utf8string('[' + IntToStr(AClientId) + '] ') + ARequest);
  td_send(AClientId, pansichar(ARequest));
end;

initialization
  GLogLock := TCriticalSection.Create;
  { До первого клиента: уровень общий на процесс (td_api.tl,
    setLogVerbosityLevel: "Can be called synchronously"). }
  TdExecute(utf8string('{"@type":"setLogVerbosityLevel","new_verbosity_level":'
    + IntToStr(TDLIB_LOG_VERBOSITY) + '}'));

finalization
  FreeAndNil(GLogFile);
  FreeAndNil(GLogLock);

end.
