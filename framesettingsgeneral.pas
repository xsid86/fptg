unit framesettingsgeneral;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, uiframe;

type

  { TFrameSettingsGeneral

    Раздел "General" окна настроек (TFormSettings) — пока без единой
    настройки, заведён заранее под структуру дерева разделов, чтобы
    добавление настроек позже не требовало менять сам каркас окна. }

  TFrameSettingsGeneral = class(TFrameBase)
    lblEmpty: TLabel;
  end;

implementation

{$R *.lfm}

end.
