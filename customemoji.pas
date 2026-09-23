unit customemoji;

{ Custom (Telegram Premium) emoji used inline in message text
  (textEntityTypeCustomEmoji) — a global cache from custom_emoji_id to
  the bitmap PaintRuns (msglayout.pas) should draw for it right now.
  Unlike the animated big single-emoji messages (messageAnimatedEmoji,
  rendered through the sticker widget pipeline, framehistory.pas),
  these live INSIDE the word-wrapped text flow, the same slot a plain
  Unicode emoji from emojiassets.pas would occupy — there's no
  per-occurrence child control to animate the usual way. A static
  format (cmfWebp) just decodes once; an animated one (cmfTgs) gets a
  real TLottiePlayer (lottieplayer.pas) running continuously in the
  background, and CustomEmojiBitmapFor returns whatever its latest
  decoded frame is — TMsgScroller.CustomEmojiAnimTick
  (framehistory.pas) is what actually keeps repainting so that latest
  frame gets picked up (see AnyLiveAnimating).

  tdmessages.pas owns the TDLib side (getCustomEmojiStickers, then the
  usual downloadFile/updateFile dance) and calls the Set* procedures
  below as data arrives; msglayout.pas only ever calls
  CustomEmojiBitmapFor, read-only, during Paint. Neither of those units
  needs to know about the other — this unit is the only thing both
  import, which is also why the format enum here is its own (not
  tdmessages.TStickerFormat): tdmessages already needs this unit, so
  this unit importing tdmessages back for one enum type would be a
  cycle. }

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, fgl,
  BGRABitmap, BGRABitmapTypes, lottieplayer, videoplayer, constants;

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

{ Where the file is and what kind it is - nothing decoded, nothing
  started. This is what the WEB side needs: webapi.pas hands the page a
  /media/ URL and the page draws the emoji itself, so none of the
  bitmap/player machinery below is involved at all. Empty path means
  "not downloaded yet"; the format is only meaningful once
  CustomEmojiSetSticker has been called for the id. }
function CustomEmojiLocalPathFor(AId: Int64): utf8string;
function CustomEmojiFormatFor(AId: Int64): TCustomEmojiFormat;

{ True once metadata is known (FileId<>0), the file isn't on disk yet,
  and no downloadFile has been issued for it yet — tdmessages.pas
  checks this before requesting, then calls
  CustomEmojiMarkDownloadRequested so the next visible-row pass doesn't
  re-request it. }
function CustomEmojiNeedsDownload(AId: Int64): boolean;
procedure CustomEmojiMarkDownloadRequested(AId: Int64);

{ Nil until metadata AND the file are both known and at least one frame
  has been decoded at ASize — the caller (PaintRuns) is expected to
  fall back to something else (the plain-Unicode alt-emoji rendering
  already in place) while this returns nil. For cmfWebp this decodes
  once, synchronously, on whatever thread calls this (the UI thread,
  from Paint) — cheap, matches emojiassets.pas's own lazy-decode. For
  cmfTgs this starts (on first call) or polls (on every later call) a
  live TLottiePlayer — never blocks: if no new frame has arrived since
  the last call, the previous frame keeps being returned as-is. }
function CustomEmojiBitmapFor(AId: Int64; ASize: integer): TBGRABitmap;

{ True if any custom emoji currently has a live animation running — the
  cue TMsgScroller.CustomEmojiAnimTick uses to decide whether it's worth
  invalidating at all. }
function AnyLiveAnimating: boolean;

{ True if any KNOWN custom emoji (CustomEmojiSetSticker already called
  for it, so an entry exists) hasn't produced its first frame yet (file
  not downloaded, or downloaded but not decoded) — used where "just
  resolved, now show the real thing instead of the placeholder" needs a
  repaint. TFrameChats (framechats.pas) uses this: the chat list has no
  direct notification path from a TDLib response arriving in
  TTdMessages (a different model) to itself, only this kind of polling.

  Deliberately does NOT include "is currently animating" (unlike an
  earlier version) — by direct request, the chat list shows custom
  emoji but does not animate them (only the open chat history does,
  via AnyLiveAnimating): once an entry's first frame has arrived, this
  stops being True for it, so the chat list naturally stops
  re-invalidating on its account — whatever frame happened to be
  current at that moment is what stays showing there, not a live feed
  of every subsequent frame. }
function AnyPendingWork: boolean;

