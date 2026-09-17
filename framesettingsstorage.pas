unit framesettingsstorage;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, Spin, uiframe, tdstorage, constants;

type

  { TFrameSettingsStorage

    The "Storage" section of the settings window (TFormSettings): what
    TDLib's media cache currently weighs, the two limits that keep it
    from growing without end, and a button that applies them now
    instead of waiting for the next start.

    The limits save themselves as they are changed, the same "pick it,
    it's saved" pattern as the rest of the settings window — there is
    nothing here the Save button needs to collect.

    All the TDLib work belongs to tdstorage.pas, not to this frame.
    That is not tidiness: optimizeStorage can take minutes on a cache
    that has grown to gigabytes, and this frame dies with the settings
    dialog the moment the window is closed. A reply landing afterwards
    would call into freed memory — tdreq.pas has no way to cancel a
    pending request. So the long-lived TdStorage object does the
    talking and this frame only listens, while it exists. }

  TFrameSettingsStorage = class(TFrameBase)
    lblUsageCaption: TLabel;
    lblUsage: TLabel;
    lblDatabase: TLabel;
    lblLimit: TLabel;
    spnLimit: TSpinEdit;
    lblTtl: TLabel;
    spnTtl: TSpinEdit;
    btnCleanup: TButton;
    lblStatus: TLabel;
    procedure spnLimitChange(Sender: TObject);
    procedure spnTtlChange(Sender: TObject);
    procedure btnCleanupClick(Sender: TObject);
  protected
    procedure DoActivate; override;
    procedure DoDeactivate; override;
  public
    destructor Destroy; override;
  private
    { Same guard as the other settings frames: suppresses saving while
      the spin edits are being filled from FormMain in DoActivate. }
    FLoading: boolean;
    procedure Subscribe;
    procedure Unsubscribe;
    procedure StorageChanged(Sender: TObject);
    procedure UpdateDisplay;
  end;

implementation

{$R *.lfm}

{ main is used only in the implementation section — the interface of
  main.pas already pulls in the settings window, so the other
  direction would be a circular unit reference. Same as every other
  settings frame. }
uses
  main;

{ TFrameSettingsStorage }

destructor TFrameSettingsStorage.Destroy;
begin
  { The real safety net. DoDeactivate covers switching to another
    section, but closing the window while THIS section is open never
    calls it — the frame just goes away with the dialog. }
  Unsubscribe;
  inherited Destroy;
end;

procedure TFrameSettingsStorage.Subscribe;
begin
  TdCache.OnChanged := @StorageChanged;
end;

procedure TFrameSettingsStorage.Unsubscribe;
begin
  { Only if it is still ours: a single-listener event, and clearing
    someone else's subscription would silently break them. Compared
    through TMethod.Data — in objfpc mode @SomeMethod is a code
    pointer, not a method pointer, so it cannot be compared to an
    event directly. }
  if TMethod(TdCache.OnChanged).Data = Pointer(Self) then begin
    TdCache.OnChanged := nil;
  end;
end;

procedure TFrameSettingsStorage.DoActivate;
begin
  Subscribe;
  FLoading := True;
  try
    spnLimit.MinValue := CACHE_LIMIT_MIN_MB;
    spnLimit.MaxValue := CACHE_LIMIT_MAX_MB;
    spnLimit.Value := FormMain.CacheLimitMB;
    spnTtl.MinValue := CACHE_TTL_MIN_DAYS;
    spnTtl.MaxValue := CACHE_TTL_MAX_DAYS;
    spnTtl.Value := FormMain.CacheTtlDays;
  finally
    FLoading := False;
  end;
  UpdateDisplay;
  { Asked for on every visit rather than once: the numbers move while
    the app runs (every prefetched video adds to them), and a cached
    figure from the last time the window was open would be fiction. }
  TdCache.RefreshStats;
end;

procedure TFrameSettingsStorage.DoDeactivate;
begin
  Unsubscribe;
end;

procedure TFrameSettingsStorage.StorageChanged(Sender: TObject);
begin
  UpdateDisplay;
end;

procedure TFrameSettingsStorage.UpdateDisplay;
var
  St: TTdStorageStats;
begin
  St := TdCache.Stats;
  if St.Known then begin
    lblUsage.Caption := Format('%s in %d files',
      [FormatBytes(St.FilesSize), St.FileCount]);
    lblDatabase.Caption := Format('Database: %s, log: %s',
      [FormatBytes(St.DatabaseSize), FormatBytes(St.LogSize)]);
  end else begin
    lblUsage.Caption := 'not measured yet';
    lblDatabase.Caption := '';
  end;

  { One button, three states to say something about: running, failed,
    finished. Silence after a cleanup that deleted nothing would read
    as "the button does nothing". }
  btnCleanup.Enabled := not TdCache.Busy;
  if TdCache.Busy then begin
    lblStatus.Caption := 'Working...';
  end else if TdCache.LastError <> '' then begin
    lblStatus.Caption := string(TdCache.LastError);
  end else if TdCache.LastFreedCount > 0 then begin
    lblStatus.Caption := Format('Freed %s in %d files',
      [FormatBytes(TdCache.LastFreed), TdCache.LastFreedCount]);
  end else begin
    lblStatus.Caption := '';
  end;
end;

procedure TFrameSettingsStorage.spnLimitChange(Sender: TObject);
begin
  if FLoading then begin
    Exit;
  end;
  { Saved, but NOT applied here: dragging a spin edit down to 100 MB
    would otherwise delete most of the cache on the way past every
    intermediate value. It takes effect at the next start, or right
    now via the button. }
  FormMain.SetCacheLimitMB(spnLimit.Value);
end;

procedure TFrameSettingsStorage.spnTtlChange(Sender: TObject);
begin
  if FLoading then begin
    Exit;
  end;
  FormMain.SetCacheTtlDays(spnTtl.Value);
end;

procedure TFrameSettingsStorage.btnCleanupClick(Sender: TObject);
begin
  { The spin edits' current values rather than FormMain's, so a limit
    typed a second ago applies without leaving the field first. They
    are the same thing in every other case — OnChange already saved
    them. }
  TdCache.Cleanup(spnLimit.Value, spnTtl.Value);
  UpdateDisplay;
end;

end.
