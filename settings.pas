unit settings;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, ComCtrls, ExtCtrls, StdCtrls,
  uiframe, framesettingsgeneral, framesettingsaudio, framesettingsautodownload;

type

  { TFormSettings

    Модальное окно настроек: TreeView разделов слева, справа — фрейм
    текущего раздела через TFrameNavigator (тот же механизм переключения
    экранов, что и у TFormMain/FNav — переиспользован, не изобретён
    заново под второй контейнер). Разделы пока фиксированы (General,
    Audio) — список статичный, без отдельной регистрации разделов:
    двух пунктов достаточно, гибкая инфраструктура была бы
    преждевременной. }

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
  tvSections.Selected := tvSections.Items[0];
  { Выбор первого пункта не всегда сам стреляет OnSelectionChanged
    (зависит от того, был ли уже выбранный узел) — показываем фрейм
    явно, чтобы окно не открылось с пустой правой панелью. }
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
  end;
end;

procedure TFormSettings.btnSaveClick(Sender: TObject);
var
  F: TFrameBase;
begin
  { Аудио персистит выбор сразу при клике по устройству (см.
    framesettingsaudio.pas) — сохранять здесь нечего. General пуст.
    Auto download сохраняем, только если раздел реально открывали
    (Find <> nil) — иначе сетка чекбоксов ни разу не создавалась и
    сохранять нечего, значения в config.ini остаются как были. }
  F := FNav.Find(TFrameSettingsAutoDownload);
  if F <> nil then begin
    TFrameSettingsAutoDownload(F).SaveSettings;
  end;
  Close;
end;

end.
