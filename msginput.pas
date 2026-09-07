unit msginput;

{$mode objfpc}{$H+}

{ Панель ввода сообщения — по прямому запросу пользователя (2026-09-08):
  первый набросок layout'а, пока только текстовый ввод. Живёт в нижней
  части рабочей области (main.pas, pnlWork), отделена от области фреймов
  (TFrameNavigator) сплиттером — см. TFormMain.FormCreate.

  Три ряда сверху вниз: Toolbar (пустая панель, "на неё потом будем
  раскидывать кнопки" — вложений/форматирования и т.п., не в этом
  заходе), Memo (сам текст сообщения, растягивается на всё оставшееся
  место), ButtonRow (кнопка Send, выровнена по правому краю — "пока",
  остальные кнопки могут добавиться туда же позже).

  Построена целиком в коде (тем же приёмом, что TMediaViewerPanel,
  mediaviewer.pas) — не через дизайнер: не привязана к какому-либо
  конкретному чату/модели сама по себе (не тянет tdmessages/framehistory
  в uses) — просто источник текста и событие "нажали отправить", кому
  и что отправлять решает владелец (main.pas, у которого уже есть
  доступ и к TFrameNavigator.Current, и к TTdMessages) — тот же принцип
  разделения ответственности, что уже применяется у TMediaViewerPanel
  (AAudioDeviceName передаётся явно, а не читается из main.pas напрямую). }

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
    { Enter — отправить (тем же путём, что клик по Send); Ctrl+Enter —
      обычный перевод строки, штатное поведение TMemo, не трогаем. }
    procedure MemoKeyDown(Sender: TObject; var Key: word; Shift: TShiftState);
  public
    constructor Create(AOwner: TComponent); override;
    procedure ClearText;
    { Пустая панель сверху — задел под будущие кнопки (вложения,
      форматирование и т.п.), см. комментарий у юнита. }
    property Toolbar: TPanel read FToolbar;
    { Ряд кнопок под полем ввода — сейчас только Send, выровненная по
      правому краю; следующие кнопки — туда же, тем же Align=alRight
      (каждая следующая встанет левее уже добавленных). }
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

  { Порядок создания важен для Align: ряд кнопок и панель тулбара —
    первыми (alTop/alBottom), Memo — последним (alClient заполняет
    то, что осталось между ними). }
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
  { Raised — по прямому запросу пользователя, отличает панель (задел
    под будущие кнопки) от плоского фона остального поля ввода. }
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
    Exit;   { Ctrl+Enter — обычный перевод строки }
  end;
  Key := 0;   { подавляем перевод строки — вместо него отправляем }
  SendBtnClick(Self);
end;

end.
