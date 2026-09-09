unit msginput;

{$mode objfpc}{$H+}

{ Message input panel. Lives at the bottom of the work area (main.pas,
  pnlWork), separated from the frame area (TFrameNavigator) by a
  splitter — see TFormMain.FormCreate.

  Three rows top to bottom: Toolbar (text-formatting buttons plus the
  HTML/Markdown mode switch, see below), Memo (the message text, fills
  the remaining space), ButtonRow (Send button, right-aligned; further
  buttons can be added to the same row).

  Built entirely in code, not via the designer: not bound to any
  particular chat/model itself (does not pull tdmessages/framehistory
  into uses) — it is just a text source plus a "send clicked" event;
  the owner (main.pas, which already has access to both
  TFrameNavigator.Current and TTdMessages) decides who and what to
  send.

  Formatting toolbar — NOT a WYSIWYG rich-text editor (TMemo is a plain
  Windows edit control, it cannot render bold/italic inline at all, and
  replacing it with a custom owner-drawn one is well outside this
  pass's scope, the same conclusion already reached for colored emoji
  in this same input box). Instead, each button wraps the current
  selection in Telegram's OWN marked-up syntax — either MarkdownV2
  (*bold*, _italic_, __underline__, ~strike~, ||spoiler||, `code`,
  ```code block```, [text](url), a '>' per line for blockquote) or HTML
  (<b>, <i>, <u>, <s>, <tg-spoiler>, <code>, <pre>, <a href>,
  <blockquote>) — confirmed against
  core.telegram.org/bots/api and TDLib's own text-parse-mode docs, not
  guessed. FHtmlModeBox selects which syntax gets inserted; the SAME
  choice is read by the owner (TFormMain.MessageInputSend) at send time
  to tell TTdMessages.SendFormattedText which parser to run the whole
  message through (parseTextEntities — see tdmessages.pas). Nothing
  here builds a real TDLib text entity directly; the marked-up string
  is just plain text with visible punctuation/tags in the TMemo, same
  as typing it by hand, until parseTextEntities turns it into one at
  send time.

  A caveat worth keeping in mind: the OFFICIAL menus in the reference
  screenshots also had "Cite" (=Quote/blockquote, included below),
  "Translate" (not a formatting entity — calls a completely different
  TDLib method on already-typed text, out of scope here) and a "Date"
  item (Telegram's tg-time countdown entity, a genuinely separate,
  fairly exotic feature, not implemented in this pass — TDLib's own
  parseTextEntities documentation does not list a date/time entity
  among what it parses). }

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ExtCtrls, Buttons, Graphics,
  Dialogs, LCLType;

