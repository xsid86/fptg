unit photodecoder;

{$mode objfpc}{$H+}

{ Разовое (не зацикленное, в отличие от audioplayer.pas/videoplayer.pas)
  декодирование одного файла-фото в фоновом потоке — JPEG-декод уже
  скачанного файла (TBGRABitmap.Create) и ресемпл в целевой размер
  превью (BGRAFilters). Раньше это делала TPhotoWidget.SetPhoto
  синхронно, прямо на главном потоке, в момент показа новой строки —
  при агрессивной автозагрузке "далеко вперёд" несколько новых фото
  становятся видны почти одновременно при быстром скролле, и этот
  декод (полноразмерный JPEG + ресемпл, не крошечный minithumbnail)
  ощутимо подвешивал прокрутку. См. CLAUDE.md.

  Блюр-плейсхолдер из minithumbnail (TPhotoWidget.SetPhoto) сюда НЕ
  вынесен — источник крошечный (~30×40), цена декода+блюра на нём
  пренебрежимо мала, не стоит сложности отдельного потока. }

interface

uses
  Classes, SysUtils, BGRABitmap, BGRABitmapTypes;

type
  TPhotoDecodeThread = class(TThread)
  private
    FSourcePath: utf8string;
    FTargetW, FTargetH: integer;
    FResult: TBGRABitmap;
    FOnDone: TNotifyEvent;
    { Пишется и читается ТОЛЬКО на главном потоке (виджет — из своего
      Destroy/при переиспользовании ДО того, как Synchronize успел
      сработать; DoDone — уже гарантированно на главном потоке, изнутри
      самого Synchronize) — обычной, не atomic, переменной достаточно:
      конкурентного доступа с двух потоков к этому полю не бывает в
      принципе, см. комментарий у Cancel. }
    FCanceled: boolean;
    procedure DoDone;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASourcePath: utf8string; ATargetW, ATargetH: integer;
      AOnDone: TNotifyEvent);
    { Вызывающий (виджет) обязан звать это в своём Destroy, если декод
      этого потока ещё не завершился (FDecodeThread <> nil) — иначе
      DoDone вызовет AOnDone на уже уничтоженном объекте. Безопасно
      звать с главного потока в ЛЮБОЙ момент до того, как AOnDone
      реально сработал: пока Synchronize не дошёл до выполнения
      колбэка на главном потоке, сам поток гарантированно жив (он
      заблокирован внутри Synchronize, ожидая своей очереди) — FreeOn
      Terminate не может сработать раньше этого момента. }
    procedure Cancel;
    { Забирает владение результатом (может быть nil, если декод не
      удался/отменён) — вызывающий обязан освободить сам. Вызывать
      только изнутри AOnDone. }
    function TakeResult: TBGRABitmap;
    property SourcePath: utf8string read FSourcePath;
  end;

implementation

constructor TPhotoDecodeThread.Create(const ASourcePath: utf8string;
  ATargetW, ATargetH: integer; AOnDone: TNotifyEvent);
begin
  inherited Create(True);
  FSourcePath := ASourcePath;
  FTargetW := ATargetW;
  FTargetH := ATargetH;
  FOnDone := AOnDone;
  FreeOnTerminate := True;
  Start;
end;

procedure TPhotoDecodeThread.Cancel;
begin
  FCanceled := True;
end;

function TPhotoDecodeThread.TakeResult: TBGRABitmap;
begin
  Result := FResult;
  FResult := nil;
end;

procedure TPhotoDecodeThread.DoDone;
begin
  { FCanceled проверяется ЗДЕСЬ, не в Execute перед вызовом Synchronize
    — эта функция сама уже выполняется на главном потоке (это и есть
    смысл Synchronize), поэтому чтение поля, которое пишет только
    главный поток (см. Cancel), не требует никакой дополнительной
    синхронизации. Если отменено — просто освобождаем результат сами
    (виджет, которому он предназначался, больше не спросит TakeResult). }
  if FCanceled then begin
    FreeAndNil(FResult);
    Exit;
  end;
  if Assigned(FOnDone) then begin
    FOnDone(Self);
  end;
end;

procedure TPhotoDecodeThread.Execute;
var
  Src: TBGRABitmap;
begin
  Src := nil;
  try
    try
      if FileExists(string(FSourcePath)) then begin
        Src := TBGRABitmap.Create(string(FSourcePath));
        Src.ResampleFilter := rfBestQuality;
        FResult := Src.Resample(FTargetW, FTargetH, rmFineResample);
      end;
    except
      FreeAndNil(FResult);
    end;
  finally
    Src.Free;
  end;
  Synchronize(@DoDone);
end;

end.
