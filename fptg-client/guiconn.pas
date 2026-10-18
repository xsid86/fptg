unit guiconn;

{$mode objfpc}{$H+}

{ The window's connection to the server — what to remember between runs.
  In conf.dat (secureconfig, encrypted): the server's address and port,
  the user name, the session's refresh token (not the password: the
  password is kept nowhere except as a hash on the server) and the
  fingerprint of the server certificate the person trusted (pinning).

  Signing in itself and the checks happen on the page (connect.js,
  core/session.js): it reaches the server from WebView2, and the window
  only stores things and decides about the certificate. }

interface

uses
  Classes, SysUtils;

type
  TServerAddress = record
    Host: string;
    Port: integer;
    User: string;
    Refresh: string;
    Fingerprint: string;
  end;

{ What is saved; False — nothing to connect to (no address). }
function LoadServerAddress(out AAddr: TServerAddress): boolean;
procedure SaveServerAddress(const AAddr: TServerAddress);
{ The latest window frame colours from the page (JSON as it came,
  winframe); '' — none yet. }
function LoadWindowFrame: string;
procedure SaveWindowFrame(const AJson: string);
{ https://address:port (IPv6 — in brackets). }
function ServerOrigin(const AAddr: TServerAddress): string;
{ Escaping for an address parameter. }
function UrlEncode(const S: string): string;

implementation

uses
  constants, guiconst, secureconfig, appdirs;

const
  KEY_HOST = 'host';
  KEY_PORT = 'port';
  KEY_USER = 'user';
  KEY_REFRESH = 'refresh';
  KEY_FINGERPRINT = 'fingerprint';

var
  GConfigReady: boolean = False;

procedure EnsureConfigDir;
begin
  if not GConfigReady then begin
    { The window's conf.dat is in the user profile (appdirs.pas). }
    SecureConfigSetDir(ClientDataDir);
    GConfigReady := True;
  end;
end;

function LoadServerAddress(out AAddr: TServerAddress): boolean;
var
  Ini: TSecureIni;
begin
  EnsureConfigDir;
  Ini := OpenConfig;
  try
    AAddr.Host := Ini.ReadString(GUI_CONFIG_SECTION, KEY_HOST, '');
    AAddr.Port := Ini.ReadInteger(GUI_CONFIG_SECTION, KEY_PORT, 0);
    AAddr.User := Ini.ReadString(GUI_CONFIG_SECTION, KEY_USER, '');
    AAddr.Refresh := Ini.ReadString(GUI_CONFIG_SECTION, KEY_REFRESH, '');
    AAddr.Fingerprint := Ini.ReadString(GUI_CONFIG_SECTION, KEY_FINGERPRINT, '');
  finally
    Ini.Free;
  end;
  Result := (AAddr.Host <> '') and (AAddr.Port > 0);
end;

procedure SaveServerAddress(const AAddr: TServerAddress);
var
  Ini: TSecureIni;
begin
  EnsureConfigDir;
  Ini := OpenConfig;
  try
    { The previous format (a token instead of sign-in) — remove it. }
    Ini.DeleteKey(GUI_CONFIG_SECTION, 'token');
    Ini.WriteString(GUI_CONFIG_SECTION, KEY_HOST, AAddr.Host);
    Ini.WriteInteger(GUI_CONFIG_SECTION, KEY_PORT, AAddr.Port);
    Ini.WriteString(GUI_CONFIG_SECTION, KEY_USER, AAddr.User);
    Ini.WriteString(GUI_CONFIG_SECTION, KEY_REFRESH, AAddr.Refresh);
    Ini.WriteString(GUI_CONFIG_SECTION, KEY_FINGERPRINT, AAddr.Fingerprint);
  finally
    Ini.Free;
  end;
end;

function LoadWindowFrame: string;
var
  Ini: TSecureIni;
begin
  EnsureConfigDir;
  Ini := OpenConfig;
  try
    Result := Ini.ReadString(GUI_WINDOW_SECTION, GUI_FRAME_KEY, '');
  finally
    Ini.Free;
  end;
end;

procedure SaveWindowFrame(const AJson: string);
var
  Ini: TSecureIni;
begin
  EnsureConfigDir;
  Ini := OpenConfig;
  try
    Ini.WriteString(GUI_WINDOW_SECTION, GUI_FRAME_KEY, AJson);
  finally
    Ini.Free;
  end;
end;

function ServerOrigin(const AAddr: TServerAddress): string;
var
  H: string;
begin
  H := AAddr.Host;
  if (Pos(':', H) > 0) and (Copy(H, 1, 1) <> '[') then begin
    H := '[' + H + ']';
  end;
  Result := 'https://' + H + ':' + IntToStr(AAddr.Port);
end;

function UrlEncode(const S: string): string;
var
  I: integer;
  C: char;
begin
  Result := '';
  for I := 1 to Length(S) do begin
    C := S[I];
    if C in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~'] then begin
      Result := Result + C;
    end else begin
      Result := Result + '%' + IntToHex(Ord(C), 2);
    end;
  end;
end;

end.
