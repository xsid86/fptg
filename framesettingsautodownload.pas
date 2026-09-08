unit framesettingsautodownload;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, IniFiles, uiframe,
  tdcore, constants;

type

  { TFrameSettingsAutoDownload

    The "Auto download" settings section — a 5x5 grid: one TGroupBox
    per media type (AUTODL_MEDIA_KINDS), each holding a column of
    checkboxes, one per chat type (AUTODL_CHAT_KINDS). Each section
    sizes itself to its checkboxes (AutoSize + ChildSizing,
    ControlsPerLine=1 — one checkbox per row); sections wrap to a new
    row when the next one no longer fits the available width
    (ReflowSections, a manual CSS-like flex-wrap — LCL's ChildSizing
    has no built-in equivalent, see the constructor comment). The
    container (TScrollBox) never scrolls horizontally — by
    construction no section can exceed its width; only vertical
    scrolling applies if the wrapped rows exceed the visible height.

    Only displays and persists the selected values to
    config.ini/[autodownload] (SaveSettings/LoadSettings) — the actual
    auto-download logic driven by these flags lives elsewhere. }

  TFrameSettingsAutoDownload = class(TFrameBase)
  private
    FScroll: TScrollBox;
    FGroups: array[0..High(AUTODL_MEDIA_KINDS)] of TGroupBox;
    { FBoxes[media][chat] — the checkbox grid, built once in the
      constructor; DoActivate/SaveSettings only read/write Checked,
      they never rebuild the grid. }
    FBoxes: array[0..High(AUTODL_MEDIA_KINDS)] of array[0..High(AUTODL_CHAT_KINDS)] of TCheckBox;
    procedure BuildGrid;
    procedure ReflowSections(Sender: TObject);
  protected
    procedure DoActivate; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure LoadSettings;
    procedure SaveSettings;
  end;

implementation

{$R *.lfm}

{ main is used only in the implementation section, not the interface,
  to avoid a circular unit dependency (same approach as
  framesettingsaudio.pas) — the in-memory source of truth for these
  settings lives on FormMain; SaveSettings only refreshes it after
  writing. }
uses
  main;

const
  SECTION_GAP = 5;

{ TFrameSettingsAutoDownload }

constructor TFrameSettingsAutoDownload.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  FScroll := TScrollBox.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alClient;
  FScroll.BorderStyle := bsNone;
  { No horizontal scrolling. ReflowSections below guarantees that no
    section is ever wider than the container (within the window's
    reasonable width, Constraints.MinWidth=480 on TFormSettings
    itself), so horizontal scrolling is never needed. Vertical
    scrolling is left as the default AutoScroll, in case wrapped rows
    exceed the visible height. }
  FScroll.HorzScrollBar.Visible := False;
  FScroll.OnResize := @ReflowSections;

  BuildGrid;
end;

procedure TFrameSettingsAutoDownload.BuildGrid;
var
  M, C: integer;
  Grp: TGroupBox;
  Cb: TCheckBox;
begin
  for M := 0 to High(AUTODL_MEDIA_KINDS) do begin
    Grp := TGroupBox.Create(Self);
    Grp.Parent := FScroll;
    Grp.Caption := AUTODL_MEDIA_CAPTIONS[M];
    { The section sizes itself to its checkboxes (AutoSize), one
      checkbox per row — a single column, not a multi-column table. }
    Grp.ChildSizing.Layout := cclLeftToRightThenTopToBottom;
    Grp.ChildSizing.ControlsPerLine := 1;
    Grp.ChildSizing.LeftRightSpacing := 5;
    Grp.ChildSizing.TopBottomSpacing := 5;
    Grp.ChildSizing.VerticalSpacing := 5;
    Grp.AutoSize := True;
    FGroups[M] := Grp;

    for C := 0 to High(AUTODL_CHAT_KINDS) do begin
      Cb := TCheckBox.Create(Self);
      Cb.Parent := Grp;
      Cb.Caption := AUTODL_CHAT_CAPTIONS[C];
      FBoxes[M][C] := Cb;
    end;

    { Force an immediate AutoSize recalculation — ReflowSections below
      must read the section's actual content-fitted width/height, not
      the default size from TGroupBox creation. }
    Grp.AdjustSize;
  end;

  ReflowSections(nil);
end;

{ A manually implemented CSS-like flex-wrap: sections flow left to
  right as long as they fit the container's width; one that doesn't
  fit wraps to a new row. LCL's ChildSizing has no built-in equivalent
  — ControlsPerLine=0 there does not mean "wrap by width"; it
  degenerates to the same single-column table as ControlsPerLine=1
  (see TAutoSizeBox.SetTableControls in wincontrol.inc: Max(1, Min(0,
  Count)) = 1) — a fixed table for a known number of columns/rows, not
  adaptive wrapping. }
procedure TFrameSettingsAutoDownload.ReflowSections(Sender: TObject);
var
  I, X, Y, RowH, AvailW: integer;
  Grp: TGroupBox;
begin
  AvailW := FScroll.ClientWidth;
  if AvailW <= 0 then begin
    Exit;
  end;
  X := SECTION_GAP;
  Y := SECTION_GAP;
  RowH := 0;
  for I := 0 to High(AUTODL_MEDIA_KINDS) do begin
    Grp := FGroups[I];
    if (X > SECTION_GAP) and (X + Grp.Width > AvailW) then begin
      X := SECTION_GAP;
      Inc(Y, RowH + SECTION_GAP);
      RowH := 0;
    end;
    Grp.SetBounds(X, Y, Grp.Width, Grp.Height);
    Inc(X, Grp.Width + SECTION_GAP);
    if Grp.Height > RowH then begin
      RowH := Grp.Height;
    end;
  end;
end;

procedure TFrameSettingsAutoDownload.DoActivate;
begin
  LoadSettings;
end;

procedure TFrameSettingsAutoDownload.LoadSettings;
var
  M, C: integer;
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(TdApp.BaseDir + 'config.ini');
  try
    for M := 0 to High(AUTODL_MEDIA_KINDS) do begin
      for C := 0 to High(AUTODL_CHAT_KINDS) do begin
        FBoxes[M][C].Checked := Ini.ReadBool('autodownload',
          AUTODL_MEDIA_KINDS[M] + '.' + AUTODL_CHAT_KINDS[C], False);
      end;
    end;
  finally
    Ini.Free;
  end;
end;

procedure TFrameSettingsAutoDownload.SaveSettings;
var
  M, C: integer;
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(TdApp.BaseDir + 'config.ini');
  try
    for M := 0 to High(AUTODL_MEDIA_KINDS) do begin
      for C := 0 to High(AUTODL_CHAT_KINDS) do begin
        Ini.WriteBool('autodownload',
          AUTODL_MEDIA_KINDS[M] + '.' + AUTODL_CHAT_KINDS[C], FBoxes[M][C].Checked);
      end;
    end;
  finally
    Ini.Free;
  end;
  { The single in-memory source of truth for the session is
    FormMain.FAutoDownload (framehistory.pas reads through it, it
    never parses config.ini itself) — without this refresh, the
    values just saved would not take effect until the app restarts. }
  FormMain.LoadAutoDownloadSettings;
end;

end.