{ Chat-list-only counterpart to CustomEmojiBitmapFor — by direct
  request, the chat list shows a custom emoji but never animates it
  (see AnyPendingWork's own comment). Simply not re-invalidating the
  grid (AnyPendingWork above) is NOT enough on its own: Bitmap is one
  GLOBAL object per custom_emoji_id, shared with the open chat history
  — if history is visible at the same time (the normal layout: chat
  list beside the open conversation) and is actively animating that
  same emoji, its own timer keeps mutating this SAME Bitmap's pixels in
  place. Any unrelated repaint of the chat list (scrolling, a totally
  different row changing, even an OS-level repaint of an overlapping
  region) would then show whatever frame history's player had most
  recently written — the list would still visibly flicker/animate
  despite never asking for a repaint on its own account (reported
  directly, reproduced exactly in this shared-view layout). This
  returns a ONE-TIME, permanently-frozen copy taken the moment a real
  frame first became available, completely decoupled from whatever the
  live Bitmap does afterward — calls CustomEmojiBitmapFor internally
  first (so the normal fetch/decode/animate pipeline for HISTORY's
  benefit keeps running exactly as before; this doesn't own or
  duplicate that work, only piggybacks on its result once). }
function CustomEmojiStaticBitmapFor(AId: Int64; ASize: integer): TBGRABitmap;

implementation

type
  TCustomEmojiEntry = class
    FileId:       integer;
    Format:       TCustomEmojiFormat;
    LocalPath:    utf8string;
    DownloadRequested: boolean;
    { For cmfWebp: the (only, final) decoded frame. For cmfTgs: the
      latest frame pulled from Player, updated in place — same object
      identity across frames, only its pixels change (PaintRuns holds no
      reference across calls, so this is safe: it always re-reads
      CustomEmojiBitmapFor fresh on every repaint). }
    Bitmap:       TBGRABitmap;
    BitmapSize:   integer;
    DecodeFailed: boolean;
    { See CustomEmojiStaticBitmapFor — a permanent, one-time copy of
      Bitmap taken the first time it became non-nil at StaticSnapshotSize,
      never updated again afterward (even if Bitmap keeps animating for
      history's sake). Reset (freed, nil'd) only when the underlying
      file genuinely changes (CustomEmojiSetLocalPath, a real path
      change) — the same "this entry is now different data" trigger
      that already resets Bitmap itself. }
    StaticSnapshot:     TBGRABitmap;
    StaticSnapshotSize: integer;
    { cmfTgs/cmfWebm only — a live decoder thread, created lazily at the
      first requested size and kept running for the rest of the session
      (no eviction on scroll-out, see docs/journal/ — custom emoji are rare
      enough in practice that this is an accepted v1 simplification,
      the same tradeoff already made for the cache itself never
      shrinking). Exactly one of Player/VideoPlayer is ever assigned,
      matching Format — never both at once. RawBuf is whichever
      player's own scratch output buffer (ARGB32_Premultiplied for
      Player/cmfTgs, opaque BGRA for VideoPlayer/cmfWebm — same
      byte size either way, BitmapSize*BitmapSize*4), reused across
      polls instead of reallocated. }
    Player:        TLottiePlayer;
    VideoPlayer:   TAnimationPlayer;
    PlayerVersion: cardinal;
    RawBuf:        PByte;
    destructor Destroy; override;
  end;

destructor TCustomEmojiEntry.Destroy;
begin
  if Player <> nil then begin
    { FreeOnTerminate — the thread frees itself once it notices the
      flag; never call .Free on it directly (see lottieplayer.pas). }
    Player.StopPlayback;
    Player := nil;
  end;
  if VideoPlayer <> nil then begin
    { Same FreeOnTerminate convention as Player above, see
      videoplayer.pas. }
    VideoPlayer.StopPlayback;
    VideoPlayer := nil;
  end;
  if RawBuf <> nil then begin
    FreeMem(RawBuf);
  end;
  Bitmap.Free;
  StaticSnapshot.Free;
  inherited Destroy;
end;

type
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
  Result.Bitmap := nil;
  Result.BitmapSize := 0;
  Result.DecodeFailed := False;
  Result.Player := nil;
  Result.VideoPlayer := nil;
  Result.PlayerVersion := 0;
  Result.RawBuf := nil;
  Result.StaticSnapshot := nil;
  Result.StaticSnapshotSize := 0;
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
  if E = nil then begin
    Exit;
  end;
  { TDLib fires updateFile more than once for an already-completed
    download (observed in practice, not just theoretical — reported as
    "cycles between the real sticker and the alt-emoji fallback") —
    without this guard, every redundant notification restarted the live
    player from scratch, and CustomEmojiBitmapFor returns nil for the
    brief window between stopping the old one and the new one producing
    its first frame, which PaintRuns reads as "fall back to the plain
    Unicode glyph". Only a REAL path change (or the first time it's set
    at all) should tear anything down. }
  if E.LocalPath = ALocalPath then begin
    Exit;
  end;
  E.LocalPath := ALocalPath;
  if E.Player <> nil then begin
    E.Player.StopPlayback;
    E.Player := nil;
  end;
  if E.VideoPlayer <> nil then begin
    E.VideoPlayer.StopPlayback;
    E.VideoPlayer := nil;
  end;
  if E.RawBuf <> nil then begin
    FreeMem(E.RawBuf);
    E.RawBuf := nil;
  end;
  FreeAndNil(E.Bitmap);
  E.BitmapSize := 0;
  E.DecodeFailed := False;
  FreeAndNil(E.StaticSnapshot);
  E.StaticSnapshotSize := 0;
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

