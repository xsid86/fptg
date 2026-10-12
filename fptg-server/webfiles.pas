unit webfiles;

{$mode objfpc}{$H+}

{ The bridge that lets the HTTP side hand out media files without ever
  touching the model.

  The problem this solves: a downloaded photo/video/track lives in
  TDLib's cache under an absolute path only the model knows, and the
  model is single-threaded and owned by the main thread (see the header
  of webapi.pas). But an <img src> or a <video src> is fetched by the
  browser on its own schedule, and that request lands on a socket
  thread, which must not go anywhere near TDLib's state.

  So the main thread PUBLISHES: every time it serialises a message row
  that has a downloaded file, it records file_id -> absolute path here.
  The socket thread only ever RESOLVES, under the same lock. TDLib's
  file_id is already a process-wide unique integer, so it needs no
  invention of our own.

  This is also what keeps path traversal impossible on that route:
  /media/<id> carries no path at all, just an integer, and the only
  paths that can ever be served are ones the model itself produced. }

interface

function WebFilePublish(AFileId: integer; const APath: utf8string): utf8string;
function WebFileResolve(AFileId: integer; out APath: string): boolean;
procedure WebFilesClear;

{ Content type by extension, for what comes out of the TDLib cache.
  Deliberately separate from localserver's own table for the web root:
  that one answers for the files this project ships, this one for
  whatever Telegram happens to send, and the two lists have almost
  nothing in common. }
function MediaContentType(const AFileName: string): string;

implementation

uses
  SysUtils, SyncObjs, fgl;

type
  TFileMap = specialize TFPGMap<integer, string>;

var
  GLock: SyncObjs.TCriticalSection = nil;
  GMap: TFileMap = nil;

{ Records the file and returns the URL the page should use, or '' when
  there is nothing to serve yet (the file has not been downloaded).
  Returning the URL from the same call keeps "publish it" and "link to
  it" from ever disagreeing about the shape of that URL. }
function WebFilePublish(AFileId: integer; const APath: utf8string): utf8string;
var
  Idx: integer;
begin
  Result := '';
  if (AFileId = 0) or (APath = '') then begin
    Exit;
  end;
  GLock.Enter;
  try
    Idx := GMap.IndexOf(AFileId);
    if Idx >= 0 then begin
      GMap.Data[Idx] := string(APath);
    end else begin
      GMap.Add(AFileId, string(APath));
    end;
  finally
    GLock.Leave;
  end;
  Result := '/media/' + utf8string(IntToStr(AFileId));
end;

function WebFileResolve(AFileId: integer; out APath: string): boolean;
var
  Idx: integer;
begin
  APath := '';
  Result := False;
  GLock.Enter;
  try
    Idx := GMap.IndexOf(AFileId);
    if Idx >= 0 then begin
      APath := GMap.Data[Idx];
      Result := APath <> '';
    end;
  finally
    GLock.Leave;
  end;
end;

procedure WebFilesClear;
begin
  GLock.Enter;
  try
    GMap.Clear;
  finally
    GLock.Leave;
  end;
end;

function MediaContentType(const AFileName: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  if (Ext = '.jpg') or (Ext = '.jpeg') then begin
    Result := 'image/jpeg';
  end else if Ext = '.png' then begin
    Result := 'image/png';
  end else if Ext = '.gif' then begin
    Result := 'image/gif';
  end else if Ext = '.webp' then begin
    Result := 'image/webp';
  end else if Ext = '.mp4' then begin
    Result := 'video/mp4';
  end else if Ext = '.webm' then begin
    Result := 'video/webm';
  end else if Ext = '.mov' then begin
    Result := 'video/quicktime';
  end else if Ext = '.mp3' then begin
    Result := 'audio/mpeg';
  end else if (Ext = '.ogg') or (Ext = '.oga') then begin
    { Telegram voice notes are Opus in an Ogg container. Labelled
      audio/ogg rather than audio/opus: the former is what browsers
      actually match against for playback. }
    Result := 'audio/ogg';
  end else if Ext = '.opus' then begin
    Result := 'audio/ogg';
  end else if Ext = '.m4a' then begin
    Result := 'audio/mp4';
  end else if Ext = '.wav' then begin
    Result := 'audio/wav';
  end else if Ext = '.flac' then begin
    Result := 'audio/flac';
  end else if Ext = '.pdf' then begin
    Result := 'application/pdf';
  end else if Ext = '.tgs' then begin
    { A gzip-compressed Lottie JSON. No registered type; served as
      octet-stream because the page fetches and inflates it itself
      rather than handing it to an <img>. }
    Result := 'application/octet-stream';
  end else begin
    Result := 'application/octet-stream';
  end;
end;

initialization
  GLock := SyncObjs.TCriticalSection.Create;
  GMap := TFileMap.Create;
  GMap.Sorted := True;

finalization
  GMap.Free;
  GMap := nil;
  GLock.Free;
  GLock := nil;

end.
