unit splash;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls,
  tdauth, tdcore;

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
    FSettled:   boolean;   { состояние авторизации уже определилось }
    FStartTick: QWord;     { момент показа, для минимальной выдержки }
    FTimer:     TTimer;    { создаётся в коде, чтобы не трогать .lfm }
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

const
  { Минимальное время показа сплэша. Если TDLib ответит быстрее,
    окно всё равно повисит столько — иначе оно мигает. }
  MIN_SPLASH_MS = 2000;

{ TFormSplash }

procedure TFormSplash.FormCreate(Sender: TObject);
begin
  FDone := False;
  FSettled := False;
  { GetTickCount64 монотонен — в отличие от Now он не поедет
    при переводе часов или смене летнего времени. }
  FStartTick := GetTickCount64;

  lblStatus.Caption := 'Подключение к Telegram...';
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

{ Прячемся, когда выполнены ОБА условия: состояние определилось
  и прошла минимальная выдержка. Если выдержка ещё не истекла —
  ждём тиков таймера, не блокируя очередь сообщений. }
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

  { Прячемся только на осмысленном состоянии. WaitTdlibParameters
    прилетает почти мгновенно и означает лишь «TDLib проснулся». }
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
  { Типовой случай — неверный api_id/api_hash: состояние застревает
    на WaitTdlibParameters, и без этого окно висело бы молча. }
  lblStatus.Caption := 'Ошибка ' + IntToStr(ACode) + ': ' + string(AMessage);
  btnCancel.Visible := True;
end;

end.