function DecodeWebpFrame(const APath: utf8string; ASize: integer): TBGRABitmap;
var
  Src: TBGRABitmap;
begin
  Result := nil;
  Src := TBGRABitmap.Create(string(APath));
  try
    Src.ResampleFilter := rfBestQuality;
    Result := Src.Resample(ASize, ASize, rmFineResample);
  finally
    Src.Free;
  end;
end;

{ Un-premultiplies ASrc into ADst's own pixel buffer. BGRABitmap stores
  straight (non-premultiplied) alpha internally — feeding it
  premultiplied values as-is would darken every partially-transparent
  edge pixel a second time on top of rlottie's own premultiplication.

  ASrc here is E.RawBuf, filled by TLottiePlayer.TryGetFrame — that is
  the PLAYER'S OWN PUBLIC OUTPUT BUFFER, already in B,G,R,A byte order
  (standard Windows DIB order), NOT rlottie's raw R,G,B,A render output.
  The R/B swap TLottiePlayer.BoxDownscaleArgb documents happens INSIDE
  that function, converting from rlottie's raw R,G,B,A into this B,G,R,A
  buffer — confirmed by framehistory.DrawPremultipliedArgbBuffer, the
  sticker widget's consumer of this exact same TryGetFrame output, which
  Moves it straight into a BI_RGB DIB with no further swap at all, and
  DIBs are B,G,R,A by definition. A previous version of this function
  read it as if it still needed that R,G,B,A-style swap applied AGAIN
  (R:=SP[0], B:=SP[2]) — that undoes the swap BoxDownscaleArgb already
  did, a real, reported bug (colors "inverted" — R and B channels
  literally swapped). Fixed: read straight, B,G,R,A, no swap. }
procedure UnpremultiplyInto(ASrc: PByte; AW, AH: integer; ADst: TBGRABitmap);
var
  X, Y: integer;
  SP: PByte;
  Row: PBGRAPixel;
  A: byte;
  R, G, B: integer;
begin
  for Y := 0 to AH - 1 do begin
    Row := ADst.ScanLine[Y];
    for X := 0 to AW - 1 do begin
      SP := ASrc + (cardinal(Y) * cardinal(AW) + cardinal(X)) * 4;
      A := SP[3];
      if A = 0 then begin
        Row[X].FromRGB(0, 0, 0, 0);
      end else begin
        B := (SP[0] * 255) div A;
        G := (SP[1] * 255) div A;
        R := (SP[2] * 255) div A;
        if R > 255 then R := 255;
        if G > 255 then G := 255;
        if B > 255 then B := 255;
        Row[X].FromRGB(R, G, B, A);
      end;
    end;
  end;
  ADst.InvalidateBitmap;
end;

{ Copies ASrc — BGRA (B,G,R,A per pixel), the same byte layout
  TAnimationPlayer.TryGetFrame already produces for "GIF"/webm-sticker
  playback (see framehistory.DrawBgraBuffer's direct SetDIBitsToDevice
  use of this exact buffer — a plain BI_RGB blit, no further channel
  swap, proving the layout) — into ADst. Reads the REAL 4th byte as
  alpha, not a hardcoded 255 — this used to force full opacity
  (renamed from CopyOpaqueBgraInto, which is no longer accurate) back
  when webm's VP9 alpha extension genuinely wasn't decoded at all; now
  that videoplayer.TAnimationPlayer composites a real alpha channel
  when the source file has one (see its own ExecuteInner comment),
  forcing 255 here would have SILENTLY THROWN THAT AWAY AGAIN — exactly
  the bug reported after the alpha-compositing fix shipped (still a
  solid black background where a webm custom emoji should be
  transparent) — the decoder was already fixed, this consumer of its
  output just never got updated to stop overriding it. Straight
  (non-premultiplied) alpha, no per-channel math needed unlike
  UnpremultiplyInto above — libswscale's YUVA420P->BGRA conversion
  (videoplayer.pas) does not premultiply, a DIFFERENT convention from
  rlottie's ARGB32_Premultiplied output that UnpremultiplyInto exists
  to undo; a plain video decode with no alpha at all (the common case)
  still works correctly through this same path — its 4th byte comes
  out as 255 from swscale itself in that case, nothing to force. }
