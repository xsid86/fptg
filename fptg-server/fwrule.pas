unit fwrule;

{$mode objfpc}{$H+}

{ Letting the server through the firewall (2026-10-19): when it is to be
  reached from the local network or the internet (srvnetwork.pas), Windows
  Firewall needs an inbound rule. Adding one takes administrator rights, so
  netsh runs elevated — Windows asks the person (UAC) once.

  Two rules under one name ("fptg server, port N"), both for this program
  only: TCP on the server's port (HTTPS, WebSocket, the call relay's TCP
  side) and UDP on any port (the call relay's allocations, turnrelay.pas).
  The profiles: the local network — private and domain; the internet — all.

  No core dependencies: the console server and the server window both use
  it. Elsewhere than Windows nothing is changed — the result says what to
  open by hand. }

interface

{ Adds (replacing old ones) the rules for APort. AInternet — every network
  profile, otherwise private and domain. False — refused or failed;
  AMessage says why or what to do instead. }
function AllowThroughFirewall(APort: word; AInternet: boolean; out AMessage: string): boolean;
{ Removes the rules for APort, if there are any (asks for elevation only then). }
function RemoveFirewallRule(APort: word; out AMessage: string): boolean;
{ Whether rules for APort exist. }
function FirewallRuleExists(APort: word): boolean;

implementation

uses
  SysUtils, Process, constants
  {$IFDEF WINDOWS}, Windows, ShellApi{$ENDIF};

function RuleName(APort: word): string;
begin
  Result := FIREWALL_RULE_NAME + IntToStr(APort);
end;

function FirewallRuleExists(APort: word): boolean;
{$IFDEF WINDOWS}
var
  Output: string;
begin
  { netsh show rule exits with 1 when there is no such rule; it needs no
    elevation. }
  Result := RunCommand('netsh', ['advfirewall', 'firewall', 'show', 'rule',
    'name=' + RuleName(APort)], Output, [poNoConsole]);
end;
{$ELSE}
begin
  Result := False;
end;
{$ENDIF}

{$IFDEF WINDOWS}
{ cmd /s /c "<chain>" elevated (UAC), waiting for it. False — refused. }
function RunElevated(const AChain: string; out AMessage: string): boolean;
var
  Info: TShellExecuteInfoW;
  Params: UnicodeString;
  Code: DWORD;
begin
  AMessage := '';
  Params := UnicodeString('/s /c "' + AChain + '"');
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize := SizeOf(Info);
  Info.fMask := SEE_MASK_NOCLOSEPROCESS;
  Info.lpVerb := 'runas';
  Info.lpFile := 'cmd.exe';
  Info.lpParameters := PWideChar(Params);
  Info.nShow := SW_HIDE;
  if not ShellExecuteExW(@Info) then begin
    if GetLastError = ERROR_CANCELLED then begin
      AMessage := 'The firewall was not changed: administrator rights were refused.';
    end else begin
      AMessage := 'The firewall was not changed: ' + SysErrorMessage(GetLastError);
    end;
    Exit(False);
  end;
  try
    WaitForSingleObject(Info.hProcess, INFINITE);
    Code := 0;
    GetExitCodeProcess(Info.hProcess, Code);
  finally
    CloseHandle(Info.hProcess);
  end;
  Result := True;
end;
{$ENDIF}

function AllowThroughFirewall(APort: word; AInternet: boolean; out AMessage: string): boolean;
{$IFDEF WINDOWS}
var
  Name, Exe, Prof, Chain: string;
begin
  Name := RuleName(APort);
  Exe := ParamStr(0);
  if AInternet then begin
    Prof := 'any';
  end else begin
    Prof := 'private,domain';
  end;
  Chain := 'netsh advfirewall firewall delete rule name="' + Name + '" >nul'
    + ' & netsh advfirewall firewall add rule name="' + Name + '" dir=in action=allow'
    + ' protocol=TCP localport=' + IntToStr(APort) + ' program="' + Exe + '" profile=' + Prof
    + ' & netsh advfirewall firewall add rule name="' + Name + '" dir=in action=allow'
    + ' protocol=UDP program="' + Exe + '" profile=' + Prof;
  if not RunElevated(Chain, AMessage) then begin
    Exit(False);
  end;
  Result := FirewallRuleExists(APort);
  if Result then begin
    AMessage := 'Windows Firewall lets the server in on port ' + IntToStr(APort) + '.';
  end else begin
    AMessage := 'Could not add the Windows Firewall rule. Allow TCP port '
      + IntToStr(APort) + ' for this program by hand.';
  end;
end;
{$ELSE}
begin
  AMessage := 'Open TCP port ' + IntToStr(APort) + ' (and UDP for the call relay) in the '
    + 'firewall, for example: sudo ufw allow ' + IntToStr(APort) + '/tcp';
  Result := False;
end;
{$ENDIF}

function RemoveFirewallRule(APort: word; out AMessage: string): boolean;
{$IFDEF WINDOWS}
begin
  AMessage := '';
  if not FirewallRuleExists(APort) then begin
    Exit(True);
  end;
  if not RunElevated('netsh advfirewall firewall delete rule name="' + RuleName(APort) + '"',
    AMessage) then begin
    Exit(False);
  end;
  Result := not FirewallRuleExists(APort);
  if Result then begin
    AMessage := 'The Windows Firewall rule for port ' + IntToStr(APort) + ' is removed.';
  end;
end;
{$ELSE}
begin
  AMessage := '';
  Result := True;
end;
{$ENDIF}

end.
