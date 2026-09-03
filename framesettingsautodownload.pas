unit framesettingsautodownload;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, IniFiles, uiframe,
  tdcore, constants;

type

  { TFrameSettingsAutoDownload

    Раздел "Auto download" окна настроек — сетка 5×5: секция (TGroupBox)
    на каждый тип медиа (AUTODL_MEDIA_KINDS), внутри секции столбиком —
    чекбокс на каждый тип чата (AUTODL_CHAT_KINDS). Каждая секция сама
    облегает свои чекбоксы (AutoSize + собственный ChildSizing,
    ControlsPerLine=1 — один чекбокс на строку) — секции внутри
    контейнера переносятся на новую строку, когда очередная не
    помещается по ширине (ReflowSections, CSS-подобный flex-wrap;
    готовой такой раскладки в LCL ChildSizing нет — см. комментарий в
    конструкторе). Контейнер (TScrollBox) не прокручивается по
    горизонтали — по построению ни одна секция не должна вылезать за
    его ширину, только по вертикали, если перенесённых строк наберётся
    больше, чем помещается по высоте.

    Пока только отображение и персистенс выбранных значений в
    config.ini/[autodownload] (SaveSettings/LoadSettings) — сама логика
    авто-скачивания по этим флагам не подключена, это отдельная,
    отдельно заводимая задача. }

  TFrameSettingsAutoDownload = class(TFrameBase)
  private
    FScroll: TScrollBox;
    FGroups: array[0..High(AUTODL_MEDIA_KINDS)] of TGroupBox;
    { FBoxes[медиа][чат] — сетка чекбоксов, строится один раз в
      конструкторе; DoActivate/SaveSettings только читают/пишут
      Checked, сетку не пересоздают. }
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

{ main — только в реализации, не в интерфейсе: тот же приём, что и у
  framesettingsaudio.pas (FormMain.AudioDeviceName/SetAudioDeviceName)
  — единственный источник правды в памяти для прочитанных настроек
  живёт на FormMain, SaveSettings его только освежает после записи. }
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
  { По прямому запросу пользователя — не должен прокручиваться по
    горизонтали. ReflowSections ниже гарантирует, что ни одна секция
    сама по себе не шире контейнера (в разумных пределах ширины окна,
    Constraints.MinWidth=480 у самого TFormSettings), так что
    горизонтальный скролл в принципе не нужен. Вертикальный оставлен
    как есть (AutoScroll по умолчанию) — на случай, если перенесённых
    строк наберётся больше, чем видимая высота. }
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
    { По прямому запросу пользователя: секция сама облегает свои
      чекбоксы (AutoSize), один чекбокс на строку — столбик, не
      таблица в несколько колонок. }
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

    { Форсируем пересчёт AutoSize сразу — ReflowSections ниже читает
      уже настоящую, облегающую содержимое ширину/высоту секции, а не
      размер по умолчанию из момента создания TGroupBox. }
    Grp.AdjustSize;
  end;

  ReflowSections(nil);
end;

{ Вручную реализованный CSS-подобный flex-wrap: секции идут слева
  направо, пока помещаются в ширину контейнера; та, что не помещается
  — переносится на новую строку. Готовой такой раскладки в LCL
  ChildSizing нет: ControlsPerLine=0 там означает не "перенос по
  ширине", а вырождается в ту же 1-колоночную таблицу, что и
  ControlsPerLine=1 (см. TAutoSizeBox.SetTableControls в
  wincontrol.inc — Max(1, Min(0, Count)) = 1) — это фиксированная
  таблица под известное число колонок/строк, не адаптивный перенос. }
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
  { Единственный источник правды в памяти на время сессии —
    FormMain.FAutoDownload (framehistory.pas читает через него, не
    парсит config.ini само) — без этого только что сохранённые
    значения не подействовали бы до перезапуска приложения. }
  FormMain.LoadAutoDownloadSettings;
end;

end.