procedure CopyBgraInto(ASrc: PByte; AW, AH: integer; ADst: TBGRABitmap);
var
  X, Y: integer;
  SP: PByte;
  Row: PBGRAPixel;
begin
  for Y := 0 to AH - 1 do begin
    Row := ADst.ScanLine[Y];
    for X := 0 to AW - 1 do begin
      SP := ASrc + (cardinal(Y) * cardinal(AW) + cardinal(X)) * 4;
      Row[X].FromRGB(SP[2], SP[1], SP[0], SP[3]);
    end;
  end;
  ADst.InvalidateBitmap;
end;

{ (Re)starts E's live player at ASize, stopping/discarding whatever was
  running at a different size first — a resized column (e.g. window
  resize) is rare enough that simply restarting from scratch is fine,
  no attempt is made to preserve playback position. No-op if a player
  already exists at exactly this size. }
procedure EnsureTgsPlayer(E: TCustomEmojiEntry; ASize: integer);
begin
  if (E.Player <> nil) and (E.BitmapSize = ASize) then begin
    Exit;
  end;
  if E.Player <> nil then begin
    E.Player.StopPlayback;
    E.Player := nil;
  end;
  if E.RawBuf <> nil then begin
    FreeMem(E.RawBuf);
    E.RawBuf := nil;
  end;
  FreeAndNil(E.Bitmap);
  E.PlayerVersion := 0;
  E.BitmapSize := ASize;
  GetMem(E.RawBuf, cardinal(ASize) * cardinal(ASize) * 4);
  E.Player := TLottiePlayer.Create(E.LocalPath, ASize, ASize);
end;

{ Same shape as EnsureTgsPlayer, for the video-decode (cmfWebm) path —
  TAnimationPlayer (videoplayer.pas), not TLottiePlayer. }
procedure EnsureWebmPlayer(E: TCustomEmojiEntry; ASize: integer);
begin
  if (E.VideoPlayer <> nil) and (E.BitmapSize = ASize) then begin
    Exit;
  end;
  if E.VideoPlayer <> nil then begin
    E.VideoPlayer.StopPlayback;
    E.VideoPlayer := nil;
  end;
  if E.RawBuf <> nil then begin
    FreeMem(E.RawBuf);
    E.RawBuf := nil;
  end;
  FreeAndNil(E.Bitmap);
  E.PlayerVersion := 0;
  E.BitmapSize := ASize;
  GetMem(E.RawBuf, cardinal(ASize) * cardinal(ASize) * 4);
  E.VideoPlayer := TAnimationPlayer.Create(E.LocalPath, ASize, ASize);
end;

function CustomEmojiBitmapFor(AId: Int64; ASize: integer): TBGRABitmap;
var
  E: TCustomEmojiEntry;
