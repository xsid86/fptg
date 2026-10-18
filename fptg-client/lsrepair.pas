unit lsrepair;

{$mode objfpc}{$H+}

{ Self-repair of the window's WebView2 profile localStorage (theme, accent,
  traffic display, the page's remembered choices).

  A PITFALL (2026-10-11, a live profile): in the storage's leveldb journal
  (Local Storage\leveldb\NNNNNN.log) a hole of zero bytes was left after a
  broken-off session. A zero record header (crc 0, length 0, type 0) means
  "empty from here" to leveldb: on recovery it drops the whole rest of the
  block. And Chromium opens the database reusing the journal ("Reusing old
  log" in LOG) and appends AFTER the hole — so everything written in the
  following sessions was lost on every start: the page read the value
  from before the hole.

  Here — before the WebView2 environment is created, while the files are
  free: a journal with such a hole and data after it (leveldb would not
  read it anyway) is set aside as *.bad; without a journal leveldb opens
  the database from MANIFEST and the tables and starts a new journal.
  Only what lay in the journal before the hole is lost — and that could no
  longer be changed anyway.

  The journal format — leveldb doc/log_format.md: 32 KB blocks, a record is
  a 7-byte header (crc32c 4, length 2, type 1) and data; a block's tail
  shorter than 7 bytes is zeros without a header. }

interface

{ AProfileDir — the WebView2 user data folder (the one passed to
  CreateCoreWebView2EnvironmentWithOptions). True — something was set aside. }
function RepairLocalStorage(const AProfileDir: string): boolean;

implementation

uses
  Classes, SysUtils, guiconst;

{ Whether the journal has a zero header followed by something else written. }
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
    { Strings are 1-based: byte Pos is AData[Pos + 1]. }
    Len := Ord(AData[Pos + 5]) or (Ord(AData[Pos + 6]) shl 8);
    if (Len = 0) and (AData[Pos + 7] = #0) and (AData[Pos + 1] = #0) and (AData[Pos + 2] = #0)
       and (AData[Pos + 3] = #0) and (AData[Pos + 4] = #0) then begin
      { A zero header. The end of the journal — if only zeros follow. }
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
    { Busy (the environment is running already) or no access — leave it alone. }
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
