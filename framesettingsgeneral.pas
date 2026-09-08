unit framesettingsgeneral;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, uiframe;

type

  { TFrameSettingsGeneral

    The "General" section of the settings window (TFormSettings). Has
    no settings yet; exists to establish the section-tree structure so
    that adding settings later requires no changes to the window
    layout. }

  TFrameSettingsGeneral = class(TFrameBase)
    lblEmpty: TLabel;
  end;

implementation

{$R *.lfm}

end.
