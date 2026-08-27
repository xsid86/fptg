unit framewelcome;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, uiframe;

type

  { TFrameWelcome

    Заглушка рабочей области: показывается, пока чат не выбран.
    Позже её место займёт TFrameChat. }

  TFrameWelcome = class(TFrameBase)
    lblTitle: TLabel;
    lblHint:  TLabel;
  end;

implementation

{$R *.lfm}

end.
