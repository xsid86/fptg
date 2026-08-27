unit tdjson;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ctypes;

const
  TDJSON_LIB = 'tdjson.dll';

type
  { Вызывается из внутренних потоков TDLib. LCL отсюда трогать нельзя. }
  TTdLogMessageCallback = procedure(verbosity_level: cint; message: pansichar); cdecl;

  { ---- Актуальный API (client id) ---- }

function td_create_client_id: cint; cdecl; external TDJSON_LIB name 'td_create_client_id';

procedure td_send(client_id: cint; request: pansichar); cdecl; external TDJSON_LIB name 'td_send';

function td_receive(timeout: cdouble): pansichar; cdecl; external TDJSON_LIB name 'td_receive';

function td_execute(request: pansichar): pansichar; cdecl; external TDJSON_LIB name 'td_execute';

procedure td_set_log_message_callback(max_verbosity_level: cint; callback: TTdLogMessageCallback); cdecl; external TDJSON_LIB name 'td_set_log_message_callback';

{ ---- Хелперы ---- }

{ Копирует байты из буфера TDLib в UTF8String без перекодировки.
  Вызывать НЕМЕДЛЕННО после td_receive/td_execute. }
function TdCopyToUtf8(P: pansichar): utf8string;

{ Обёртки, возвращающие уже скопированную строку. }
function TdReceive(Timeout: double): utf8string;
function TdExecute(const ARequest: utf8string): utf8string;
procedure TdSend(AClientId: integer; const ARequest: utf8string);

implementation

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
  { False = только пометить кодировку, байты не трогать }
  SetCodePage(Raw, CP_UTF8, False);
  Result := Raw;
end;

function TdReceive(Timeout: double): utf8string;
begin
  Result := TdCopyToUtf8(td_receive(Timeout));
end;

function TdExecute(const ARequest: utf8string): utf8string;
begin
  Result := TdCopyToUtf8(td_execute(pansichar(ARequest)));
end;

procedure TdSend(AClientId: integer; const ARequest: utf8string);
begin
  td_send(AClientId, pansichar(ARequest));
end;

end.
