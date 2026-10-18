unit customemoji;

{ Custom (Telegram Premium) emoji — a registry from custom_emoji_id to the
  sticker file: file id, format, path on disk and whether a download has
  been asked for already.

  tdmessages.pas and tdchats.pas run the TDLib side
  (getCustomEmojiStickers, then the ordinary downloadFile/updateFile) and
  call Set* as the data arrives; webapi.pas gives the page the /media/
  address and the format, and the page draws the emoji itself.

  Bitmaps and live decoders (TLottiePlayer, TAnimationPlayer) for the
  native history and chat list used to live here too; they went with the
  native windows (2026-10-05) — the registry alone is left.

  The format is its own enum, not tdmessages.TStickerFormat: tdmessages
  already depends on this unit, and a reference back for the sake of one
  type would be a cycle. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl;

type
  TCustomEmojiFormat = (cmfWebp, cmfTgs, cmfWebm);

{ Called once metadata for AId is known (from getCustomEmojiStickers) —
  ALocalPath may already be non-empty if TDLib's file cache already has
  it, same as any other Ensure*File flow in this project. }
procedure CustomEmojiSetSticker(AId: Int64; AFileId: integer;
  AFormat: TCustomEmojiFormat; const ALocalPath: utf8string);
{ Called once the file finishes downloading (updateFile). }
procedure CustomEmojiSetLocalPath(AId: Int64; const ALocalPath: utf8string);

function CustomEmojiKnown(AId: Int64): boolean;
function CustomEmojiFileIdFor(AId: Int64): integer;
function CustomEmojiIdForFile(AFileId: integer): Int64;   { 0 if none }

{ Where the file is and what kind it is. Empty path means "not
  downloaded yet"; the format is only meaningful once
  CustomEmojiSetSticker has been called for the id. }
function CustomEmojiLocalPathFor(AId: Int64): utf8string;
function CustomEmojiFormatFor(AId: Int64): TCustomEmojiFormat;

{ True once metadata is known (FileId<>0), the file isn't on disk yet,
  and no downloadFile has been issued for it yet — tdmessages.pas
  checks this before requesting, then calls
  CustomEmojiMarkDownloadRequested so the next pass doesn't re-request
  it. }
function CustomEmojiNeedsDownload(AId: Int64): boolean;
procedure CustomEmojiMarkDownloadRequested(AId: Int64);

implementation

type
  TCustomEmojiEntry = class
    FileId:       integer;
    Format:       TCustomEmojiFormat;
    LocalPath:    utf8string;
    DownloadRequested: boolean;
  end;

  TCustomEmojiMap = specialize TFPGMap<Int64, TCustomEmojiEntry>;

var
  FMap: TCustomEmojiMap;

function Ensure: TCustomEmojiMap;
begin
  if FMap = nil then begin
    FMap := TCustomEmojiMap.Create;
    FMap.Sorted := True;
  end;
  Result := FMap;
end;

function Entry(AId: Int64; ACreate: boolean): TCustomEmojiEntry;
var
  Idx: integer;
begin
  Result := nil;
  Idx := Ensure.IndexOf(AId);
  if Idx >= 0 then begin
    Result := Ensure.Data[Idx];
    Exit;
  end;
  if not ACreate then begin
    Exit;
  end;
  Result := TCustomEmojiEntry.Create;
  Result.FileId := 0;
  Result.Format := cmfWebp;
  Result.LocalPath := '';
  Result.DownloadRequested := False;
  Ensure.Add(AId, Result);
end;

procedure CustomEmojiSetSticker(AId: Int64; AFileId: integer;
  AFormat: TCustomEmojiFormat; const ALocalPath: utf8string);
var
  E: TCustomEmojiEntry;
begin
  E := Entry(AId, True);
  E.FileId := AFileId;
  E.Format := AFormat;
  if ALocalPath <> '' then begin
    E.LocalPath := ALocalPath;
  end;
end;

procedure CustomEmojiSetLocalPath(AId: Int64; const ALocalPath: utf8string);
var
  E: TCustomEmojiEntry;
begin
  E := Entry(AId, False);
  if E <> nil then begin
    E.LocalPath := ALocalPath;
  end;
end;

function CustomEmojiKnown(AId: Int64): boolean;
begin
  Result := Entry(AId, False) <> nil;
end;

function CustomEmojiFileIdFor(AId: Int64): integer;
var
  E: TCustomEmojiEntry;
begin
  E := Entry(AId, False);
  if E = nil then begin
    Result := 0;
  end else begin
    Result := E.FileId;
  end;
end;

function CustomEmojiLocalPathFor(AId: Int64): utf8string;
var
  E: TCustomEmojiEntry;
begin
  E := Entry(AId, False);
  if E = nil then begin
    Result := '';
  end else begin
    Result := E.LocalPath;
  end;
end;

function CustomEmojiFormatFor(AId: Int64): TCustomEmojiFormat;
var
  E: TCustomEmojiEntry;
begin
  { cmfWebp for an unknown id: it is the still, harmless one, and the
    caller is expected to check the path before using any of this. }
  Result := cmfWebp;
  E := Entry(AId, False);
  if E <> nil then begin
    Result := E.Format;
  end;
end;

function CustomEmojiIdForFile(AFileId: integer): Int64;
var
  I: integer;
begin
  Result := 0;
  if (FMap = nil) or (AFileId = 0) then begin
    Exit;
  end;
  for I := 0 to FMap.Count - 1 do begin
    if FMap.Data[I].FileId = AFileId then begin
      Result := FMap.Keys[I];
      Exit;
    end;
  end;
end;

function CustomEmojiNeedsDownload(AId: Int64): boolean;
var
  E: TCustomEmojiEntry;
begin
  E := Entry(AId, False);
  Result := (E <> nil) and (E.FileId <> 0) and (E.LocalPath = '') and not E.DownloadRequested;
end;

procedure CustomEmojiMarkDownloadRequested(AId: Int64);
var
  E: TCustomEmojiEntry;
begin
  E := Entry(AId, False);
  if E <> nil then begin
    E.DownloadRequested := True;
  end;
end;

procedure FreeMap;
var
  I: integer;
begin
  if FMap <> nil then begin
    for I := 0 to FMap.Count - 1 do begin
      FMap.Data[I].Free;
    end;
    FMap.Free;
  end;
end;

finalization
  FreeMap;

end.
