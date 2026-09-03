unit settings;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, ComCtrls, ExtCtrls,
  uiframe, framesettingsgeneral, framesettingsaudio;

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
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure tvSectionsSelectionChanged(Sender: TObject);
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
  end;
end;

end.
