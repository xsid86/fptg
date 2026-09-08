unit framewelcome;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, uiframe;

type

  { TFrameWelcome

    Placeholder for the work area, shown until a chat is selected. }

  TFrameWelcome = class(TFrameBase)
    lblTitle: TLabel;
    lblHint:  TLabel;
  end;

implementation

{$R *.lfm}

end.
