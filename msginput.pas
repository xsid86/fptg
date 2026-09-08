unit msginput;

{$mode objfpc}{$H+}

{ Message input panel. Lives at the bottom of the work area (main.pas,
  pnlWork), separated from the frame area (TFrameNavigator) by a
  splitter — see TFormMain.FormCreate.

  Three rows top to bottom: Toolbar (empty panel, reserved for future
  buttons — attachments/formatting etc.), Memo (the message text,
  fills the remaining space), ButtonRow (Send button, right-aligned;
  further buttons can be added to the same row).

  Built entirely in code, not via the designer: not bound to any
  particular chat/model itself (does not pull tdmessages/framehistory
  into uses) — it is just a text source plus a "send clicked" event;
  the owner (main.pas, which already has access to both
  TFrameNavigator.Current and TTdMessages) decides who and what to
  send. }

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Buttons, Graphics, LCLType;

type
  TMessageInputPanel = class(TCustomControl)
  private
    FToolbar: TPanel;
    FButtonRow: TPanel;
    FMemo: TMemo;
    FSendBtn: TBitBtn;
    FOnSend: TNotifyEvent;
    function GetText: string;
    procedure SetText(const AValue: string);
    procedure SendBtnClick(Sender: TObject);
    { Enter sends (same path as clicking Send); Ctrl+Enter inserts a
      newline, TMemo's default behavior, left untouched. }
    procedure MemoKeyDown(Sender: TObject; var Key: word; Shift: TShiftState);
  public
    constructor Create(AOwner: TComponent); override;
    procedure ClearText;
    { Empty panel at the top, reserved for future buttons (attachments,
      formatting, etc.). }
    property Toolbar: TPanel read FToolbar;
    { Button row below the input field — currently only Send,
      right-aligned; further buttons go into the same row with
      Align=alRight (each new one lands to the left of the previous). }
    property ButtonRow: TPanel read FButtonRow;
    property Text: string read GetText write SetText;
    property OnSend: TNotifyEvent read FOnSend write FOnSend;
  end;

implementation

const
  MSGINPUT_TOOLBAR_H = 32;
  MSGINPUT_BUTTONROW_H = 40;
  MSGINPUT_PAD = 8;
  MSGINPUT_SEND_W = 90;

constructor TMessageInputPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Constraints.MinHeight := 80;

  { Creation order matters for Align: the button row and toolbar go
    first (alTop/alBottom), Memo last (alClient fills what remains
    between them). }
  FButtonRow := TPanel.Create(Self);
  FButtonRow.Parent := Self;
  FButtonRow.Align := alBottom;
  FButtonRow.Height := MSGINPUT_BUTTONROW_H;
  FButtonRow.BevelOuter := bvNone;

  FSendBtn := TBitBtn.Create(Self);
  FSendBtn.Parent := FButtonRow;
  FSendBtn.Caption := 'Send';
  FSendBtn.Align := alRight;
  FSendBtn.Width := MSGINPUT_SEND_W;
  FSendBtn.BorderSpacing.Around := MSGINPUT_PAD div 2;
  FSendBtn.OnClick := @SendBtnClick;

  FToolbar := TPanel.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.Height := MSGINPUT_TOOLBAR_H;
  { Raised bevel visually sets the toolbar apart from the flat
    background of the rest of the input panel. }
  FToolbar.BevelOuter := bvRaised;

  FMemo := TMemo.Create(Self);
  FMemo.Parent := Self;
  FMemo.Align := alClient;
  FMemo.ScrollBars := ssVertical;
  FMemo.WordWrap := True;
  FMemo.BorderStyle := bsNone;
  FMemo.OnKeyDown := @MemoKeyDown;
end;

function TMessageInputPanel.GetText: string;
begin
  Result := FMemo.Text;
end;

procedure TMessageInputPanel.SetText(const AValue: string);
begin
  FMemo.Text := AValue;
end;

procedure TMessageInputPanel.ClearText;
begin
  FMemo.Clear;
end;

procedure TMessageInputPanel.SendBtnClick(Sender: TObject);
begin
  if Assigned(FOnSend) then begin
    FOnSend(Self);
  end;
end;

procedure TMessageInputPanel.MemoKeyDown(Sender: TObject; var Key: word; Shift: TShiftState);
begin
  if Key <> VK_RETURN then begin
    Exit;
  end;
  if ssCtrl in Shift then begin
    Exit;   { Ctrl+Enter — plain newline }
  end;
  Key := 0;   { suppress the newline — send instead }
  SendBtnClick(Self);
end;

end.
