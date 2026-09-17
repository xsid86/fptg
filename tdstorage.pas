unit tdstorage;

{ TDLib's own media cache — the tdlib/accN/files tree — and the one
  API that prunes it.

  Everything the app downloads (photos, videos, music, documents,
  voice notes) is written there by TDLib and never removed on its own:
  the auto-download prefetch in framehistory.pas keeps feeding it, so
  the folder only grows. TDLib has exactly one method for trimming it,
  optimizeStorage, and the files must be deleted THROUGH it: they are
  tracked in db.sqlite, and erasing them behind TDLib's back leaves it
  convinced they are still on disk.

  Both calls here are verified against the real td_api.tl, not recalled:

    getStorageStatisticsFast
      -> storageStatisticsFast files_size:int53 file_count:int32
         database_size:int53 language_pack_database_size:int53
         log_size:int53

    optimizeStorage size:int53 ttl:int32 count:int32
      immunity_delay:int32 file_types:vector<FileType>
      chat_ids:vector<int53> exclude_chat_ids:vector<int53>
      return_deleted_file_statistics:Bool chat_limit:int32
      -> storageStatistics size:int53 count:int32 by_chat:...

  Two details of optimizeStorage decide how the body below is built.

  First: -1, not 0, is "no limit" for size/ttl/count/immunity_delay.
  A field left OUT of the JSON arrives as 0, and size:0 means "leave
  zero bytes of files behind" — the whole cache. So all four are
  always sent explicitly, and a disabled setting is sent as -1.

  Second: an EMPTY file_types is not "nothing" but TDLib's own default
  set, documented as "all types except thumbnails, profile photos,
  stickers and wallpapers". That default is exactly right here — those
  four are small (tens of MB against gigabytes of video) and are what
  the chat list and the message list draw from, so losing them would
  make the UI visibly worse to save nothing.

  The requests are owned by this long-lived object rather than by the
  settings frame that shows the numbers: a response can arrive after
  the settings dialog has been closed, and tdreq.pas has no way to
  cancel a pending callback — it would fire into freed memory. The
  frame subscribes to OnChanged and clears it when it goes away. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, tdreq;

type
  { The last known answer to getStorageStatisticsFast. Known is False
    until the first successful reply — the display has to say "unknown"
    rather than a confident 0 B. }
  TTdStorageStats = record
    Known:        boolean;
    FilesSize:    Int64;
    FileCount:    integer;
    DatabaseSize: Int64;
    LogSize:      Int64;
  end;

  TTdStorage = class
  private
    FStats:          TTdStorageStats;
    FBusy:           boolean;
    FLastFreed:      Int64;
    FLastFreedCount: integer;
    FLastError:      utf8string;
    FOnChanged:      TNotifyEvent;
    procedure Changed;
    procedure Fail(const AResp: TTdResponse);
    procedure StatsDone(Sender: TObject; const AResp: TTdResponse);
    procedure OptimizeDone(Sender: TObject; const AResp: TTdResponse);
  public
    { Both are no-ops while another call is still in flight (Busy) or
      before there is an authorized account to ask. }
    procedure RefreshStats;
    { ALimitMB / ATtlDays: 0 means "no limit of this kind", and is what
      gets turned into the -1 TDLib wants. Files newer than TDLib's own
      immunity delay are kept regardless. Refreshes the statistics
      afterwards, so one Cleanup produces more than one OnChanged. }
    procedure Cleanup(ALimitMB, ATtlDays: integer);
    property Stats: TTdStorageStats read FStats;
    property Busy: boolean read FBusy;
    { Bytes/files actually deleted by the last Cleanup — TDLib reports
      them because the request asks for deleted-file statistics rather
      than the resulting totals. }
    property LastFreed: Int64 read FLastFreed;
    property LastFreedCount: integer read FLastFreedCount;
    { Empty unless the last call failed. }
    property LastError: utf8string read FLastError;
    { Single listener, like the models' own OnChanged — see the unit
      header for why the subscriber must clear it on the way out. }
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

{ The singleton. Not named TdStorage: Pascal identifiers are
  case-insensitive, so that would resolve to this very unit rather
  than to the function — the same pitfall tdcore.pas already documents
  for TdMsgList/tdmessages and TdUserList/tdusers. }
function TdCache: TTdStorage;

{ Shared by the settings section and anything else reporting a cache
  size. Kept here rather than reusing framehistory's private
  FormatFileSize: that unit is the whole message list, and this one
  sits as low in the dependency graph as the numbers themselves. }
function FormatBytes(ABytes: Int64): string;

implementation

uses
  tdcore, constants;

var
  GStorage: TTdStorage = nil;

function TdCache: TTdStorage;
begin
  if GStorage = nil then begin
    GStorage := TTdStorage.Create;
  end;
  Result := GStorage;
end;

function FormatBytes(ABytes: Int64): string;
begin
  if ABytes >= Int64(1024) * 1024 * 1024 then begin
    Result := FormatFloat('0.00', ABytes / (1024.0 * 1024 * 1024)) + ' GB';
  end else if ABytes >= 1024 * 1024 then begin
    Result := FormatFloat('0.0', ABytes / (1024.0 * 1024)) + ' MB';
  end else if ABytes >= 1024 then begin
    Result := FormatFloat('0', ABytes / 1024.0) + ' KB';
  end else begin
    Result := IntToStr(ABytes) + ' B';
  end;
end;

{ TTdStorage }

procedure TTdStorage.Changed;
begin
  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

procedure TTdStorage.Fail(const AResp: TTdResponse);
begin
  FBusy := False;
  FLastError := utf8string(Format('ERROR %d: %s',
    [AResp.ErrorCode, string(AResp.ErrorMessage)]));
  Changed;
end;

procedure TTdStorage.RefreshStats;
begin
  if FBusy or (TdRequests = nil) then begin
    Exit;
  end;
  FBusy := True;
  Changed;
  { The "fast" variant on purpose: the full getStorageStatistics walks
    every file to group them by chat, which is exactly the work being
    avoided just to print a total. }
  TdRequests.SendRequest('getStorageStatisticsFast', '', @StatsDone);
end;

procedure TTdStorage.StatsDone(Sender: TObject; const AResp: TTdResponse);
begin
  if not AResp.Success then begin
    Fail(AResp);
    Exit;
  end;
  FBusy := False;
  FLastError := '';
  FStats.Known := True;
  FStats.FilesSize := JGetInt64(AResp.Obj, 'files_size');
  FStats.FileCount := JGetInt(AResp.Obj, 'file_count');
  FStats.DatabaseSize := JGetInt64(AResp.Obj, 'database_size');
  FStats.LogSize := JGetInt64(AResp.Obj, 'log_size');
  Changed;
end;

procedure TTdStorage.Cleanup(ALimitMB, ATtlDays: integer);
var
  SizeLimit: Int64;
  TtlSec: integer;
  Body: utf8string;
begin
  if FBusy or (TdRequests = nil) then begin
    Exit;
  end;

  if ALimitMB > 0 then begin
    SizeLimit := Int64(ALimitMB) * 1024 * 1024;
  end else begin
    SizeLimit := -1;
  end;
  if ATtlDays > 0 then begin
    TtlSec := ATtlDays * 24 * 60 * 60;
  end else begin
    TtlSec := -1;
  end;

  FBusy := True;
  FLastFreed := 0;
  FLastFreedCount := 0;
  FLastError := '';
  Changed;

  { count/immunity_delay stay at TDLib's defaults: a file-count cap
    makes no sense next to a size cap, and the immunity delay is what
    keeps a download that is still being written from being deleted
    out from under the widget waiting for it. }
  Body := '"size":' + utf8string(IntToStr(SizeLimit)) +
          ',"ttl":' + utf8string(IntToStr(TtlSec)) +
          ',"count":-1,"immunity_delay":-1' +
          ',"file_types":[],"chat_ids":[],"exclude_chat_ids":[]' +
          ',"return_deleted_file_statistics":true,"chat_limit":0';
  { Its own timeout: this walks the whole file database, and on a cache
    that has grown to gigabytes it can take far longer than the 30s
    default — that would report a failure for a cleanup that in fact
    ran to completion. }
  TdRequests.SendRequest('optimizeStorage', Body, @OptimizeDone, 0,
    STORAGE_OPTIMIZE_TIMEOUT_MS);
end;

procedure TTdStorage.OptimizeDone(Sender: TObject; const AResp: TTdResponse);
begin
  if not AResp.Success then begin
    Fail(AResp);
    Exit;
  end;
  FBusy := False;
  FLastError := '';
  { return_deleted_file_statistics was true, so these are what went
    away, not what is left. }
  FLastFreed := JGetInt64(AResp.Obj, 'size');
  FLastFreedCount := JGetInt(AResp.Obj, 'count');
  Changed;
  { The totals on screen are now stale by exactly the amount above —
    ask for the real ones rather than subtracting, the database and
    log sizes move too. }
  RefreshStats;
end;

finalization
  FreeAndNil(GStorage);

end.
