unit splash;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls,
  constants, tdauth, tdcore;

type

  { TFormSplash }

  TFormSplash = class(TForm, ITdStateListener)
    Image1:    TImage;
    lblStatus: TLabel;
    btnCancel: TButton;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
  private
    FDone:      boolean;
    FSettled:   boolean;   { authorization state has resolved }
    FStartTick: QWord;     { time shown, for the minimum display duration }
    FTimer:     TTimer;    { created in code, not in the .lfm }
    procedure TimerTick(Sender: TObject);
    procedure TryHide;
  public
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);
  end;

var
  FormSplash: TFormSplash;

implementation

{$R *.lfm}

{ TFormSplash }

procedure TFormSplash.FormCreate(Sender: TObject);
begin
  FDone := False;
  FSettled := False;
  { GetTickCount64 is monotonic — unlike Now, it does not jump on a
    clock adjustment or DST change. }
  FStartTick := GetTickCount64;

  lblStatus.Caption := 'Connecting to Telegram...';
  btnCancel.Visible := False;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 100;
  FTimer.OnTimer := @TimerTick;
  FTimer.Enabled := False;

  TdApp.Subscribe(Self);
end;

procedure TFormSplash.FormDestroy(Sender: TObject);
begin
  if FTimer <> nil then begin
    FTimer.Enabled := False;
  end;
  TdUnsubscribe(Self);
end;

procedure TFormSplash.TimerTick(Sender: TObject);
begin
  TryHide;
end;

{ Hides once BOTH conditions hold: the state has resolved and the
  minimum display duration has elapsed. If the duration has not
  elapsed yet, waits for timer ticks without blocking the message
  queue. }
procedure TFormSplash.TryHide;
begin
  if FDone or (not FSettled) then begin
    Exit;
  end;
  if GetTickCount64 - FStartTick < MIN_SPLASH_MS then begin
    FTimer.Enabled := True;
    Exit;
  end;
  FDone := True;
  FTimer.Enabled := False;
  Hide;
end;

procedure TFormSplash.btnCancelClick(Sender: TObject);
begin
  Application.Terminate;
end;

procedure TFormSplash.TdStateChanged(AState: TTdAuthState);
begin
  if FDone then begin
    Exit;
  end;

  { Hides only on a meaningful state. WaitTdlibParameters arrives
    almost instantly and only means "TDLib has woken up". }
  if TdIsPromptState(AState) or (AState = tasReady) then begin
    FSettled := True;
    TryHide;
  end else begin
    lblStatus.Caption := AuthStateToStr(AState) + '...';
  end;
end;

procedure TFormSplash.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  if FDone then begin
    Exit;
  end;
  { Typical case: a wrong api_id/api_hash — the state gets stuck on
    WaitTdlibParameters, and without this the window would just hang
    silently. }
  lblStatus.Caption := 'Error ' + IntToStr(ACode) + ': ' + string(AMessage);
  btnCancel.Visible := True;
end;

end.
