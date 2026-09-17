unit settings;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, ComCtrls, ExtCtrls, StdCtrls,
  uiframe, framesettingsgeneral, framesettingsaudio, framesettingsautodownload,
  framesettingsstorage;

type

  { TFormSettings

    Modal settings window: a section TreeView on the left, the current
    section's frame on the right via TFrameNavigator (the same screen-
    switching mechanism as TFormMain/FNav). The section list is
    static, not a registry. }

  TFormSettings = class(TForm)
    pnlLeft:    TPanel;
    tvSections: TTreeView;
    pnlContent: TPanel;
    pnlButtons: TPanel;
    btnSave:    TButton;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure tvSectionsSelectionChanged(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
  private
    FNav: TFrameNavigator;
  end;

var
  FormSettings: TFormSettings;

implementation

{$R *.lfm}

{ TFormSettings }

procedure TFormSettings.FormCreate(Sender: TObject);
begin
  FNav := TFrameNavigator.Create(pnlContent);

  tvSections.Items.Clear;
  tvSections.Items.Add(nil, 'General');
  tvSections.Items.Add(nil, 'Audio');
  tvSections.Items.Add(nil, 'Auto download');
  tvSections.Items.Add(nil, 'Storage');
  tvSections.Selected := tvSections.Items[0];
  { Selecting the first item does not always fire OnSelectionChanged
    (depends on whether a node was already selected) — show the frame
    explicitly so the window never opens with an empty right panel. }
  FNav.ShowFrame(TFrameSettingsGeneral);
end;

procedure TFormSettings.FormDestroy(Sender: TObject);
begin
  FreeAndNil(FNav);
end;

procedure TFormSettings.tvSectionsSelectionChanged(Sender: TObject);
begin
  if tvSections.Selected = nil then begin
    Exit;
  end;
  case tvSections.Selected.Index of
    0: FNav.ShowFrame(TFrameSettingsGeneral);
    1: FNav.ShowFrame(TFrameSettingsAudio);
    2: FNav.ShowFrame(TFrameSettingsAutoDownload);
    3: FNav.ShowFrame(TFrameSettingsStorage);
  end;
end;

procedure TFormSettings.btnSaveClick(Sender: TObject);
var
  F: TFrameBase;
begin
  { Audio persists its selection immediately on click (see
    framesettingsaudio.pas) — nothing to save here. General has no
    settings. Auto download is saved only if the section was actually
    opened (Find <> nil) — otherwise its checkbox grid was never
    created and config.ini keeps its existing values. }
  F := FNav.Find(TFrameSettingsAutoDownload);
  if F <> nil then begin
    TFrameSettingsAutoDownload(F).SaveSettings;
  end;
  Close;
end;

end.
