unit lsrepair;

{$mode objfpc}{$H+}

{ Самовосстановление localStorage профиля WebView2 окна (тема, акцент,
  показ трафика, запомненные выборы страницы).

  ГРАБЛЯ (2026-10-11, живой профиль): в журнале leveldb хранилища
  (Local Storage\leveldb\NNNNNN.log) после оборванной сессии осталась дыра
  из нулевых байт. Нулевой заголовок записи (crc 0, длина 0, тип 0) для
  leveldb — «дальше пусто»: при восстановлении он отбрасывает весь
  остаток блока. А Chromium открывает базу с повторным использованием
  журнала («Reusing old log» в LOG) и дописывает ПОСЛЕ дыры — так что
  всё записанное в следующих сессиях при каждом запуске терялось:
  страница читала значение до дыры.

  Здесь — до создания окружения WebView2, пока файлы не заняты: журнал с
  такой дырой, за которой есть данные (их leveldb всё равно не прочтёт),
  откладывается в *.bad; без журнала leveldb открывает базу по MANIFEST и
  таблицам и начинает новый журнал. Теряется только то, что лежало в
  журнале до дыры, — его и так уже нельзя было изменить.

  Формат журнала — leveldb doc/log_format.md: блоки по 32 КБ, запись —
  заголовок 7 байт (crc32c 4, длина 2, тип 1) и данные; хвост блока
  короче 7 байт — нули без заголовка. }

interface

{ AProfileDir — папка пользовательских данных WebView2 (та, что отдаётся
  CreateCoreWebView2EnvironmentWithOptions). True — что-то отложено. }
function RepairLocalStorage(const AProfileDir: string): boolean;

implementation

uses
  Classes, SysUtils, guiconst;

{ Есть ли в журнале нулевой заголовок, за которым ещё что-то записано. }
function HasDeadGap(const AData: RawByteString): boolean;
var
  Pos, Left, Len, I: integer;
  Size: integer;
begin
  Result := False;
  Size := Length(AData);
  Pos := 0;
  while Pos + LS_LOG_HEADER <= Size do begin
    Left := LS_LOG_BLOCK - (Pos mod LS_LOG_BLOCK);
    if Left < LS_LOG_HEADER then begin
      Inc(Pos, Left);
      Continue;
    end;
    { Строки 1-based: байт Pos — AData[Pos + 1]. }
    Len := Ord(AData[Pos + 5]) or (Ord(AData[Pos + 6]) shl 8);
    if (Len = 0) and (AData[Pos + 7] = #0) and (AData[Pos + 1] = #0) and (AData[Pos + 2] = #0)
       and (AData[Pos + 3] = #0) and (AData[Pos + 4] = #0) then begin
      { Нулевой заголовок. Конец журнала — если дальше одни нули. }
      for I := Pos + 1 to Size do begin
        if AData[I] <> #0 then begin
          Exit(True);
        end;
      end;
      Exit;
    end;
    Inc(Pos, LS_LOG_HEADER + Len);
  end;
end;

function ReadAll(const AFileName: string; out AData: RawByteString): boolean;
var
  F: TFileStream;
begin
  Result := False;
  AData := '';
  try
    F := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(AData, F.Size);
      if F.Size > 0 then begin
        F.ReadBuffer(AData[1], F.Size);
      end;
      Result := True;
    finally
      F.Free;
    end;
  except
    { Занят (окружение уже запущено) или нет доступа — не трогаем. }
  end;
end;

function RepairLocalStorage(const AProfileDir: string): boolean;
var
  Dir: string;
  SR: TSearchRec;
  Data: RawByteString;
begin
  Result := False;
  Dir := IncludeTrailingPathDelimiter(AProfileDir) + LS_LEVELDB_SUBDIR;
  if FindFirst(Dir + '*.log', faAnyFile, SR) <> 0 then begin
    Exit;
  end;
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then begin
        Continue;
      end;
      if ReadAll(Dir + SR.Name, Data) and HasDeadGap(Data) then begin
        DeleteFile(Dir + SR.Name + '.bad');
        if RenameFile(Dir + SR.Name, Dir + SR.Name + '.bad') then begin
          Result := True;
        end;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

end.
