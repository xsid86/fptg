unit framelog;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, ExtCtrls,
  tdauth, tdcore, uiframe;

type

  { TFrameLog

    Отладочный экран: сырой поток JSON от TDLib. Подписан постоянно,
    а не только когда активен, — иначе при возврате на экран была бы
    дыра в логе. }

  TFrameLog = class(TFrameBase, ITdUpdateListener)
    pnlTop:   TPanel;
    btnClear: TButton;
    chkPause: TCheckBox;
    lblCount: TLabel;
    Memo1:    TMemo;
    procedure btnClearClick(Sender: TObject);
  private
    FTotal: int64;
    procedure UpdateCounter;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string);
  end;

implementation

{$R *.lfm}

const
  { Лог не должен расти бесконечно: мемо с сотнями тысяч строк
    съедает память и начинает тормозить при перерисовке. }
  MAX_LOG_LINES = 500;

constructor TFrameLog.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FTotal := 0;
  Memo1.Clear;
  UpdateCounter;
  TdApp.Subscribe(Self);
end;

destructor TFrameLog.Destroy;
begin
  TdUnsubscribe(Self);
  inherited Destroy;
end;

procedure TFrameLog.UpdateCounter;
begin
  lblCount.Caption := Format('получено: %d, показано: %d', [FTotal, Memo1.Lines.Count]);
end;

procedure TFrameLog.btnClearClick(Sender: TObject);
begin
  Memo1.Clear;
  UpdateCounter;
end;

procedure TFrameLog.TdUpdate(const AJson: utf8string);
begin
  Inc(FTotal);
  if chkPause.Checked then begin
    UpdateCounter;
    Exit;
  end;

  Memo1.Lines.BeginUpdate;
  try
    while Memo1.Lines.Count >= MAX_LOG_LINES do begin
      Memo1.Lines.Delete(0);
    end;
    Memo1.Lines.Add(string(AJson));
    Memo1.Lines.Add('');
  finally
    Memo1.Lines.EndUpdate;
  end;
  UpdateCounter;
end;

end.
