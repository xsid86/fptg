unit framelog;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, ExtCtrls, fpjson,
  constants, tdauth, tdcore, uiframe;

type

  { TFrameLog

    Debug screen showing the raw JSON stream from TDLib. Subscribed
    permanently, not only while active, so returning to the screen
    does not leave a gap in the log. }

  TFrameLog = class(TFrameBase, ITdUpdateListener)
    pnlTop: TPanel;
    btnClear: TButton;
    chkPause: TCheckBox;
    lblCount: TLabel;
    Memo1: TMemo;
    procedure btnClearClick(Sender: TObject);
  private
    FTotal: Int64;
    procedure UpdateCounter;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
  end;

implementation

{$R *.lfm}

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
  lblCount.Caption := Format('received: %d, shown: %d', [FTotal, Memo1.Lines.Count]);
end;

procedure TFrameLog.btnClearClick(Sender: TObject);
begin
  Memo1.Clear;
  UpdateCounter;
end;

procedure TFrameLog.TdUpdate(const AJson: utf8string; AData: TJSONObject);
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
  finally
    Memo1.Lines.EndUpdate;
  end;
  UpdateCounter;
end;

end.
