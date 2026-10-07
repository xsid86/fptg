unit guiconn;

{$mode objfpc}{$H+}

{ Подключение окна к серверу: адрес, порт и токен, которые печатает
  FPTelegramServer при запуске. Хранятся в conf.dat рядом с
  FPTelegram.exe — зашифрованными, тем же secureconfig, что настройки
  сервера.

  Проверка подключения — один GET страницы с токеном в фоновом потоке:
  200 — сервер наш и токен верный, 403 — токен не тот, остальное —
  сервер недоступен. Ответ — в главном потоке. }

interface

uses
  Classes, SysUtils;

type
  TServerAddress = record
    Host: string;
    Port: integer;
    Token: string;
  end;

  TProbeResult = (prOk, prBadToken, prUnreachable);

  TProbeDone = procedure(ASerial: integer; AResult: TProbeResult;
    const AMessage: string) of object;

{ Сохранённое подключение; False — его нет (первый запуск). }
function LoadServerAddress(out AAddr: TServerAddress): boolean;
procedure SaveServerAddress(const AAddr: TServerAddress);
{ Адрес страницы сервера с токеном. }
function ServerPageUrl(const AAddr: TServerAddress): string;
{ Проверка в фоне; ADone зовётся в главном потоке с тем же ASerial —
  по нему вызывающий отличает ответ на последнюю проверку от
  опоздавшего. }
procedure ProbeServer(const AAddr: TServerAddress; ASerial: integer; ADone: TProbeDone);

implementation

uses
  httpsend, synacode, constants, guiconst, secureconfig;

const
  KEY_HOST = 'host';
  KEY_PORT = 'port';
  KEY_TOKEN = 'token';

type
  TProbeThread = class(TThread)
  private
    FUrl: string;
    FSerial: integer;
    FDone: TProbeDone;
    FResult: TProbeResult;
    FMessage: string;
    procedure Report;
  protected
    procedure Execute; override;
  end;

var
  GConfigReady: boolean = False;

procedure EnsureConfigFile;
begin
  if not GConfigReady then begin
    SecureConfigSetDir(ExtractFilePath(ParamStr(0)));
    GConfigReady := True;
  end;
end;

function LoadServerAddress(out AAddr: TServerAddress): boolean;
var
  Ini: TSecureIni;
begin
  EnsureConfigFile;
  Ini := OpenConfig;
  try
    AAddr.Host := Ini.ReadString(GUI_CONFIG_SECTION, KEY_HOST, '');
    AAddr.Port := Ini.ReadInteger(GUI_CONFIG_SECTION, KEY_PORT, 0);
    AAddr.Token := Ini.ReadString(GUI_CONFIG_SECTION, KEY_TOKEN, '');
  finally
    Ini.Free;
  end;
  Result := (AAddr.Host <> '') and (AAddr.Port > 0) and (AAddr.Token <> '');
end;

procedure SaveServerAddress(const AAddr: TServerAddress);
var
  Ini: TSecureIni;
begin
  EnsureConfigFile;
  Ini := OpenConfig;
  try
    Ini.WriteString(GUI_CONFIG_SECTION, KEY_HOST, AAddr.Host);
    Ini.WriteInteger(GUI_CONFIG_SECTION, KEY_PORT, AAddr.Port);
    Ini.WriteString(GUI_CONFIG_SECTION, KEY_TOKEN, AAddr.Token);
  finally
    Ini.Free;
  end;
end;

function ServerPageUrl(const AAddr: TServerAddress): string;
var
  H: string;
begin
  H := AAddr.Host;
  { IPv6 — в квадратных скобках, иначе двоеточия адреса спутаются с
    портом. }
  if (Pos(':', H) > 0) and (Copy(H, 1, 1) <> '[') then begin
    H := '[' + H + ']';
  end;
  Result := 'http://' + H + ':' + IntToStr(AAddr.Port) + '/?t=' + EncodeURLElement(AAddr.Token);
end;

procedure TProbeThread.Execute;
var
  Http: THTTPSend;
begin
  FResult := prUnreachable;
  FMessage := '';
  Http := THTTPSend.Create;
  try
    Http.Timeout := CONNECT_PROBE_TIMEOUT_MS;
    Http.Sock.ConnectionTimeout := CONNECT_PROBE_TIMEOUT_MS;
    { HEAD: проверке тело страницы не нужно — сервер отвечает на HEAD
      тем же кодом (localserver, ServeFileFrom). }
    if Http.HTTPMethod('HEAD', FUrl) then begin
      case Http.ResultCode of
        200: FResult := prOk;
        403: FResult := prBadToken;
      else
        FMessage := 'The server answered ' + IntToStr(Http.ResultCode) + ' '
          + Http.ResultString;
      end;
    end else begin
      FMessage := Http.Sock.LastErrorDesc;
    end;
  finally
    Http.Free;
  end;
  { Synchronize, не Queue: поток освобождается сам сразу после Execute,
    и невыполненная запись Queue снялась бы вместе с ним. }
  Synchronize(@Report);
end;

procedure TProbeThread.Report;
begin
  if Assigned(FDone) then begin
    FDone(FSerial, FResult, FMessage);
  end;
end;

procedure ProbeServer(const AAddr: TServerAddress; ASerial: integer; ADone: TProbeDone);
var
  T: TProbeThread;
begin
  T := TProbeThread.Create(True);
  T.FreeOnTerminate := True;
  T.FUrl := ServerPageUrl(AAddr);
  T.FSerial := ASerial;
  T.FDone := ADone;
  T.Start;
end;

end.
