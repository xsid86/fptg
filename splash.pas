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
    FDone: boolean;
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
  lblStatus.Caption := 'Подключение к Telegram...';
  btnCancel.Visible := True;
  TdApp.Subscribe(Self);
end;

procedure TFormSplash.FormDestroy(Sender: TObject);
begin
  TdUnsubscribe(Self);
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
    FDone := True;
    Sleep(2000);
    Hide;
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
