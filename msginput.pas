unit msginput;

{$mode objfpc}{$H+}

{ Message input panel. Lives at the bottom of the work area (main.pas,
  pnlWork), separated from the frame area (TFrameNavigator) by a
  splitter — see TFormMain.FormCreate.

  Three rows top to bottom: Toolbar (text-formatting TextEditPanel plus the
  HTML/Markdown mode switch, see below), Memo (the message text, fills
  the remaining space), ButtonRow (Send button, right-aligned; further
  TextEditPanel can be added to the same row).

  A real TFrame with a paired .lfm (msginput.lfm) — unlike most of the
  media-viewer/settings code added earlier in this project, this one is
  meant to be laid out visually in the Lazarus Designer (drag icons onto
  the TextEditPanel, reorder them, set ChildSizing on Memo's parent, etc.),
  not built in code. Toolbar/ButtonRow/Memo/the format TextEditPanel are
  therefore plain published fields, streamed from the .lfm, not
  programmatically created in a constructor.

  Not bound to any particular chat/model itself (does not pull
  tdmessages/framehistory/main into uses) — it is just a text source
  plus a "send clicked" event; the owner (main.pas, which already has
  access to both TFrameNavigator.Current and TTdMessages) decides who
  and what to send.

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
  guessed. HtmlModeBox selects which syntax gets inserted; the SAME
  choice is read by the owner (TFormMain.MessageInputSend) at send time
  to tell TTdMessages.SendFormattedText which parser to run the whole
  message through (parseTextEntities — see tdmessages.pas). Nothing
  here builds a real TDLib text entity directly; the marked-up string
  is just plain text with visible punctuation/tags in the TMemo, same
  as typing it by hand, until parseTextEntities turns it into one at
  send time (which also escapes any stray reserved punctuation in the
  rest of the message — see EscapeMarkdownV2/EscapeHtml there).

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
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Buttons,
  Dialogs, LCLType;

type

  { TMessageInputPanel }

  TMessageInputPanel = class(TFrame)
    BoldBtn: TSpeedButton;
    ClearFmtBtn: TSpeedButton;
    CodeBtn: TSpeedButton;
    ItalicBtn: TSpeedButton;
    LinkBtn: TSpeedButton;
    MonoBtn: TSpeedButton;
    QuoteBtn: TSpeedButton;
    SpoilerBtn: TSpeedButton;
    StrikeBtn: TSpeedButton;
    TextEditIcons: TImageList;
    Toolbar: TPanel;
    SendBtn: TBitBtn;
    HtmlModeBox: TCheckBox;
    Memo: TMemo;
    UnderlineBtn: TSpeedButton;
    procedure SendBtnClick(Sender: TObject);
    { Enter sends (same path as clicking Send); Ctrl+Enter inserts a
      newline, TMemo's default behavior, left untouched. }
    procedure MemoKeyDown(Sender: TObject; var Key: word; Shift: TShiftState);
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
  private
    FOnSend: TNotifyEvent;
    function GetText: string;
    procedure SetText(const AValue: string);
    function GetIsHtmlMode: boolean;
    { Wraps the current Memo selection in the delimiter/tag pair
      matching the current mode (plain args for Markdown, html args for
      HTML — see HtmlModeBox). With nothing selected, both markers are
      inserted anyway and the cursor is left BETWEEN them, ready to type
      the formatted text directly; with a real selection, the whole
      wrapped result is left selected afterward so another button can
      be applied right on top of it (e.g. bold+italic together). }
    procedure WrapSelection(const APlainOpen, APlainClose, AHtmlOpen, AHtmlClose: string);
  public
    procedure ClearText;
    property Text: string read GetText write SetText;
    { True = the toolbar buttons insert HTML tags and
      TFormMain.MessageInputSend should ask TDLib to parse the message
      as HTML; False = MarkdownV2. }
    property IsHtmlMode: boolean read GetIsHtmlMode;
    property OnSend: TNotifyEvent read FOnSend write FOnSend;
  end;

implementation

{$R *.lfm}

function TMessageInputPanel.GetText: string;
begin
  Result := Memo.Text;
end;

procedure TMessageInputPanel.SetText(const AValue: string);
begin
  Memo.Text := AValue;
end;

function TMessageInputPanel.GetIsHtmlMode: boolean;
begin
  Result := HtmlModeBox.Checked;
end;

procedure TMessageInputPanel.ClearText;
begin
  Memo.Clear;
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

  StartPos := Memo.SelStart;
  Len := Memo.SelLength;
  Sel := Memo.SelText;
  Memo.SelText := Open + Sel + Close;

  if Len = 0 then begin
    Memo.SelStart := StartPos + Length(Open);
    Memo.SelLength := 0;
  end else begin
    Memo.SelStart := StartPos;
    Memo.SelLength := Length(Open) + Len + Length(Close);
  end;
  Memo.SetFocus;
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
  StartPos := Memo.SelStart;
  Sel := Memo.SelText;

  if IsHtmlMode then begin
    Quoted := '<blockquote>' + Sel + '</blockquote>';
    Memo.SelText := Quoted;
    if Sel = '' then begin
      Memo.SelStart := StartPos + Length('<blockquote>');
      Memo.SelLength := 0;
    end else begin
      Memo.SelStart := StartPos;
      Memo.SelLength := Length(Quoted);
    end;
  end else begin
    { '>' at the start, and again right after every line break in the
      selection — LineEnding matches what Memo.SelText itself uses on
      this platform, so this only ever inserts breaks that were already
      there. }
    Quoted := '>' + StringReplace(Sel, LineEnding, LineEnding + '>', [rfReplaceAll]);
    Memo.SelText := Quoted;
    Memo.SelStart := StartPos;
    Memo.SelLength := Length(Quoted);
  end;
  Memo.SetFocus;
end;

procedure TMessageInputPanel.LinkBtnClick(Sender: TObject);
var
  StartPos: integer;
  LinkText, Url, Inserted: string;
begin
  StartPos := Memo.SelStart;
  LinkText := Memo.SelText;

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

  Memo.SelText := Inserted;
  Memo.SelStart := StartPos;
  Memo.SelLength := Length(Inserted);
  Memo.SetFocus;
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
  StartPos := Memo.SelStart;
  Sel := Memo.SelText;
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

  Memo.SelText := Plain;
  Memo.SelStart := StartPos;
  Memo.SelLength := Length(Plain);
  Memo.SetFocus;
end;

end.
