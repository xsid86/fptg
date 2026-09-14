unit apisetup;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, Graphics, LCLIntf;

type

  { TFormApiConfig

    First-run dialog shown by tg.lpr when config.ini is missing or has
    no api_id/api_hash yet (TdApp.LoadConfig failed) — BEFORE any other
    form is created, so it cannot reach TdApp's account list or any of
    the usual ITdStateListener machinery, only TdApp.SaveApiCredentials/
    LoadConfig (tdcore.pas). ShowModal returns mrOk only once a valid
    pair has actually been saved AND re-read successfully — the caller
    in tg.lpr doesn't need to re-validate, just check the result. }

  TFormApiConfig = class(TForm)
    lblTitle:    TLabel;
    lblInfo:     TLabel;
    lblLink:     TLabel;
    lblApiId:    TLabel;
    edtApiId:    TEdit;
    lblApiHash:  TLabel;
    edtApiHash:  TEdit;
    btnOk:       TButton;
    btnCancel:   TButton;
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure lblLinkClick(Sender: TObject);
    procedure edtApiIdKeyPress(Sender: TObject; var Key: char);
    procedure btnOkClick(Sender: TObject);
  end;

var
  FormApiConfig: TFormApiConfig;

implementation

{$R *.lfm}

uses
  tdcore;

{ TFormApiConfig }

procedure TFormApiConfig.FormCreate(Sender: TObject);
begin
  Position := poScreenCenter;

  { Pre-fills whatever LoadConfig already parsed successfully — most
    often either both blank (true first run) or api_id set with
    api_hash still blank (a half-saved pair, e.g. after the file-lock
    failure SaveApiCredentials' comment describes) — so the user isn't
    made to retype a value that's already on disk. }
  if TdApp.ApiId <> 0 then begin
    edtApiId.Text := IntToStr(TdApp.ApiId);
  end;
  if TdApp.ApiHash <> '' then begin
    edtApiHash.Text := string(TdApp.ApiHash);
  end;
end;

{ SetFocus needs a window that is actually visible on screen — calling
  it from FormCreate raises "Can not focus" (EInvalidOperation),
  because the underlying HWND isn't shown yet at that point. FormShow
  fires once the window is on screen (right before ShowModal's own
  message loop starts), which is the earliest point SetFocus is valid.
  Focuses whichever field is still empty, not always edtApiId — with
  api_id already pre-filled (see FormCreate above), api_hash is the one
  actually worth landing the cursor in. }
procedure TFormApiConfig.FormShow(Sender: TObject);
begin
  if (edtApiId.Text = '') and edtApiId.CanFocus then begin
    edtApiId.SetFocus;
  end else if edtApiHash.CanFocus then begin
    edtApiHash.SetFocus;
  end;
end;

procedure TFormApiConfig.lblLinkClick(Sender: TObject);
begin
  OpenURL('https://my.telegram.org');
end;

{ Keeps the field numeric-only as the user types — api_id is always a
  plain integer, TryStrToInt in btnOkClick is the real validation, this
  just avoids letters slipping in unnoticed. Backspace/Delete/arrows
  etc. all arrive as control characters (<#32), not filtered. }
procedure TFormApiConfig.edtApiIdKeyPress(Sender: TObject; var Key: char);
begin
  if (Key < #32) or (Key in ['0'..'9']) then begin
    Exit;
  end;
  Key := #0;
end;

procedure TFormApiConfig.btnOkClick(Sender: TObject);
var
  ApiId: integer;
  ApiHash: string;
begin
  if not TryStrToInt(Trim(edtApiId.Text), ApiId) or (ApiId <= 0) then begin
    MessageDlg('Invalid API ID', 'API ID must be the numeric app_id shown on my.telegram.org.', mtError, [mbOK], 0);
    if edtApiId.CanFocus then begin
      edtApiId.SetFocus;
    end;
    Exit;
  end;

  ApiHash := Trim(edtApiHash.Text);
  if ApiHash = '' then begin
    MessageDlg('Invalid API hash', 'API hash cannot be empty.', mtError, [mbOK], 0);
    if edtApiHash.CanFocus then begin
      edtApiHash.SetFocus;
    end;
    Exit;
  end;

  TdApp.SaveApiCredentials(ApiId, utf8string(ApiHash));

  { Re-read config.ini the normal way rather than trusting the values
    just typed — the same single code path LoadConfig always uses,
    catching e.g. a config.ini the OS made read-only. }
  if not TdApp.LoadConfig then begin
    MessageDlg('Configuration Error', TdApp.ConfigError, mtError, [mbOK], 0);
    Exit;
  end;

  ModalResult := mrOk;
end;

end.