type
  TMessageInputPanel = class(TCustomControl)
  private
    FToolbar: TPanel;
    FButtonRow: TPanel;
    FMemo: TMemo;
    FSendBtn: TBitBtn;
    FBoldBtn, FItalicBtn, FUnderlineBtn, FStrikeBtn, FMonoBtn, FCodeBtn,
      FSpoilerBtn, FQuoteBtn, FLinkBtn, FClearFmtBtn: TBitBtn;
    FHtmlModeBox: TCheckBox;
    FOnSend: TNotifyEvent;
    function GetText: string;
    procedure SetText(const AValue: string);
    function GetIsHtmlMode: boolean;
    procedure SendBtnClick(Sender: TObject);
    { Enter sends (same path as clicking Send); Ctrl+Enter inserts a
      newline, TMemo's default behavior, left untouched. }
    procedure MemoKeyDown(Sender: TObject; var Key: word; Shift: TShiftState);
    { Wraps the current TMemo selection in the delimiter/tag pair
      matching the current mode (plain args for Markdown, html args for
      HTML — see FHtmlModeBox). With nothing selected, both markers are
      inserted anyway and the cursor is left BETWEEN them, ready to type
      the formatted text directly; with a real selection, the whole
      wrapped result is left selected afterward so another button can
      be applied right on top of it (e.g. bold+italic together). }
    procedure WrapSelection(const APlainOpen, APlainClose, AHtmlOpen, AHtmlClose: string);
    procedure BoldBtnClick(Sender: TObject);
    procedure ItalicBtnClick(Sender: TObject);
    procedure UnderlineBtnClick(Sender: TObject);
    procedure StrikeBtnClick(Sender: TObject);
    procedure MonoBtnClick(Sender: TObject);
    { Multi-line code BLOCK (``` fences / <pre>), distinct from the
      single-backtick/inline Mono button above — Telegram's own
      composer offers both. }
    procedure CodeBtnClick(Sender: TObject);
    procedure SpoilerBtnClick(Sender: TObject);
    { Not a simple wrap: MarkdownV2 blockquote is a '>' prefix on EVERY
      line of the quoted text (see core.telegram.org/bots/api), not an
      open/close pair — a plain WrapSelection would only quote the
      first line. HTML blockquote IS a simple wrap, handled inline. }
    procedure QuoteBtnClick(Sender: TObject);
    { Prompts for link text (if nothing is selected) and a URL via two
      small InputQuery dialogs, then inserts [text](url) or
      <a href="url">text</a> depending on mode. }
    procedure LinkBtnClick(Sender: TObject);
    { Best-effort, not a real parser: strips the delimiter
      characters/tags themselves out of the selection, for whichever
      mode is currently active. A literal '*'/'_'/etc. the user typed
      on purpose, indistinguishable from a formatting marker in this
      plain-marked-up-text model, gets stripped too — same trade-off
      the toolbar's insertion side already accepts. }
    procedure ClearFmtBtnClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure ClearText;
    { Formatting toolbar at the top — see the unit header comment. }
    property Toolbar: TPanel read FToolbar;
    { Button row below the input field — currently only Send,
      right-aligned; further buttons go into the same row with
      Align=alRight (each new one lands to the left of the previous). }
    property ButtonRow: TPanel read FButtonRow;
    property Text: string read GetText write SetText;
    { True = the toolbar buttons insert HTML tags and
      TFormMain.MessageInputSend should ask TDLib to parse the message
      as HTML; False = MarkdownV2. }
    property IsHtmlMode: boolean read GetIsHtmlMode;
    property OnSend: TNotifyEvent read FOnSend write FOnSend;
  end;

implementation

const
  MSGINPUT_TOOLBAR_H = 36;
  MSGINPUT_BUTTONROW_H = 40;
  MSGINPUT_PAD = 8;
  MSGINPUT_SEND_W = 90;
  { Formatting-button widths — short captions for now (BitButtons,
    text only), by direct request: icons replace the captions later,
    the exact widths will stop mattering once that happens. }
  MSGINPUT_FMTBTN_W = 44;
  MSGINPUT_FMTBTN_WIDE = 64;
  MSGINPUT_MODEBOX_W = 60;

constructor TMessageInputPanel.Create(AOwner: TComponent);

  { Local helper — the nine formatting buttons only differ by parent,
    caption, width and click handler; spelling all of that out nine
    times separately would just be the same six lines copy-pasted. }
  function AddFmtBtn(const ACaption: string; AWidth: integer;
    AOnClick: TNotifyEvent): TBitBtn;
  begin
    Result := TBitBtn.Create(Self);
    Result.Parent := FToolbar;
    Result.Caption := ACaption;
    Result.Align := alLeft;
    Result.Width := AWidth;
    Result.BorderSpacing.Around := MSGINPUT_PAD div 4;
    Result.OnClick := AOnClick;
  end;

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

  { Left to right, in creation order (LCL places same-Align siblings in
    the order they were added to Controls) — matches the order in the
    reference screenshots as closely as the trimmed-down button set
    allows (Translate/Date left out, see the unit header comment). }
  FBoldBtn      := AddFmtBtn('B', MSGINPUT_FMTBTN_W, @BoldBtnClick);
  FItalicBtn    := AddFmtBtn('I', MSGINPUT_FMTBTN_W, @ItalicBtnClick);
  FUnderlineBtn := AddFmtBtn('U', MSGINPUT_FMTBTN_W, @UnderlineBtnClick);
  FStrikeBtn    := AddFmtBtn('S', MSGINPUT_FMTBTN_W, @StrikeBtnClick);
  FMonoBtn      := AddFmtBtn('Mono', MSGINPUT_FMTBTN_WIDE, @MonoBtnClick);
  FCodeBtn      := AddFmtBtn('Code', MSGINPUT_FMTBTN_WIDE, @CodeBtnClick);
  FSpoilerBtn   := AddFmtBtn('Spoiler', MSGINPUT_FMTBTN_WIDE, @SpoilerBtnClick);
  FQuoteBtn     := AddFmtBtn('Quote', MSGINPUT_FMTBTN_WIDE, @QuoteBtnClick);
  FLinkBtn      := AddFmtBtn('Link', MSGINPUT_FMTBTN_WIDE, @LinkBtnClick);
  FClearFmtBtn  := AddFmtBtn('Clear', MSGINPUT_FMTBTN_WIDE, @ClearFmtBtnClick);

  { Mode switch — read by both the buttons above (which syntax to
    insert) and the owner, at send time (which TDLib parser to run the
    result through, see TMessageInputPanel.IsHtmlMode's own comment).
    Unchecked = Markdown, the default: shorter, easier to type by hand
    than HTML tags. }
  FHtmlModeBox := TCheckBox.Create(Self);
  FHtmlModeBox.Parent := FToolbar;
  FHtmlModeBox.Caption := 'HTML';
  FHtmlModeBox.Align := alRight;
  FHtmlModeBox.Width := MSGINPUT_MODEBOX_W;
  FHtmlModeBox.BorderSpacing.Around := MSGINPUT_PAD div 4;

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

function TMessageInputPanel.GetIsHtmlMode: boolean;
begin
  Result := FHtmlModeBox.Checked;
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

procedure TMessageInputPanel.WrapSelection(const APlainOpen, APlainClose,
  AHtmlOpen, AHtmlClose: string);
var
  Open, Close, Sel: string;
  StartPos, Len: integer;
begin
  if IsHtmlMode then begin
    Open := AHtmlOpen;
    Close := AHtmlClose;
  end else begin
    Open := APlainOpen;
    Close := APlainClose;
  end;

  StartPos := FMemo.SelStart;
  Len := FMemo.SelLength;
  Sel := FMemo.SelText;
  FMemo.SelText := Open + Sel + Close;

  if Len = 0 then begin
    FMemo.SelStart := StartPos + Length(Open);
    FMemo.SelLength := 0;
  end else begin
    FMemo.SelStart := StartPos;
    FMemo.SelLength := Length(Open) + Len + Length(Close);
  end;
  FMemo.SetFocus;
end;

procedure TMessageInputPanel.BoldBtnClick(Sender: TObject);
begin
  WrapSelection('*', '*', '<b>', '</b>');
end;

procedure TMessageInputPanel.ItalicBtnClick(Sender: TObject);
begin
  WrapSelection('_', '_', '<i>', '</i>');
end;

procedure TMessageInputPanel.UnderlineBtnClick(Sender: TObject);
begin
  WrapSelection('__', '__', '<u>', '</u>');
end;

procedure TMessageInputPanel.StrikeBtnClick(Sender: TObject);
begin
  WrapSelection('~', '~', '<s>', '</s>');
end;

procedure TMessageInputPanel.MonoBtnClick(Sender: TObject);
begin
  WrapSelection('`', '`', '<code>', '</code>');
end;

procedure TMessageInputPanel.CodeBtnClick(Sender: TObject);
begin
  WrapSelection('```', '```', '<pre>', '</pre>');
end;

procedure TMessageInputPanel.SpoilerBtnClick(Sender: TObject);
begin
  WrapSelection('||', '||', '<tg-spoiler>', '</tg-spoiler>');
end;

procedure TMessageInputPanel.QuoteBtnClick(Sender: TObject);
var
  StartPos: integer;
  Sel, Quoted: string;
begin
  StartPos := FMemo.SelStart;
  Sel := FMemo.SelText;

  if IsHtmlMode then begin
    Quoted := '<blockquote>' + Sel + '</blockquote>';
    FMemo.SelText := Quoted;
    if Sel = '' then begin
      FMemo.SelStart := StartPos + Length('<blockquote>');
      FMemo.SelLength := 0;
    end else begin
      FMemo.SelStart := StartPos;
      FMemo.SelLength := Length(Quoted);
    end;
  end else begin
    { '>' at the start, and again right after every line break in the
      selection — LineEnding matches what TMemo.SelText itself uses on
      this platform, so this only ever inserts breaks that were already
      there. }
    Quoted := '>' + StringReplace(Sel, LineEnding, LineEnding + '>', [rfReplaceAll]);
    FMemo.SelText := Quoted;
    FMemo.SelStart := StartPos;
    FMemo.SelLength := Length(Quoted);
  end;
  FMemo.SetFocus;
end;

procedure TMessageInputPanel.LinkBtnClick(Sender: TObject);
var
  StartPos: integer;
  LinkText, Url, Inserted: string;
begin
  StartPos := FMemo.SelStart;
  LinkText := FMemo.SelText;

  if LinkText = '' then begin
    if not InputQuery('Add link', 'Link text:', LinkText) then begin
      Exit;
    end;
    if Trim(LinkText) = '' then begin
      Exit;
    end;
  end;

  Url := 'https://';
  if not InputQuery('Add link', 'URL:', Url) then begin
    Exit;
  end;
  if Trim(Url) = '' then begin
    Exit;
  end;

  if IsHtmlMode then begin
    Inserted := '<a href="' + Url + '">' + LinkText + '</a>';
  end else begin
    Inserted := '[' + LinkText + '](' + Url + ')';
  end;

  FMemo.SelText := Inserted;
  FMemo.SelStart := StartPos;
  FMemo.SelLength := Length(Inserted);
  FMemo.SetFocus;
end;

{ [text](url) -> text, for ClearFmtBtnClick's Markdown branch — the one
  piece of Markdown syntax that isn't a single repeated delimiter
  character, so the simple StringReplace approach used for the rest
  doesn't cover it. }
function StripMarkdownLinks(const AText: string): string;
var
  I, CloseBracket, CloseParen: integer;
begin
  Result := '';
  I := 1;
  while I <= Length(AText) do begin
    if AText[I] = '[' then begin
      CloseBracket := I + 1;
      while (CloseBracket <= Length(AText)) and (AText[CloseBracket] <> ']') do begin
        Inc(CloseBracket);
      end;
      if (CloseBracket < Length(AText)) and (AText[CloseBracket + 1] = '(') then begin
        CloseParen := CloseBracket + 2;
        while (CloseParen <= Length(AText)) and (AText[CloseParen] <> ')') do begin
          Inc(CloseParen);
        end;
        Result := Result + Copy(AText, I + 1, CloseBracket - I - 1);
        I := CloseParen + 1;
        Continue;
      end;
    end;
    Result := Result + AText[I];
    Inc(I);
  end;
end;

procedure TMessageInputPanel.ClearFmtBtnClick(Sender: TObject);
var
  StartPos, I: integer;
  Sel, Plain: string;
begin
  StartPos := FMemo.SelStart;
  Sel := FMemo.SelText;
  if Sel = '' then begin
    Exit;
  end;

  if IsHtmlMode then begin
    { Strips ANY <tag> found in the selection, not just the specific
      ones this toolbar itself inserts — a reasonable "remove all
      formatting" for a plain-marked-up-text editor with no real
      entity tracking of its own. }
    Plain := '';
    I := 1;
    while I <= Length(Sel) do begin
      if Sel[I] = '<' then begin
        while (I <= Length(Sel)) and (Sel[I] <> '>') do begin
          Inc(I);
        end;
        Inc(I);   { skip the '>' itself too }
      end else begin
        Plain := Plain + Sel[I];
        Inc(I);
      end;
    end;
  end else begin
    Plain := StripMarkdownLinks(Sel);
    Plain := StringReplace(Plain, '*', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, '_', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, '~', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, '|', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, '`', '', [rfReplaceAll]);
    Plain := StringReplace(Plain, LineEnding + '>', LineEnding, [rfReplaceAll]);
    if (Length(Plain) > 0) and (Plain[1] = '>') then begin
      Delete(Plain, 1, 1);
    end;
  end;

  FMemo.SelText := Plain;
  FMemo.SelStart := StartPos;
  FMemo.SelLength := Length(Plain);
  FMemo.SetFocus;
end;

end.