begin
  Result := nil;
  if ASize <= 0 then begin
    Exit;
  end;
  E := Entry(AId, False);
  if (E = nil) or (E.LocalPath = '') or E.DecodeFailed then begin
    Exit;
  end;

  case E.Format of
    cmfWebp: begin
      if (E.Bitmap = nil) or (E.BitmapSize <> ASize) then begin
        FreeAndNil(E.Bitmap);
        try
          E.Bitmap := DecodeWebpFrame(E.LocalPath, ASize);
        except
          E.Bitmap := nil;
        end;
        if E.Bitmap = nil then begin
          E.DecodeFailed := True;
          Exit;
        end;
        E.BitmapSize := ASize;
      end;
      Result := E.Bitmap;
    end;

    cmfTgs: begin
      { Loops for as long as the entity is on screen — same as a
        full-message sticker (TStickerWidget), by direct request: an
        earlier version froze after a fixed time so it wouldn't make
        surrounding text unreadable, but the user explicitly asked for
        continuous looping instead, same as a real animated sticker. }
      EnsureTgsPlayer(E, ASize);
      if E.Player.Failed then begin
        E.Player.StopPlayback;
        E.Player := nil;
        E.DecodeFailed := True;
        Exit;
      end;
      if E.Player.TryGetFrame(E.RawBuf, E.PlayerVersion) then begin
        if E.Bitmap = nil then begin
          E.Bitmap := TBGRABitmap.Create(ASize, ASize, BGRAPixelTransparent);
        end;
        UnpremultiplyInto(E.RawBuf, ASize, ASize, E.Bitmap);
      end;
      Result := E.Bitmap;   { nil until the first frame has arrived }
    end;

    cmfWebm: begin
      { Confirmed common in real traffic (tdlib_raw.log has multiple
        custom-emoji packs at stickerFormatWebm) — not the rare edge
        case it was assumed to be when this format was first left
        unimplemented (reported directly: those custom emoji simply
        never rendered at all, falling back to the plain-Unicode
        alt-text glyph instead — "not pulling in custom emoji" /
        "substituting animated with static"). Reuses the same
        TAnimationPlayer/ffmpeg decode path already proven for "GIF"s
        and webm-format full-message stickers — same "loop forever
        while on screen" behavior as cmfTgs above, by the same request. }
      EnsureWebmPlayer(E, ASize);
      if E.VideoPlayer.Failed then begin
        E.VideoPlayer.StopPlayback;
        E.VideoPlayer := nil;
        E.DecodeFailed := True;
        Exit;
      end;
      if E.VideoPlayer.TryGetFrame(E.RawBuf, E.PlayerVersion) then begin
        if E.Bitmap = nil then begin
          E.Bitmap := TBGRABitmap.Create(ASize, ASize, BGRAPixelTransparent);
        end;
        CopyBgraInto(E.RawBuf, ASize, ASize, E.Bitmap);
      end;
      Result := E.Bitmap;   { nil until the first frame has arrived }
    end;
  end;
end;

function CustomEmojiStaticBitmapFor(AId: Int64; ASize: integer): TBGRABitmap;
var
  E: TCustomEmojiEntry;
  Live: TBGRABitmap;
begin
  Result := nil;
  E := Entry(AId, False);
  if E = nil then begin
    Exit;
  end;
  { Already have a frozen snapshot at the right size — return it
    immediately, WITHOUT touching the live/shared decode state at all.
    This isn't just an optimization: the live Bitmap/player slot is
    SHARED with whatever else asks for this same custom_emoji_id —
    chiefly the open chat history, at a DIFFERENT (larger) size.
    EnsureTgsPlayer/EnsureWebmPlayer tear down and restart the decoder
    on ANY size change, including one made by a completely different
    caller — so the two surfaces alternating requests at two different
    sizes constantly fight over the same slot, and Live flickers nil
    even though nothing is actually wrong.

    A previous version of this function called CustomEmojiBitmapFor
    UNCONDITIONALLY on every call and bailed out (returning nil, the
    reported "shows fallback intermittently" bug) whenever THAT
    happened to catch Live mid-flicker — confirmed directly via a
    temporary diagnostic log (customemoji_debug.log, since removed):
    ASize stayed constant the whole time and a valid snapshot existed
    continuously from the first successful resolve onward, yet Live
    kept flipping nil/non-nil throughout purely from this contention,
    and the old code let that leak into what should have been a
    permanently-resolved, contention-immune render. Skipping the call
    entirely once a snapshot exists both fixes that and, as a bonus,
    stops the chat list from contributing to the size-thrashing at all
    after the first resolve — it simply never asks again. }
  if (E.StaticSnapshot <> nil) and (E.StaticSnapshotSize = ASize) then begin
    Result := E.StaticSnapshot;
    Exit;
  end;
  Live := CustomEmojiBitmapFor(AId, ASize);   { first-time bootstrap only — runs the real fetch/decode pipeline }
  if Live = nil then begin
    Exit;
  end;
  FreeAndNil(E.StaticSnapshot);
  E.StaticSnapshot := Live.Duplicate;
  E.StaticSnapshotSize := ASize;
  Result := E.StaticSnapshot;
end;

function AnyLiveAnimating: boolean;
var
  I: integer;
begin
  Result := False;
  if FMap = nil then begin
    Exit;
  end;
  for I := 0 to FMap.Count - 1 do begin
    if (FMap.Data[I].Player <> nil) and not FMap.Data[I].Player.Failed then begin
      Result := True;
      Exit;
    end;
    if (FMap.Data[I].VideoPlayer <> nil) and not FMap.Data[I].VideoPlayer.Failed then begin
      Result := True;
      Exit;
    end;
  end;
end;

function AnyPendingWork: boolean;
var
  I: integer;
  E: TCustomEmojiEntry;
begin
  Result := False;
  if FMap = nil then begin
    Exit;
  end;
  for I := 0 to FMap.Count - 1 do begin
    E := FMap.Data[I];
    if (not E.DecodeFailed) and (E.Bitmap = nil) then begin
      Result := True;   { known, but no frame decoded/downloaded yet }
      Exit;
    end;
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
