unit tdmessages;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, base64, fgl, ExtCtrls, fpjson, jsonparser,
  constants, tdauth, tdsession, tdreq, tdchats;

type
  TMsgContentKind = (mckText, mckAudio, mckPhoto, mckAnimation, mckSticker,
    mckVoiceNote, mckFile, mckVideo, mckOther);

  { Telegram's three sticker formats — confirmed against the official
    TDLib docs (classtd_1_1td__api_1_1sticker_format*.html), not
    guessed: stickerFormatWebp (a static image), stickerFormatTgs
    (a Lottie vector, gzip-compressed JSON — see lottieplayer.pas),
    stickerFormatWebm (video, VP9 codec in a webm container — the same
    ffmpeg decoder as the "GIF" widget, videoplayer.pas, which doesn't
    care about the container). }
  TStickerFormat = (sfWebp, sfTgs, sfWebm);

  { Delivery state of an outgoing message. A separate name from
    tdchats.TMsgSendState: framehistory uses both units together, and a
    matching type name would only cause confusion. }
  TMsgDeliveryState = (mdsDelivered, mdsPending, mdsFailed);

  TMsgEntityKind = (mekNone, mekBold, mekItalic, mekUrl, mekTextUrl,
    mekCode, mekPre, mekStrikethrough, mekUnderline, mekCustomEmoji,
    mekBlockQuote);

  { A styled/link range within TMsgRow.PlainText.
    ByteStart/ByteLen are BYTE offsets into PlainText (utf8string), not
    character or UTF-16 offsets — the same indexing convention the rest
    of the project uses for utf8string (see
    avatarcache.AvatarInitials). TDLib itself counts an entity's
    offset/length in UTF-16 code units — the conversion is done once,
    by Utf16RangeToByteRange, while parsing the message. }
  TMsgEntity = record
    ByteStart: integer;
    ByteLen:   integer;
    Kind:      TMsgEntityKind;
    URL:       utf8string;   { mekTextUrl only; for mekUrl the link is the text itself }
    CustomEmojiId: Int64;    { mekCustomEmoji only }
  end;
  TMsgEntityArray = array of TMsgEntity;

  { Where a forwarded message came from — TDLib's messageOrigin variant
    type. mfoChannel is the only case where the source post's
    message_id is known (chat_id+message_id sit right in origin), so
    it's the only one that can jump to the actual message (see
    OpenChat/JumpTo below). For mfoUser/mfoChat, Telegram deliberately
    withholds the source message's id (privacy); mfoHiddenUser has
    nothing at all besides a name. Confirmed against tdlib_raw.log (all
    4 origin variants have been observed) and docs.core.telegram.org,
    not from memory. }
  TMsgForwardKind = (mfoNone, mfoUser, mfoChat, mfoChannel, mfoHiddenUser);

  { One entry of message.interaction_info.reactions.reactions — a single
    reaction "type" applied to the message, with its aggregate count.
    Three TDLib reaction-type variants, confirmed from tdlib_raw.log
    (all three seen live), not guessed: reactionTypeEmoji (a plain
    Unicode emoji — the same rendering path as an emoji in message
    text, see emojiassets.EmojiBitmapFor), reactionTypeCustomEmoji (a
    Premium emoji, the SAME custom_emoji_id space and cache as a
    mekCustomEmoji text entity — see customemoji.pas), reactionTypePaid
    (a Telegram Stars reaction — no emoji at all, just a count; drawn
    with a fixed star glyph, see TMsgScroller.PaintReactions). }
  { Prefixed "rc" (reaction-content), not the "rk" msglayout.TRunKind
    uses for its own, unrelated rkEmoji/rkText/rkLink — both units are
    in framehistory.pas's uses clause, and "rkEmoji" alone would resolve
    to the wrong enum there (a real, hit-first-try compile error: "case"
    rejects a constant of the wrong type). }
  TMsgReactionKind = (rcEmoji, rcCustomEmoji, rcPaid);
  TMsgReaction = record
    Kind: TMsgReactionKind;
    Emoji: utf8string;       { rcEmoji only }
    CustomEmojiId: Int64;    { rcCustomEmoji only }
    TotalCount: integer;
    IsChosen: boolean;       { True if this account is among the reactors }
  end;
  TMsgReactionArray = array of TMsgReaction;

  { TMsgRow

    Plain data, no LCL — same as TChatRow. ContentRaw holds the entire
    "content" JSON field: the source of truth for future renderers
    (photo/video/stickers) that need fields the model doesn't parse
    today. PlainText/Entities are already-parsed, layout-ready text
    (the message body or a caption), extracted from content once when
    parsed, so it doesn't need reparsing on every repaint. }
  TMsgRow = class
  public
    Id, ChatId:      Int64;
    SenderUserId:    Int64;   { 0 if the sender is a chat }
    SenderChatId:    Int64;   { 0 if the sender is a user }
    Date, EditDate:  Int64;
    IsOutgoing:      boolean;
    Kind:            TMsgContentKind;
    ContentRaw:      utf8string;
    PlainText:       utf8string;
    Entities:        TMsgEntityArray;
    Delivery:        TMsgDeliveryState;
    { Forward info — see TMsgForwardKind. ForwardDate is the time of the
      original post (not to be confused with Date, the time of this
      forward). }
    ForwardKind:       TMsgForwardKind;
    ForwardUserId:     Int64;   { mfoUser }
    ForwardChatId:     Int64;   { mfoChat: sender_chat_id; mfoChannel: the source's chat_id }
    ForwardMessageId:  Int64;   { mfoChannel: the message's id in the source chat }
    ForwardSenderName: utf8string;   { mfoHiddenUser; mfoChat/mfoChannel: author_signature, may be '' }
    ForwardDate:       Int64;
    { A reply (messageReplyToMessage) — 0/0 if the message isn't a
      reply, or is a reply to a story (messageReplyToStory, a separate,
      rarer variant not handled here). TDLib does NOT include the
      quoted message's content here (confirmed from tdlib_raw.log: only
      chat_id/message_id and bookkeeping fields) — the preview
      name/text is resolved separately via TTdMessages.ReplyPreview. }
    ReplyChatId:       Int64;
    ReplyMessageId:    Int64;
    { messageAudio.audio — Kind=mckAudio only. AudioDuration in seconds
      (0 if not Kind=mckAudio, or the field wasn't sent). Title/
      Performer are metadata from the file itself (ID3 etc.), which
      TDLib provides without downloading or decoding the audio; if both
      are empty, the widget's header falls back to AudioFileName. }
    AudioDuration:     integer;
    AudioTitle:        utf8string;
    AudioPerformer:    utf8string;
    AudioFileName:     utf8string;
    { The downloadable file itself (content.audio.audio, a TDLib file
      object — not to be confused with content.audio; both levels of an
      audio message are named "audio", confirmed from tdlib_raw.log).
      AudioFileId=0 means the field wasn't sent (not Kind=mckAudio).
      AudioLocalPath is empty until the file is downloaded; filled in
      by EnsureAudioFile/ApplyAudioFile, the same approach as
      TChatRow.PhotoPath in tdchats.pas. }
    AudioFileId:            integer;
    AudioLocalPath:         utf8string;
    AudioDownloadRequested: boolean;
    { messageVoiceNote.voice_note — Kind=mckVoiceNote only. The same
      two-level scheme as audio (content.voice_note.voice is the
      downloadable file, confirmed from tdlib_raw.log), but without
      title/performer/file_name — TDLib doesn't send those for voice
      notes, and the widget shows a fixed "Voice message" label instead
      (see TMsgScroller.LayoutAudioWidgets). }
    VoiceDuration:          integer;
    VoiceFileId:            integer;
    VoiceLocalPath:         utf8string;
    VoiceDownloadRequested: boolean;
    { messageDocument.document — Kind=mckFile only. The same
      double-"document" JSON scheme (content.document.file_name is
      metadata, content.document.document is the downloadable TDLib
      file object) as content.audio.audio, confirmed from
      tdlib_raw.log. }
    DocFileName:     utf8string;
    DocFileSize:     Int64;
    DocFileId:            integer;
    DocLocalPath:         utf8string;
    DocDownloadRequested: boolean;
    { messagePhoto.photo — Kind=mckPhoto only. PhotoWidth/Height are the
      natural size of the chosen (medium, type='m') layer of
      photo.sizes, used for computing the preview. PhotoMinithumb is
      the raw (already base64-decoded) bytes of a tiny JPEG, arriving
      right in the content without any download — used for a blurred
      placeholder until the real file is downloaded. }
    PhotoWidth, PhotoHeight: integer;
    PhotoMinithumb:          RawByteString;
    PhotoFileId:             integer;
    PhotoLocalPath:          utf8string;
    PhotoDownloadRequested:  boolean;
    { Download progress for the preview file above, from the SAME
      updateFile/downloadFile responses ApplyPhotoFile already handles —
      it used to bail out before even looking at these numbers whenever
      is_downloading_completed was still False, discarding them. Both
      stay 0 until the first real progress update arrives; PhotoTotalSize
      may briefly be 0 too (TDLib's own "size not known yet" state,
      file.size and file.expected_size can both be 0 for an instant) —
      TPhotoWidget.Paint treats that as "don't draw a bar", not "0%". }
    PhotoDownloadedSize:     Int64;
    PhotoTotalSize:          Int64;
    { The largest available layer of photo.sizes (by width*height, not
      by array order — TDLib's ordering from smallest to largest isn't
      relied upon) — for "Save as"/"Show in folder": saving needs the
      original, not the small preview copy (PhotoFileId above is
      deliberately medium-sized, for fast inline display, and isn't
      suitable for saving). Downloaded separately from PhotoFileId:
      different file_id, different TDLib cache file. }
    PhotoBestFileId:            integer;
    PhotoBestLocalPath:         utf8string;
    PhotoBestDownloadRequested: boolean;
    { messageAnimation.animation — Kind=mckAnimation only.
      AnimWidth/Height/Duration are the natural size (pixels) and
      duration (seconds) of the source video, the same scheme as
      PhotoWidth/Height for a photo (used for the preview via the same
      ComputePhotoPreviewSize). AnimMinithumb plays the same role as
      PhotoMinithumb (a tiny JPEG right in the content, for a
      placeholder, no download needed). The downloadable file itself is
      content.animation.animation (a TDLib file object — the same
      double-"animation" JSON naming as content.audio.audio, confirmed
      from tdlib_raw.log) — ONE layer, not two like a photo: Telegram
      delivers a "GIF" as a single MP4 file, with no set of preview
      sizes, so there's one file_id/path, with no split between
      "preview" and "original". }
    AnimWidth, AnimHeight: integer;
    AnimDuration:          integer;
    AnimMinithumb:         RawByteString;
    AnimFileId:            integer;
    AnimLocalPath:         utf8string;
    AnimDownloadRequested: boolean;
    { True is a permanent property of the ROW (not a one-shot flag that
      clears after firing once): the auto-download settings for this
      chat's kind want this "GIF" not just downloaded but immediately
      played on a loop (framehistory.pas,
      TMsgScroller.MaybeAutoDownload/LayoutAnimationWidgets — checked on
      EVERY layout pass, a self-healing behavior, see its own comment).
      A manual click by the user doesn't touch this field — only the
      auto-download setting itself does. }
    AnimAutoPlay:          boolean;
    { messageVideo.video — Kind=mckVideo only. The same double-"video"
      JSON naming (content.video.video is the downloadable TDLib file
      object, content.video is the metadata) as
      content.animation.animation, confirmed from tdlib_raw.log (55
      matches, not from memory). Unlike a "GIF", this is a real video
      with sound, played WITHOUT looping (framehistory.pas,
      TMediaPlayer — mediaplayer.pas), so there's no field analogous to
      AnimAutoPlay: auto-download for video only downloads it (see
      MaybeAutoDownload) — auto-starting playback with sound without a
      user click was never requested and would be intrusive UX.

      The preview is NOT the minithumbnail (a tiny ~40x22 base64-JPEG
      that looked poor when stretched and blurred to fill the preview)
      but content.video.thumbnail, a separate downloadable JPEG (a real
      frame, not a placeholder, sized per-video — 320x180 in the
      tdlib_raw.log examples seen). Downloaded WITHOUT the Auto
      download settings gate, unconditionally, as soon as the row
      becomes visible (framehistory.pas, LayoutVideoWidgets) — the same
      principle already applied to stickers: the file is tiny (tens of
      KB), the point being an instant response while scrolling, not a
      deliberate decision to download the whole video.

      VideoThumbWidth/Height come from content.video.thumbnail's
      METADATA (the width/height fields sit next to file and are known
      IMMEDIATELY when the message is parsed, not only after the JPEG
      itself downloads) — used instead of VideoWidth/VideoHeight (the
      video's real resolution, often 720p/1080p) to size the chat
      PREVIEW (framehistory.pas, LayoutVideoWidgets): since the preview
      is just a static image from the thumbnail, not a decoded video
      frame, sizing the preview box to the SOURCE video's resolution
      makes no sense — the thumbnail is only ever that smaller size
      anyway, and a bigger box would just get blurred by Resample.
      VideoWidth/VideoHeight remain as they were — needed by the viewer
      (mediaviewer.pas) to fit the REAL decoded video into the window
      size. }
    VideoWidth, VideoHeight:     integer;
    VideoDuration:               integer;
    VideoThumbFileId:            integer;
    VideoThumbWidth, VideoThumbHeight: integer;
    VideoThumbLocalPath:         utf8string;
    VideoThumbDownloadRequested: boolean;
    VideoFileId:                 integer;
    VideoLocalPath:              utf8string;
    VideoDownloadRequested:      boolean;
    { Download progress for the video file above — see the comment on
      PhotoDownloadedSize/PhotoTotalSize above, the same idea, same
      source (ApplyVideoFile now reads these before its own early-exit
      instead of discarding them). }
    VideoDownloadedSize:         Int64;
    VideoTotalSize:              Int64;
    { messageSticker.sticker — Kind=mckSticker only. The same
      double-"sticker" JSON naming (content.sticker.sticker is the
      downloadable TDLib file object, content.sticker is the metadata)
      as content.video.video, confirmed from tdlib_raw.log, not from
      memory — including field order (cross-checked against the
      official docs.core.telegram.org/tdlib,
      classtd_1_1td__api_1_1sticker.html: sticker_ (the file) comes
      AFTER thumbnail_, unlike video/audio/animation, where the
      downloadable file is the only field with that name). Width/height
      are "as intended by the sender" (usually 512x512 for TGS,
      arbitrary for webp/webm) — the actual on-screen size is decided
      by ComputeStickerSize (msglayout.pas), not these numbers directly.
      There's no Minithumbnail-equivalent field: a sticker has no
      inline base64 preview (unlike photo/video/"GIF") — only a
      SEPARATE downloadable thumbnail.file (128x128 WebP), unused here
      (by choice — full animation right away, no intermediate static
      placeholder from the thumbnail); before download, StickerLocalPath
      leaves the widget simply empty, same as other media types before
      the first click/auto-download. }
    StickerFormat:           TStickerFormat;
    StickerWidth, StickerHeight: integer;
    StickerFileId:           integer;
    StickerLocalPath:        utf8string;
    StickerDownloadRequested: boolean;
    { message.interaction_info.reactions.reactions — empty if the
      message has no reactions (the common case). Set unconditionally
      in ApplyMessage (independent of Kind/content — any message type
      can carry reactions) and refreshed live via
      updateMessageInteractionInfo, see TdUpdate. Display only, for
      now: no UI to add/remove a reaction of your own yet. }
    Reactions: TMsgReactionArray;
    { msglayout's layout cache. Kept as an opaque TObject rather than
      TMsgLayout — otherwise tdmessages would need to know about
      msglayout, creating a unit cycle. Freed in the destructor via a
      plain Free; the virtual destructor takes care of the rest. }
    LayoutCache:     TObject;
    destructor Destroy; override;
  end;

  TMsgMap = specialize TFPGMap<Int64, TMsgRow>;

  { Preview of a quoted (reply_to) message — either for replies to a
    message already in the loaded history (see ReplyPreview/
    RequestReply) OR fetched separately via getRepliedMessage when it's
    not yet in FAll (older than the current pagination window). Not to
    be confused with TMsgRow — this only holds what's needed to draw
    the quote itself. }
  TMsgReplyPreview = class
  public
    SenderUserId, SenderChatId: Int64;
    PreviewText: utf8string;
  end;

  TReplyMap = specialize TFPGMap<Int64, TMsgReplyPreview>;

  { Audio file_id -> message — the same approach as TTdChats.FByFile
    for avatars (tdchats.pas). }
  TAudioFileMap = specialize TFPGMap<integer, TMsgRow>;
  { Voice-note file_id -> message — the same role as TAudioFileMap for
    audio, a separate map (not shared): its own file_id, its own TDLib
    cache file, the same principle as TDocFileMap below. }
  TVoiceFileMap = specialize TFPGMap<integer, TMsgRow>;
  { Document file_id -> message — the same role as TAudioFileMap for
    audio, a separate map (not shared with TAudioFileMap): a message
    has exactly one Kind, but separate maps are easier to read than one
    shared map with a "which field to update" branch inside. }
  TDocFileMap = specialize TFPGMap<integer, TMsgRow>;
  { Same for photos — its own map, not shared with audio/documents (see
    the comment on TDocFileMap). }
  TPhotoFileMap = specialize TFPGMap<integer, TMsgRow>;
  { Same for "GIFs" (messageAnimation) — its own map, not shared with
    the others (see the comment on TDocFileMap). }
  TAnimFileMap = specialize TFPGMap<integer, TMsgRow>;
  { Same for video messages (messageVideo) — its own map, not shared
    with the others (see the comment on TDocFileMap). }
  TVideoFileMap = specialize TFPGMap<integer, TMsgRow>;
  { Video preview frame (content.video.thumbnail.file) — a separate
    file_id from the video itself (TVideoFileMap above), its own map
    for the same reason. }
  TVideoThumbFileMap = specialize TFPGMap<integer, TMsgRow>;
  { Same for stickers (messageSticker) — its own map, not shared with
    the others (see the comment on TDocFileMap). }
  TStickerFileMap = specialize TFPGMap<integer, TMsgRow>;

  TTdMessagesEvent = procedure(Sender: TObject) of object;
  TTdMessagesErrorEvent = procedure(Sender: TObject; ACode: integer;
    const AMessage, AAction: utf8string) of object;
  { The batch around AMessageId has been applied (or the message was
    already loaded) and FRows is guaranteed to see it — see
    JumpTo/JumpDone. }
  TTdMessagesJumpEvent = procedure(Sender: TObject; AMessageId: Int64) of object;

  { TTdMessages

    The history of one open chat. Unlike TTdChats, the model is not a
    permanent observer of everything at once: until a chat is opened
    via OpenChat, updates about other messages don't interest it.
    Unlike loadChats, getChatHistory returns messages directly in the
    RPC response (newest to oldest) — see HistoryDone. }

  TTdMessages = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FReq:     TTdRequests;
    FAll:     TMsgMap;    { every known message in the open chat, by id }
    FRows:    TFPList;    { the same set, in chronological order }
    FTimer:   TTimer;
    FDirty:   boolean;
    FChatId:  Int64;
    FLoadingOlder: boolean;
    FOldestLoaded: boolean;
    FLoadLimit: integer;
    { How many times in a row getChatHistory has responded without
      moving history further into the past. TDLib's own documentation
      warns that fewer messages than limit can arrive even when history
      isn't exhausted — sometimes because more is still in flight from
      background server-side prefetch. A few retries with the same
      anchor are given before history is considered exhausted; see
      HistoryDone/RetryTick. }
    FNoProgressRetries: integer;
    FRetryTimer: TTimer;

    { Filter/search mode — see SetSearchFilter. Both empty means the
      ordinary, unfiltered history; otherwise the SAME FAll/FRows/
      renderer/widget pool is fed by searchChatMessages instead of
      getChatHistory. FSearchNextFrom is TDLib's own
      next_from_message_id cursor, NOT the "anchor minus
      TD_MESSAGE_ID_STEP" arithmetic getChatHistory needs (search
      results aren't a contiguous id range, so that trick has no
      meaning here); 0 on the first request means "start at the newest
      match", 0 coming BACK means there are no more (see SearchDone).
      FSearchSeq invalidates in-flight responses whose results are no
      longer wanted — a chat switch, a different filter, or plain
      Clear; the getChatHistory path uses the chat id as its Tag for
      the same purpose, which isn't enough here because the filter can
      change without the chat changing. }
    FFilterType:     utf8string;
    FSearchQuery:    utf8string;
    FSearchNextFrom: Int64;
    FSearchTotal:    integer;
    FSearchSeq:      integer;

    FOnChanged: TTdMessagesEvent;
    FOnLoadingChanged: TTdMessagesEvent;
    FOnActionError: TTdMessagesErrorEvent;
    FOnJumpReady: TTdMessagesJumpEvent;

    { Previews of quoted (reply_to) messages not yet in FAll — see
      ReplyPreview/RequestReply/GetRepliedDone. Deliberately kept
      separate from FAll: getRepliedMessage is a one-off, targeted
      "what is that message" request, not part of sequential
      pagination, and dumping its result into FAll would break the
      assumption that FAll is a CONTIGUOUS, gap-free range of history,
      which LoadOlder/its anchor depends on (see the comments there). }
    FReplyCache: TReplyMap;
    FReplyPending: array of Int64;

    { Audio-file downloads — see EnsureAudioFile/ApplyAudioFile. }
    FByFile: TAudioFileMap;
    { Voice-note downloads — see EnsureVoiceFile/ApplyVoiceFile. }
    FVoiceByFile: TVoiceFileMap;
    { Document-file downloads — see EnsureDocFile/ApplyDocFile. }
    FDocByFile: TDocFileMap;
    { Photo downloads — see EnsurePhotoFile/ApplyPhotoFile. }
    FPhotoByFile: TPhotoFileMap;
    { Original (largest layer) downloads — see
      EnsurePhotoBestFile/ApplyPhotoBestFile. A separate map: different
      file_id, different TDLib cache file than the preview download
      above (see the comment on TMsgRow.PhotoBestFileId). }
    FPhotoBestByFile: TPhotoFileMap;
    { "GIF" downloads — see EnsureAnimFile/ApplyAnimFile. }
    FAnimByFile: TAnimFileMap;
    { Video-message downloads — see EnsureVideoFile/ApplyVideoFile. }
    FVideoByFile: TVideoFileMap;
    { Video preview-frame downloads — see
      EnsureVideoThumbFile/ApplyVideoThumbFile. }
    FVideoThumbByFile: TVideoThumbFileMap;
    { Sticker downloads — see EnsureStickerFile/ApplyStickerFile. }
    FStickerByFile: TStickerFileMap;
    { custom_emoji_ids with a getCustomEmojiStickers request in flight
      — see IsCustomEmojiPending/MarkCustomEmojiPending/
      ClearCustomEmojiPending, the same array-based approach as
      FReplyPending above (small, short-lived set, no map needed). The
      cache itself (metadata, file, decoded bitmap) lives in
      customemoji.pas, not here — it's keyed by custom_emoji_id alone,
      shared across every chat/row that happens to use the same custom
      emoji, unlike the *ByFile maps above which are all per-TMsgRow. }
    FCustomEmojiPending: array of Int64;

    function GetCount: integer;
    function GetRow(AIndex: integer): TMsgRow;
    function Lookup(AId: Int64): TMsgRow;
    function Obtain(AId: Int64): TMsgRow;

    procedure ApplyMessage(AMsg: TJSONObject);
    procedure ApplyContentUpdate(AChatId, AMessageId: Int64; ANewContent: TJSONObject);
    procedure ExtractFormatted(AContent: TJSONObject; const AType: utf8string;
      out APlainText: utf8string; out AEntities: TMsgEntityArray);
    { AInteractionInfo is the whole message.interaction_info object (may
      be nil — an older/system message can lack it entirely); reads
      .reactions.reactions inside it. }
    procedure ExtractReactions(AInteractionInfo: TJSONObject;
      out AReactions: TMsgReactionArray);
    procedure ExtractAudioMeta(AContent: TJSONObject; const AType: utf8string;
      out ADuration: integer; out ATitle, APerformer, AFileName: utf8string;
      out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadAudioDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyAudioFile(AFile: TJSONObject);
    procedure ExtractVoiceMeta(AContent: TJSONObject; const AType: utf8string;
      out ADuration: integer; out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadVoiceDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyVoiceFile(AFile: TJSONObject);
    procedure ExtractDocMeta(AContent: TJSONObject; const AType: utf8string;
      out AFileName: utf8string; out AFileSize: Int64;
      out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadDocDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyDocFile(AFile: TJSONObject);
    procedure ExtractPhotoMeta(AContent: TJSONObject; const AType: utf8string;
      out AWidth, AHeight: integer; out AMinithumb: RawByteString;
      out AFileId: integer; out ALocalPath: utf8string;
      out ABestFileId: integer; out ABestLocalPath: utf8string);
    procedure DownloadPhotoDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyPhotoFile(AFile: TJSONObject);
    procedure DownloadPhotoBestDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyPhotoBestFile(AFile: TJSONObject);
    procedure ExtractAnimMeta(AContent: TJSONObject; const AType: utf8string;
      out AWidth, AHeight, ADuration: integer; out AMinithumb: RawByteString;
      out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadAnimDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyAnimFile(AFile: TJSONObject);
    procedure ExtractVideoMeta(AContent: TJSONObject; const AType: utf8string;
      out AWidth, AHeight, ADuration: integer;
      out AThumbFileId, AThumbWidth, AThumbHeight: integer; out AThumbLocalPath: utf8string;
      out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadVideoDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyVideoFile(AFile: TJSONObject);
    procedure DownloadVideoThumbDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyVideoThumbFile(AFile: TJSONObject);
    procedure ExtractStickerMeta(AContent: TJSONObject; const AType: utf8string;
      out AWidth, AHeight: integer; out AFormat: TStickerFormat;
      out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadStickerDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyStickerFile(AFile: TJSONObject);
    function IsCustomEmojiPending(AId: Int64): boolean;
    procedure MarkCustomEmojiPending(AId: Int64);
    procedure ClearCustomEmojiPending(AId: Int64);
    procedure GetCustomEmojiStickersDone(Sender: TObject; const AResp: TTdResponse);
    procedure DownloadCustomEmojiDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyCustomEmojiFile(AFile: TJSONObject);

    procedure Touch;
    procedure Rebuild(Sender: TObject);
    procedure SetLoadingOlder(AValue: boolean);
    function GetSearchActive: boolean;
    procedure SearchDone(Sender: TObject; const AResp: TTdResponse);
    procedure HistoryDone(Sender: TObject; const AResp: TTdResponse);
    procedure RetryTick(Sender: TObject);
    procedure SendTextDone(Sender: TObject; const AResp: TTdResponse);
    { Callback for SendFormattedText's own parseTextEntities request —
      see that method's comment for the two-step reason it's needed. }
    procedure ParseEntitiesDone(Sender: TObject; const AResp: TTdResponse);
    procedure ActionDone(Sender: TObject; const AResp: TTdResponse);
    procedure JumpDone(Sender: TObject; const AResp: TTdResponse);
    function IsReplyPending(AId: Int64): boolean;
    procedure MarkReplyPending(AId: Int64);
    procedure ClearReplyPending(AId: Int64);
    procedure RequestReply(AMessageId: Int64);
    procedure GetRepliedDone(Sender: TObject; const AResp: TTdResponse);
  public
    { The model belongs to an account, the resolver is passed in from
      outside — the same approach as TTdChats. }
    constructor Create(AOwner: TComponent; const ASession: ITdSession;
      AReq: TTdRequests); reintroduce;
    destructor Destroy; override;

    procedure Clear;
    { Switches to another chat. Same id is a no-op (except for
      AJumpToMessageId <> 0, see below). AJumpToMessageId <> 0: instead
      of a normal LoadOlder (recent messages, from the end), loads a
      batch AROUND that id (see JumpTo) — following a forward-card
      quote to another message in a different (or the same) chat, the
      same way as "jump to message" in the official client: open the
      chat and scroll to the message, rather than building a shareable
      link (getMessageLink requires membership in the chat — not the
      case for a forward's source, which is usually not in the chat
      list). }
    procedure OpenChat(AChatId: Int64; AJumpToMessageId: Int64 = 0);
    procedure CloseChat;
    { Loads an older page of history — or, while a filter/search is
      active, an older page of MATCHES (see SetSearchFilter). }
    procedure LoadOlder;

    { Switches the open chat between its ordinary history and a
      filtered/searched view of itself. AFilterType is a TDLib
      SearchMessagesFilter constructor name ('searchMessagesFilterPhoto'
      and friends — the exact spellings are in constants.pas as
      TD_MSG_FILTER_*), AQuery a full-text query; either may be empty,
      and BOTH empty means "back to the ordinary history".

      Deliberately NOT a separate model/list: searchChatMessages returns
      the very same `message` objects getChatHistory does, so the whole
      already-debugged pipeline below (ApplyMessage, every Ensure*File,
      the reply cache, custom emoji) and everything above it in
      framehistory (the scroller, the widget pools, text selection, the
      media viewer) work on the results unchanged. What differs is only
      where the batch comes from and how it is paged — see LoadOlder/
      SearchDone.

      Note the chat itself stays open in TDLib's eyes: openChat/
      closeChat are NOT re-sent here (the user is still looking at this
      chat, just at a subset of it), unlike OpenChat/CloseChat. }
    procedure SetSearchFilter(const AFilterType, AQuery: utf8string);
    { The message's index in Rows[] by its id, -1 if not loaded. Needed
      by framehistory for selecting text across several messages and
      for holding the scroll anchor during LoadOlder. }
    function IndexOfId(AId: Int64): integer;

    { A two-step send: parseTextEntities first turns AMarkupText — plain
      text carrying Telegram's own MarkdownV2 or HTML formatting syntax,
      inserted by the message input toolbar's buttons around the user's
      selection (msginput.pas) — into a real formattedText object (text
      plus a parsed entities array), then that result is sent as
      inputMessageText.text (see ParseEntitiesDone). Text with none of
      that markup in it is simply formattedText with an empty entities
      array — the same path, no separate plain-text send left in this
      unit. AIsHtml selects which of the two syntaxes AMarkupText is
      written in. }
    procedure SendFormattedText(const AMarkupText: utf8string; AIsHtml: boolean);
    procedure MarkRead(const AMessageIds: array of Int64);
    { Loads (if not already loaded) and prepares for display a batch of
      messages AROUND AMessageId in the CURRENTLY open chat — not to be
      confused with OpenChat(AChatId, AJumpToMessageId), which first
      switches chats entirely. Signaled via OnJumpReady, synchronously
      (no RPC) if AMessageId is already in FAll. }
    procedure JumpTo(AMessageId: Int64);
    { Data for drawing a reply_to quote — replies within the SAME chat
      only (AChatId <> ChatId — cross-chat replies, e.g. a channel and
      its discussion group, aren't supported here: a rare case not
      worth a cache keyed by a composite chat+message pair — returns
      False without attempting a resolve).
      Returns True with data if the preview is already available (in
      FAll or FReplyCache); False means the preview isn't available
      yet, but getRepliedMessage has been (or is about to be) started,
      and the result will arrive via OnChanged. }
    function ReplyPreview(AChatId, AMessageId: Int64;
      out ASenderUserId, ASenderChatId: Int64; out APreviewText: utf8string): boolean;
    { Requests the message's audio file (see AudioFileId) to be
      downloaded, if not already downloaded or requested. The result
      arrives via updateFile -> Touch (ARow.AudioLocalPath fills in on
      its own); framehistory finds out through the ordinary repaint, no
      separate event is set up — the same approach already used for
      avatars. }
    procedure EnsureAudioFile(ARow: TMsgRow);
    { Same for a voice note (see VoiceFileId) — the same approach. }
    procedure EnsureVoiceFile(ARow: TMsgRow);
    { EnsureAudioFile/EnsureVoiceFile under one name — the same
      audio/voice_note decoupling as "one playable track from the
      caller's perspective" used by PlayableLocalPath (see its
      comment). }
    procedure EnsurePlayableFile(ARow: TMsgRow);
    { Same for a document file (see DocFileId) — the same approach. }
    procedure EnsureDocFile(ARow: TMsgRow);
    { Same for a photo (see PhotoFileId) — the same approach. }
    procedure EnsurePhotoFile(ARow: TMsgRow);
    { The photo's original (see PhotoBestFileId) — for "Save as"/"Show
      in folder", separate from the preview above (see the field's
      comment). }
    procedure EnsurePhotoBestFile(ARow: TMsgRow);
    { Same for a "GIF" (see AnimFileId) — the same approach. }
    procedure EnsureAnimFile(ARow: TMsgRow);
    { Same for a video message (see VideoFileId) — the same approach. }
    procedure EnsureVideoFile(ARow: TMsgRow);
    { The video preview frame (see VideoThumbFileId) — WITHOUT the Auto
      download settings gate, the same principle as stickers (see the
      comment on the TMsgRow.VideoThumbFileId field) — framehistory.pas
      calls this unconditionally as soon as the row is visible. }
    procedure EnsureVideoThumbFile(ARow: TMsgRow);
    { Same for a sticker (see StickerFileId) — the same approach. }
    procedure EnsureStickerFile(ARow: TMsgRow);
    { Fetches real stickers (via getCustomEmojiStickers, then the usual
      downloadFile dance) for every distinct custom_emoji_id used in
      ARow.Entities not already known — see customemoji.pas. Same
      "framehistory.pas calls this unconditionally for visible rows, no
      Auto download gate" principle as EnsureVideoThumbFile/stickers. }
    procedure EnsureCustomEmojiForRow(ARow: TMsgRow);

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property ChatId: Int64 read FChatId;
    property Count: integer read GetCount;
    property Rows[AIndex: integer]: TMsgRow read GetRow; default;
    property LoadingOlder: boolean read FLoadingOlder;
    property OldestLoaded: boolean read FOldestLoaded;
    property LoadLimit: integer read FLoadLimit write FLoadLimit;

    { Filter/search state — see SetSearchFilter. SearchTotalCount is
      TDLib's own total_count for the current query (how many matches
      exist in the chat, not how many are loaded so far); it is only
      meaningful while SearchActive. }
    property SearchActive: boolean read GetSearchActive;
    property SearchFilter: utf8string read FFilterType;
    property SearchQuery: utf8string read FSearchQuery;
    property SearchTotalCount: integer read FSearchTotal;

    property Session: ITdSession read FSession;
    property OnChanged: TTdMessagesEvent read FOnChanged write FOnChanged;
    property OnActionError: TTdMessagesErrorEvent read FOnActionError write FOnActionError;
    property OnLoadingChanged: TTdMessagesEvent read FOnLoadingChanged write FOnLoadingChanged;
    property OnJumpReady: TTdMessagesJumpEvent read FOnJumpReady write FOnJumpReady;
  end;

{ Status icon for an OUTGOING message — the same concept as ChatReceipt
  in tdchats.pas (its TChatReceipt is reused, no second enum is
  defined). ALastReadOutbox is TChatRow.LastReadOutbox for the chat
  ARow belongs to; framehistory.pas fetches it via
  TdChatList.Lookup(ARow.ChatId). }
function MessageReceipt(ARow: TMsgRow; ALastReadOutbox: Int64): TChatReceipt;

{ Path to the already-downloaded track file for playback — messageAudio
  and messageVoiceNote store it in DIFFERENT fields (AudioLocalPath/
  VoiceLocalPath, different file_id, different download maps in
  TTdMessages), but framehistory.pas treats them as ONE playable track:
  TAudioWidget is a shared widget for both audio and voice notes
  ("identical functionality and appearance"), so the code around
  playback (StartPlayback/AudioPlayClick/ModelChanged) shouldn't have
  to re-decide which of the two fields to read at every step.
  '' means Kind isn't mckAudio/mckVoiceNote, or the file isn't
  downloaded yet. }
function PlayableLocalPath(ARow: TMsgRow): utf8string;
{ The same audio/voice_note decoupling, for duration (AudioDuration/
  VoiceDuration) — needed when seeking (AFraction * duration). }
function PlayableDuration(ARow: TMsgRow): integer;

implementation

uses
  customemoji;

function MessageReceipt(ARow: TMsgRow; ALastReadOutbox: Int64): TChatReceipt;
begin
  Result := crNone;
  if (ARow = nil) or (not ARow.IsOutgoing) then begin
    Exit;
  end;
  case ARow.Delivery of
    mdsPending: Result := crPending;
    mdsFailed:  Result := crFailed;
  else
    if ARow.Id <= ALastReadOutbox then begin
      Result := crRead;
    end else begin
      Result := crSent;
    end;
  end;
end;

function PlayableLocalPath(ARow: TMsgRow): utf8string;
begin
  Result := '';
  if ARow = nil then begin
    Exit;
  end;
  case ARow.Kind of
    mckAudio:     Result := ARow.AudioLocalPath;
    mckVoiceNote: Result := ARow.VoiceLocalPath;
  end;
end;

function PlayableDuration(ARow: TMsgRow): integer;
begin
  Result := 0;
  if ARow = nil then begin
    Exit;
  end;
  case ARow.Kind of
    mckAudio:     Result := ARow.AudioDuration;
    mckVoiceNote: Result := ARow.VoiceDuration;
  end;
end;

{ UTF-8 character length from its leading byte — the same logic as
  avatarcache.Utf8CharLen. That unit isn't reused directly: avatarcache
  pulls in Graphics/BGRABitmap, and tdmessages must stay LCL-free, same
  as tdchats. }
function Utf8CharLen(AByte: byte): integer;
begin
  if AByte < $80 then begin
    Result := 1;
  end else if AByte < $C0 then begin
    Result := 1;
  end else if AByte < $E0 then begin
    Result := 2;
  end else if AByte < $F0 then begin
    Result := 3;
  end else begin
    Result := 4;
  end;
end;

{ TDLib counts an entity's offset/length in UTF-16 code units (a
  surrogate pair counts as 2 units). PlainText is a utf8string, indexed
  by byte. This walks the string once, decoding code points, and tracks
  the matching byte boundaries. An entity whose boundary would fall
  INSIDE a surrogate pair (possible only for non-BMP characters, i.e.
  most emoji) is rounded to the nearest code-point boundary — rare and
  not critical for v1. }
procedure Utf16RangeToByteRange(const AText: utf8string;
  AUtf16Offset, AUtf16Length: integer; out AByteStart, AByteLen: integer);
var
  I, N, Units, TargetStart, TargetEnd, CodeLen: integer;
  Cp: cardinal;

  function DecodeCp(APos: integer; out ALen: integer): cardinal;
  var
    B0: byte;
  begin
    B0 := byte(AText[APos]);
    ALen := Utf8CharLen(B0);
    if APos + ALen - 1 > Length(AText) then begin
      ALen := Length(AText) - APos + 1;
    end;
    case ALen of
      1: Result := B0;
      2: Result := ((B0 and $1F) shl 6) or (byte(AText[APos + 1]) and $3F);
      3: Result := ((B0 and $0F) shl 12) or ((byte(AText[APos + 1]) and $3F) shl 6)
                   or (byte(AText[APos + 2]) and $3F);
    else
      Result := ((B0 and $07) shl 18) or ((byte(AText[APos + 1]) and $3F) shl 12)
                or ((byte(AText[APos + 2]) and $3F) shl 6) or (byte(AText[APos + 3]) and $3F);
    end;
  end;

begin
  TargetStart := AUtf16Offset;
  TargetEnd := AUtf16Offset + AUtf16Length;
  N := Length(AText);
  AByteStart := N + 1;
  AByteLen := 0;

  I := 1;
  Units := 0;
  while I <= N do begin
    if Units = TargetStart then begin
      AByteStart := I;
    end;
    Cp := DecodeCp(I, CodeLen);
    if Cp > $FFFF then begin
      Inc(Units, 2);
    end else begin
      Inc(Units, 1);
    end;
    Inc(I, CodeLen);
    if Units >= TargetEnd then begin
      if AByteStart > N then begin
        AByteStart := I;   { TargetStart fell inside the last character }
      end;
      AByteLen := I - AByteStart;
      Exit;
    end;
  end;
  if AByteStart > N then begin
    AByteStart := N + 1;
  end;
  AByteLen := (N + 1) - AByteStart;
end;

function ContentKindFromType(const AType: utf8string): TMsgContentKind;
begin
  if AType = 'messageText' then begin
    Result := mckText;
  end else if AType = 'messageAudio' then begin
    Result := mckAudio;
  end else if AType = 'messagePhoto' then begin
    Result := mckPhoto;
  end else if AType = 'messageAnimation' then begin
    Result := mckAnimation;
  end else if AType = 'messageSticker' then begin
    Result := mckSticker;
  end else if AType = 'messageAnimatedEmoji' then begin
    { A large animated emoji reaction (just an emoji sent on its own,
      with no surrounding text) — TDLib wraps it in EXACTLY the same
      sticker object as a regular sticker, just one level deeper
      (content.animated_emoji.sticker instead of content.sticker, see
      ExtractStickerMeta) — confirmed from tdlib_raw.log (106
      occurrences in one session, noticeably MORE often than regular
      stickers at 32) — the same widget, the same rendering, no
      separate Kind needed. }
    Result := mckSticker;
  end else if AType = 'messageVoiceNote' then begin
    Result := mckVoiceNote;
  end else if AType = 'messageDocument' then begin
    Result := mckFile;
  end else if AType = 'messageVideo' then begin
    Result := mckVideo;
  end else begin
    Result := mckOther;
  end;
end;

function EntityKindFromType(const AType: utf8string): TMsgEntityKind;
begin
  if AType = 'textEntityTypeBold' then begin
    Result := mekBold;
  end else if AType = 'textEntityTypeItalic' then begin
    Result := mekItalic;
  end else if AType = 'textEntityTypeUrl' then begin
    Result := mekUrl;
  end else if AType = 'textEntityTypeTextUrl' then begin
    Result := mekTextUrl;
  end else if AType = 'textEntityTypeCode' then begin
    Result := mekCode;
  end else if AType = 'textEntityTypePre' then begin
    Result := mekPre;
  end else if AType = 'textEntityTypeStrikethrough' then begin
    Result := mekStrikethrough;
  end else if AType = 'textEntityTypeUnderline' then begin
    Result := mekUnderline;
  end else if AType = 'textEntityTypeCustomEmoji' then begin
    Result := mekCustomEmoji;
  end else if (AType = 'textEntityTypeBlockQuote')
           or (AType = 'textEntityTypeExpandableBlockQuote') then begin
    { Both render the same way here — the expandable/collapsible
      behavior itself (a "show more" toggle for long quotes) is not
      implemented, only the visual "this is a quote" treatment, same
      as any other entity kind this project doesn't fully model yet
      (see e.g. mekPre, which also has no dedicated rendering). }
    Result := mekBlockQuote;
  end else begin
    Result := mekNone;
  end;
end;

{ ---------------- TMsgRow ---------------- }

destructor TMsgRow.Destroy;
begin
  LayoutCache.Free;
  inherited Destroy;
end;

{ ---------------- TTdMessages ---------------- }

constructor TTdMessages.Create(AOwner: TComponent; const ASession: ITdSession;
  AReq: TTdRequests);
begin
  inherited Create(AOwner);
  FSession := ASession;
  FReq := AReq;
  FAll := TMsgMap.Create;
  FAll.Sorted := True;
  FRows := TFPList.Create;
  FReplyCache := TReplyMap.Create;
  FReplyCache.Sorted := True;
  FByFile := TAudioFileMap.Create;
  FByFile.Sorted := True;
  FVoiceByFile := TVoiceFileMap.Create;
  FVoiceByFile.Sorted := True;
  FDocByFile := TDocFileMap.Create;
  FDocByFile.Sorted := True;
  FPhotoByFile := TPhotoFileMap.Create;
  FPhotoByFile.Sorted := True;
  FPhotoBestByFile := TPhotoFileMap.Create;
  FPhotoBestByFile.Sorted := True;
  FAnimByFile := TAnimFileMap.Create;
  FAnimByFile.Sorted := True;
  FVideoByFile := TVideoFileMap.Create;
  FVideoByFile.Sorted := True;
  FVideoThumbByFile := TVideoThumbFileMap.Create;
  FVideoThumbByFile.Sorted := True;
  FStickerByFile := TStickerFileMap.Create;
  FStickerByFile.Sorted := True;
  FLoadLimit := 50;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := MESSAGES_COALESCE_MS;
  FTimer.OnTimer := @Rebuild;
  FTimer.Enabled := False;

  FRetryTimer := TTimer.Create(Self);
  FRetryTimer.Interval := RETRY_DELAY_MS;
  FRetryTimer.OnTimer := @RetryTick;
  FRetryTimer.Enabled := False;

  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdMessages.Destroy;
begin
  FTimer.Enabled := False;
  FRetryTimer.Enabled := False;
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  Clear;
  FRows.Free;
  FAll.Free;
  FReplyCache.Free;
  FByFile.Free;
  FVoiceByFile.Free;
  FDocByFile.Free;
  FPhotoByFile.Free;
  FPhotoBestByFile.Free;
  FAnimByFile.Free;
  FVideoByFile.Free;
  FVideoThumbByFile.Free;
  FStickerByFile.Free;
  inherited Destroy;
end;

procedure TTdMessages.Clear;
var
  I: integer;
begin
  FRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    FAll.Data[I].Free;
  end;
  FAll.Clear;
  for I := 0 to FReplyCache.Count - 1 do begin
    FReplyCache.Data[I].Free;
  end;
  FReplyCache.Clear;
  FByFile.Clear;
  FVoiceByFile.Clear;
  FDocByFile.Clear;
  FPhotoByFile.Clear;
  FPhotoBestByFile.Clear;
  FAnimByFile.Clear;
  FVideoByFile.Clear;
  FVideoThumbByFile.Clear;
  FStickerByFile.Clear;
  SetLength(FReplyPending, 0);
  { Every reset path goes through here (OpenChat, CloseChat,
    SetSearchFilter), so this is the one place the search generation
    has to be bumped: any searchChatMessages response still in flight
    belongs to a view that no longer exists and must not be applied to
    the rows being built now. }
  Inc(FSearchSeq);
  FFilterType := '';
  FSearchQuery := '';
  FSearchNextFrom := 0;
  FSearchTotal := 0;
  FLoadingOlder := False;
  FOldestLoaded := False;
  FNoProgressRetries := 0;
  FRetryTimer.Enabled := False;
  FDirty := False;
  FTimer.Enabled := False;
end;

procedure TTdMessages.OpenChat(AChatId: Int64; AJumpToMessageId: Int64);
begin
  if FChatId = AChatId then begin
    { Same chat — usually a no-op, but a quote jump can still point at
      a message in the CURRENTLY open chat (a forward from another
      message in the same conversation) — history isn't reloaded from
      scratch, just the needed section is fetched/shown. }
    if AJumpToMessageId <> 0 then begin
      JumpTo(AJumpToMessageId);
    end;
    Exit;
  end;
  { closeChat/openChat aren't about data (that flows independently
    through updates and RPC responses) — they TELL TDLib which chat is
    actually being shown to the user right now. Without this, TDLib
    considers itself free to evict the message cache of a chat that
    hasn't been explicitly "open" for a while, and sends
    updateDeleteMessages with from_cache:true — previously treated as
    a real deletion (see TdUpdate), which could shrink a chat left open
    for hours down to a single message. }
  if (FChatId <> 0) and (FReq <> nil) then begin
    FReq.SendRequest('closeChat', '"chat_id":' + utf8string(IntToStr(FChatId)), @ActionDone);
  end;
  Clear;
  FChatId := AChatId;
  if (FChatId <> 0) and (FReq <> nil) then begin
    FReq.SendRequest('openChat', '"chat_id":' + utf8string(IntToStr(FChatId)), @ActionDone);
  end;
  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
  if AChatId <> 0 then begin
    if AJumpToMessageId <> 0 then begin
      JumpTo(AJumpToMessageId);
    end else begin
      LoadOlder;
    end;
  end;
end;

procedure TTdMessages.CloseChat;
begin
  if (FChatId <> 0) and (FReq <> nil) then begin
    FReq.SendRequest('closeChat', '"chat_id":' + utf8string(IntToStr(FChatId)), @ActionDone);
  end;
  Clear;
  FChatId := 0;
end;

function TTdMessages.GetCount: integer;
begin
  Result := FRows.Count;
end;

function TTdMessages.GetRow(AIndex: integer): TMsgRow;
begin
  if (AIndex < 0) or (AIndex >= FRows.Count) then begin
    Result := nil;
  end else begin
    Result := TMsgRow(FRows[AIndex]);
  end;
end;

function TTdMessages.IndexOfId(AId: Int64): integer;
var
  I: integer;
begin
  { A deliberate linear scan over FRows rather than FAll.IndexOf: FAll
    and FRows can drift apart during the debounce window (up to 50ms
    after Touch, before Rebuild fires) — LoadOlder adds messages with
    SMALLER ids to FAll, shifting the indices of existing FAll entries
    before FRows sees it. A linear scan over FRows always stays
    consistent with Count/Rows[], which the caller (framehistory)
    actually uses. }
  Result := -1;
  for I := 0 to FRows.Count - 1 do begin
    if TMsgRow(FRows[I]).Id = AId then begin
      Result := I;
      Exit;
    end;
  end;
end;

function TTdMessages.Lookup(AId: Int64): TMsgRow;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FAll.IndexOf(AId);
  if Idx >= 0 then begin
    Result := FAll.Data[Idx];
  end;
end;

function TTdMessages.Obtain(AId: Int64): TMsgRow;
begin
  Result := Lookup(AId);
  if Result = nil then begin
    Result := TMsgRow.Create;
    Result.Id := AId;
    FAll.Add(AId, Result);
  end;
end;

procedure TTdMessages.Touch;
begin
  FDirty := True;
  FTimer.Enabled := True;
end;

procedure TTdMessages.Rebuild(Sender: TObject);
var
  I: integer;
begin
  FTimer.Enabled := False;
  if not FDirty then begin
    Exit;
  end;
  FDirty := False;

  { FAll is sorted by id (TFPGMap.Sorted), and TDLib message ids are
    monotonically non-decreasing within a chat — so FAll.Data is
    already in chronological order, no re-sort needed. }
  FRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    FRows.Add(FAll.Data[I]);
  end;

  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

function TTdMessages.GetSearchActive: boolean;
begin
  Result := (FFilterType <> '') or (FSearchQuery <> '');
end;

procedure TTdMessages.SetSearchFilter(const AFilterType, AQuery: utf8string);
begin
  if (FFilterType = AFilterType) and (FSearchQuery = AQuery) then begin
    Exit;
  end;
  { Clear wipes the loaded rows AND the search state (and bumps the
    generation), so the new filter is set AFTER it, not before. }
  Clear;
  FFilterType := AFilterType;
  FSearchQuery := AQuery;

  if Assigned(FOnChanged) then begin
    { Synchronously, before any request goes out — the list is already
      empty at this point and the view must show that immediately
      rather than keep the previous filter's results on screen until
      the response arrives. }
    FOnChanged(Self);
  end;
  if FChatId <> 0 then begin
    LoadOlder;
  end;
end;

procedure TTdMessages.SetLoadingOlder(AValue: boolean);
begin
  if FLoadingOlder = AValue then begin
    Exit;
  end;
  FLoadingOlder := AValue;
  if Assigned(FOnLoadingChanged) then begin
    FOnLoadingChanged(Self);
  end;
end;

procedure TTdMessages.LoadOlder;
var
  Anchor: Int64;
  Offset: integer;
  QueryVal: TJSONString;
  FilterPart, Body: utf8string;
begin
  if FLoadingOlder or FOldestLoaded or (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;
  if (FSession = nil) or (FSession.State <> tasReady) then begin
    Exit;
  end;
  SetLoadingOlder(True);

  { --- filtered/searched view: a different request and a completely
        different paging rule, but the SAME ApplyMessage on the way back
        (see SetSearchFilter / SearchDone) --- }
  if SearchActive then begin
    { An empty filter has to be spelled out rather than omitted:
      searchMessagesFilterEmpty is a real constructor in the schema
      (verified against td_api.tl, not assumed), and "no filter at all"
      is not something the parameter accepts. topic_id and sender_id
      are left out entirely — both are nullable and mean "anywhere in
      the chat, from anyone". }
    if FFilterType = '' then begin
      FilterPart := TD_MSG_FILTER_EMPTY;
    end else begin
      FilterPart := FFilterType;
    end;
    { The query is arbitrary user input — quoted/escaped through fpjson
      rather than pasted into the body, the same rule SendFormattedText
      follows for message text. }
    QueryVal := TJSONString.Create(string(FSearchQuery));
    try
      Body := '"chat_id":' + utf8string(IntToStr(FChatId)) +
        ',"query":' + utf8string(QueryVal.AsJSON) +
        ',"from_message_id":' + utf8string(IntToStr(FSearchNextFrom)) +
        ',"offset":0' +
        ',"limit":' + utf8string(IntToStr(FLoadLimit)) +
        ',"filter":{"@type":"' + FilterPart + '"}';
    finally
      QueryVal.Free;
    end;
    FReq.SendRequest('searchChatMessages', Body, @SearchDone, PtrInt(FSearchSeq));
    Exit;
  end;

  { IMPORTANT: the anchor is taken from FAll, not FRows. FRows is a
    derived view, rebuilt on a delay via a 50ms timer (Touch/Rebuild),
    while FAll is updated SYNCHRONOUSLY inside ApplyMessage. Taking the
    anchor from FRows would leave up to a 50ms window where FRows
    hasn't yet seen a just-applied response — a LoadOlder call landing
    in that window (the user keeps scrolling, ScrollerNearTop fires
    again) would go out with a stale, already-superseded
    from_message_id. Confirmed from tdlib_raw.log: req:13/req:14 went
    out with the SAME from_message_id as req:12, even though req:12 had
    already moved history further by then — precisely because LoadOlder
    was reading a not-yet-rebuilt FRows.

    from_message_id = the anchor MINUS TD_MESSAGE_ID_STEP (not the
    anchor itself) with offset:0 — not the known boundary itself, but
    the neighboring "slot" just older than our oldest known message.
    TDLib's offset:0 "starts exactly at from_message_id"; passing the
    anchor itself (an already-known, cached message) doesn't move
    history at all in practice — see the earlier attempt with a
    negative offset, which didn't get stuck outright but empirically
    yielded exactly one new message per request, due to a 49/50 window
    overlap at offset:-(limit-1).

    WARNING (one version of this fix already hit this): the subtraction
    must be exactly TD_MESSAGE_ID_STEP, NOT an arbitrary unit — the id
    must stay a multiple of that constant, otherwise TDLib responds
    with code 400 "Invalid value of parameter from_message_id
    specified" on EVERY such request, and since the error doesn't move
    the anchor, the next LoadOlder call recomputes the SAME invalid id
    and gets the same error — without the guard in HistoryDone (see
    below), this is a tight infinite request/error loop, which is
    exactly what happened once. }
  if FAll.Count = 0 then begin
    Anchor := 0;
    Offset := 0;
  end else begin
    Anchor := FAll.Data[0].Id - TD_MESSAGE_ID_STEP;
    Offset := 0;
  end;

  { NOTE: parameter names are cross-checked against general knowledge
    of the TDLib schema, not a local td_api.tl (not present in this
    repository) — worth re-verifying against the documentation on the
    first real run.

    Tag = FChatId: if the user switches to a different chat while this
    request is in flight, the response arrives for what is now a
    different FChatId. HistoryDone checks Tag and silently ignores such
    a response — otherwise it could reset the CURRENT chat's
    FLoadingOlder/FOldestLoaded with data belonging to someone else's
    chat (PtrInt is 8 bytes on this platform, same as Int64: the
    project only builds for win64). }
  FReq.SendRequest('getChatHistory',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"from_message_id":' + utf8string(IntToStr(Anchor)) +
    ',"offset":' + utf8string(IntToStr(Offset)) +
    ',"limit":' + utf8string(IntToStr(FLoadLimit)) +
    ',"only_local":false', @HistoryDone, PtrInt(FChatId));
end;

{ searchChatMessages -> foundChatMessages, an object carrying
  total_count, messages and next_from_message_id. The messages array is
  named and shaped exactly
  like getChatHistory's, so ApplyMessage is reused verbatim; what is
  genuinely different is paging and the end-of-results signal, and
  neither of getChatHistory's two hard-won workarounds applies:

  - no "anchor minus TD_MESSAGE_ID_STEP" arithmetic — search results
    are scattered ids, not a contiguous range, and TDLib hands back its
    own cursor (next_from_message_id) for exactly this;
  - no no-progress retry/backoff counter — 0 in that cursor is an
    unambiguous "that was the last page", so there is no ambiguous
    "fewer than limit, but maybe more later" case to retry around. }
procedure TTdMessages.SearchDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
begin
  { A response for a filter/chat the user has since moved away from —
    see FSearchSeq. Note the CURRENT view's FLoadingOlder must NOT be
    cleared here: it belongs to whatever request is in flight now. }
  if AResp.Tag <> PtrInt(FSearchSeq) then begin
    Exit;
  end;

  SetLoadingOlder(False);
  if not AResp.Success then begin
    if Assigned(FOnActionError) then begin
      FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'search');
    end;
    { No retry: unlike getChatHistory's anchor, a failing search would
      fail identically on every retry (a filter TDLib rejects for this
      chat kind, no permission to search, ...) — retrying would just be
      the same tight loop that once fired 108 thousand requests, with
      nothing that could change the outcome between attempts. }
    FOldestLoaded := True;
    Exit;
  end;

  FSearchTotal := JGetInt(AResp.Obj, 'total_count');
  FSearchNextFrom := JGetInt64(AResp.Obj, 'next_from_message_id');
  if FSearchNextFrom = 0 then begin
    FOldestLoaded := True;
  end;

  Arr := JGetArr(AResp.Obj, 'messages');
  if (Arr = nil) or (Arr.Count = 0) then begin
    FOldestLoaded := True;
    { Still notify: "nothing found" is a result the view has to show,
      and without this an empty first page would leave the previous
      Touch-less state on screen. }
    Touch;
    Exit;
  end;

  { Newest to oldest, same as getChatHistory — applied in reverse so
    FAll fills oldest-to-newest. Per-message try/except for the same
    reason as there: one unexpected content shape must not abort the
    batch or escape into TTdRequests.Resolve. }
  for I := Arr.Count - 1 downto 0 do begin
    if Arr.Items[I].JSONType = jtObject then begin
      try
        ApplyMessage(TJSONObject(Arr.Items[I]));
      except
        on E: Exception do begin
          if Assigned(FOnActionError) then begin
            FOnActionError(Self, 0, utf8string(E.Message), 'search-parse');
          end;
        end;
      end;
    end;
  end;
  Touch;
end;

procedure TTdMessages.HistoryDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  OldestBefore, OldestAfter: Int64;
begin
  { A response for a chat the user already closed/switched away from
    while the request was in flight — not this case, the CURRENT
    chat's state is left untouched. }
  if AResp.Tag <> PtrInt(FChatId) then begin
    Exit;
  end;
  { A filter was switched on while this getChatHistory was still in
    flight. The chat id guard above does NOT catch that — the chat
    hasn't changed, only the view of it has — and applying an ordinary
    history page into a result list would quietly fill it with messages
    that match nothing. (The mirror case, a searchChatMessages response
    arriving after the filter is gone, is caught by FSearchSeq.) }
  if SearchActive then begin
    Exit;
  end;

  SetLoadingOlder(False);
  if not AResp.Success then begin
    if AResp.ErrorCode = 404 then begin
      FOldestLoaded := True;
      Exit;
    end;
    if Assigned(FOnActionError) then begin
      { Otherwise a getChatHistory failure (e.g. a wrong parameter
        name) fails silently: the list stays empty with no clue why. }
      FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'history');
    end;
    { IMPORTANT: an error must go through the SAME counter/backoff as
      "success without progress" below, not a plain Exit. The reason
      isn't hypothetical — the absence of exactly this guard once
      turned one incorrectly-computed from_message_id into a tight
      infinite loop: request -> error -> (FLoadingOlder already False)
      -> MaybeLoadMore/ScrollerNearTop calls LoadOlder again -> same
      anchor -> same error (108 thousand consecutive code-400 requests
      recorded in tdlib_raw.log). If LoadOlder recomputes the same bad
      anchor on the next call, give up after MAX_NO_PROGRESS_RETRIES
      attempts and treat history as exhausted, instead of hammering
      indefinitely. }
    Inc(FNoProgressRetries);
    if FNoProgressRetries >= MAX_NO_PROGRESS_RETRIES then begin
      FOldestLoaded := True;
      FNoProgressRetries := 0;
    end else begin
      FRetryTimer.Enabled := True;
    end;
    Exit;
  end;

  Arr := JGetArr(AResp.Obj, 'messages');
  if (Arr = nil) or (Arr.Count = 0) then begin
    FOldestLoaded := True;
    Exit;
  end;

  { The oldest message BEFORE applying the batch, taken from FAll
    (sorted by id), not FRows: FRows rebuilds on a delay via the 50ms
    Touch/Rebuild timer, and at this exact moment it hasn't yet seen
    what's about to be applied. }
  if FAll.Count = 0 then begin
    OldestBefore := 0;
  end else begin
    OldestBefore := FAll.Data[0].Id;
  end;

  { getChatHistory returns messages newest to oldest — applied in
    reverse order so FAll fills in oldest-to-newest order. Each message
    gets its own try/except: one unexpected JSON shape (e.g. a
    content type not seen before) must not abort the whole batch, and
    certainly must not escape through TTdRequests.Resolve, where
    nothing would catch it. }
  for I := Arr.Count - 1 downto 0 do begin
    if Arr.Items[I].JSONType = jtObject then begin
      try
        ApplyMessage(TJSONObject(Arr.Items[I]));
      except
        on E: Exception do begin
          if Assigned(FOnActionError) then begin
            FOnActionError(Self, 0, utf8string(E.Message), 'history-parse');
          end;
        end;
      end;
    end;
  end;

  { NOT "Arr.Count < FLoadLimit means history is exhausted": per the
    documentation, getChatHistory lets TDLib itself choose how many
    messages to actually return "for optimal performance", and that
    can be fewer than limit LONG before history actually ends
    (officially confirmed: "fewer messages may be returned... even if
    the end of the message history has not been reached" — sometimes
    because the rest is still in flight from background server-side
    prefetch, see github.com/tdlib/td issues #236 and #740). The only
    reliable end-of-history signal is an empty array (see above) or a
    404.

    But just as surely, getChatHistory must not be hammered with the
    same anchor indefinitely without a counter: if a batch does NOT
    move history further into the past (a common case — TDLib sends
    back a single duplicate of the anchor itself, see the maintainer's
    comment in issue #236), a few more DELAYED retries are given
    (through FRetryTimer, not synchronously — a synchronous retry
    inside this same callback once hung the app in a tight
    request/response/rebuild loop). Only after
    MAX_NO_PROGRESS_RETRIES consecutive failures is history considered
    exhausted. }
  if FAll.Count = 0 then begin
    OldestAfter := 0;
  end else begin
    OldestAfter := FAll.Data[0].Id;
  end;

  if (OldestBefore <> 0) and (OldestAfter >= OldestBefore) then begin
    Inc(FNoProgressRetries);
    if FNoProgressRetries >= MAX_NO_PROGRESS_RETRIES then begin
      FOldestLoaded := True;
      FNoProgressRetries := 0;
    end else begin
      FRetryTimer.Enabled := True;
    end;
  end else begin
    FNoProgressRetries := 0;
  end;
end;

procedure TTdMessages.RetryTick(Sender: TObject);
begin
  FRetryTimer.Enabled := False;
  LoadOlder;
end;

procedure TTdMessages.ExtractFormatted(AContent: TJSONObject; const AType: utf8string;
  out APlainText: utf8string; out AEntities: TMsgEntityArray);
var
  FT: TJSONObject;
  Arr: TJSONArray;
  I, N, ByteStart, ByteLen: integer;
  EObj, TypeObj: TJSONObject;
  EKind: TMsgEntityKind;
begin
  APlainText := '';
  SetLength(AEntities, 0);
  if AContent = nil then begin
    Exit;
  end;

  if AType = 'messageText' then begin
    FT := JGetObj(AContent, 'text');
  end else begin
    { Every other type that can have a caption (photo, video, audio,
      document, animation, ...) stores it the same way, as a
      formattedText, in the caption field. }
    FT := JGetObj(AContent, 'caption');
  end;
  if FT = nil then begin
    Exit;
  end;
  APlainText := JGetStr(FT, 'text');
  if APlainText = '' then begin
    Exit;
  end;

  Arr := JGetArr(FT, 'entities');
  if Arr = nil then begin
    Exit;
  end;
  SetLength(AEntities, Arr.Count);
  N := 0;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    EObj := TJSONObject(Arr.Items[I]);
    TypeObj := JGetObj(EObj, 'type');
    EKind := EntityKindFromType(JGetStr(TypeObj, '@type'));
    if EKind = mekNone then begin
      Continue;
    end;
    Utf16RangeToByteRange(APlainText, JGetInt(EObj, 'offset'), JGetInt(EObj, 'length'),
      ByteStart, ByteLen);
    if ByteLen <= 0 then begin
      Continue;
    end;
    AEntities[N].ByteStart := ByteStart;
    AEntities[N].ByteLen := ByteLen;
    AEntities[N].Kind := EKind;
    AEntities[N].CustomEmojiId := 0;
    if EKind = mekTextUrl then begin
      AEntities[N].URL := JGetStr(TypeObj, 'url');
    end else begin
      AEntities[N].URL := '';
      if EKind = mekCustomEmoji then begin
        AEntities[N].CustomEmojiId := JGetInt64(TypeObj, 'custom_emoji_id');
      end;
    end;
    Inc(N);
  end;
  SetLength(AEntities, N);
end;

{ message.interaction_info.reactions.reactions — confirmed straight from
  tdlib_raw.log, not guessed: a messageReactions object holding an
  array of messageReaction (type/total_count/is_chosen/...), where
  type is one of reactionTypeEmoji/reactionTypeCustomEmoji/
  reactionTypePaid. }
procedure TTdMessages.ExtractReactions(AInteractionInfo: TJSONObject;
  out AReactions: TMsgReactionArray);
var
  ReactionsObj: TJSONObject;
  Arr: TJSONArray;
  I, N: integer;
  Item, TypeObj: TJSONObject;
  TypeStr: utf8string;
begin
  SetLength(AReactions, 0);
  if AInteractionInfo = nil then begin
    Exit;
  end;
  ReactionsObj := JGetObj(AInteractionInfo, 'reactions');
  if ReactionsObj = nil then begin
    Exit;
  end;
  Arr := JGetArr(ReactionsObj, 'reactions');
  if Arr = nil then begin
    Exit;
  end;
  SetLength(AReactions, Arr.Count);
  N := 0;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    Item := TJSONObject(Arr.Items[I]);
    TypeObj := JGetObj(Item, 'type');
    TypeStr := JGetStr(TypeObj, '@type');
    AReactions[N].Emoji := '';
    AReactions[N].CustomEmojiId := 0;
    if TypeStr = 'reactionTypeCustomEmoji' then begin
      AReactions[N].Kind := rcCustomEmoji;
      AReactions[N].CustomEmojiId := JGetInt64(TypeObj, 'custom_emoji_id');
    end else if TypeStr = 'reactionTypePaid' then begin
      AReactions[N].Kind := rcPaid;
    end else begin
      AReactions[N].Kind := rcEmoji;
      AReactions[N].Emoji := JGetStr(TypeObj, 'emoji');
    end;
    AReactions[N].TotalCount := JGetInt(Item, 'total_count');
    AReactions[N].IsChosen := JGetBool(Item, 'is_chosen');
    Inc(N);
  end;
  SetLength(AReactions, N);
end;

{ messageAudio.audio — metadata from the file itself (ID3 etc.), which
  TDLib includes directly in content, with no download/decode needed.
  Confirmed from tdlib_raw.log: "content":{"@type":"messageAudio",
  "audio":{"@type":"audio","duration":214,"title":"...","performer":
  "...","file_name":"..."}}. }
procedure TTdMessages.ExtractAudioMeta(AContent: TJSONObject; const AType: utf8string;
  out ADuration: integer; out ATitle, APerformer, AFileName: utf8string;
  out AFileId: integer; out ALocalPath: utf8string);
var
  AudioObj, FileObj, LocalObj: TJSONObject;
begin
  ADuration := 0;
  ATitle := '';
  APerformer := '';
  AFileName := '';
  AFileId := 0;
  ALocalPath := '';
  if (AContent = nil) or (AType <> 'messageAudio') then begin
    Exit;
  end;
  AudioObj := JGetObj(AContent, 'audio');
  if AudioObj = nil then begin
    Exit;
  end;
  ADuration := JGetInt(AudioObj, 'duration');
  ATitle := JGetStr(AudioObj, 'title');
  APerformer := JGetStr(AudioObj, 'performer');
  AFileName := JGetStr(AudioObj, 'file_name');

  { content.audio.audio is the downloadable file itself (a TDLib file
    object), a separate level from content.audio (the track's
    metadata) — both are named "audio", confirmed from tdlib_raw.log,
    not from memory. }
  FileObj := JGetObj(AudioObj, 'audio');
  if FileObj = nil then begin
    Exit;
  end;
  AFileId := JGetInt(FileObj, 'id');
  LocalObj := JGetObj(FileObj, 'local');
  if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
    ALocalPath := JGetStr(LocalObj, 'path');
  end;
end;

{ messageVoiceNote.voice_note — the same two-level scheme as
  content.audio.audio: content.voice_note is metadata (only duration
  here — TDLib provides no title/performer/file_name for voice notes),
  content.voice_note.voice is the downloadable TDLib file object
  itself. Confirmed from tdlib_raw.log ("voice_note":{"@type":
  "voiceNote","duration":7,"waveform":"...","mime_type":"audio/ogg",
  "voice":{"@type":"file",...}}), not from memory. waveform is present
  but not read: the widget shared with regular audio doesn't draw a
  waveform (matching TAudioWidget's appearance exactly). }
procedure TTdMessages.ExtractVoiceMeta(AContent: TJSONObject; const AType: utf8string;
  out ADuration: integer; out AFileId: integer; out ALocalPath: utf8string);
var
  VoiceObj, FileObj, LocalObj: TJSONObject;
begin
  ADuration := 0;
  AFileId := 0;
  ALocalPath := '';
  if (AContent = nil) or (AType <> 'messageVoiceNote') then begin
    Exit;
  end;
  VoiceObj := JGetObj(AContent, 'voice_note');
  if VoiceObj = nil then begin
    Exit;
  end;
  ADuration := JGetInt(VoiceObj, 'duration');

  FileObj := JGetObj(VoiceObj, 'voice');
  if FileObj = nil then begin
    Exit;
  end;
  AFileId := JGetInt(FileObj, 'id');
  LocalObj := JGetObj(FileObj, 'local');
  if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
    ALocalPath := JGetStr(LocalObj, 'path');
  end;
end;

{ messageDocument.document — the same double-"document" JSON scheme as
  content.audio.audio above: content.document is metadata (file name),
  content.document.document is the downloadable TDLib file object
  itself. Confirmed from tdlib_raw.log, not from memory. }
procedure TTdMessages.ExtractDocMeta(AContent: TJSONObject; const AType: utf8string;
  out AFileName: utf8string; out AFileSize: Int64;
  out AFileId: integer; out ALocalPath: utf8string);
var
  DocObj, FileObj, LocalObj: TJSONObject;
begin
  AFileName := '';
  AFileSize := 0;
  AFileId := 0;
  ALocalPath := '';
  if (AContent = nil) or (AType <> 'messageDocument') then begin
    Exit;
  end;
  DocObj := JGetObj(AContent, 'document');
  if DocObj = nil then begin
    Exit;
  end;
  AFileName := JGetStr(DocObj, 'file_name');

  FileObj := JGetObj(DocObj, 'document');
  if FileObj = nil then begin
    Exit;
  end;
  AFileSize := JGetInt64(FileObj, 'size');
  AFileId := JGetInt(FileObj, 'id');
  LocalObj := JGetObj(FileObj, 'local');
  if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
    ALocalPath := JGetStr(LocalObj, 'path');
  end;
end;

{ messagePhoto.photo — content.photo.minithumbnail is a tiny JPEG right
  in the content (base64, the data field), no download needed;
  content.photo.sizes is an array of photoSize (type/width/height/photo
  — the downloadable TDLib file object itself), confirmed from
  tdlib_raw.log, not from memory. TWO DIFFERENT layers are picked out
  of one array in a single pass: AFileId/ALocalPath is the SMALLEST
  layer that's still enough to fill the PHOTO_MAX_WIDTH×PHOTO_MAX_HEIGHT
  preview (msglayout.pas) WITHOUT upscaling — this used to be hardcoded
  to type='m' (Telegram's 'm' is a fixed box around 320px, noticeably
  smaller than PHOTO_MAX_WIDTH/HEIGHT=400, and
  ComputePhotoPreviewSize won't upscale it either way — the result
  wasn't "our resample is bad" but an honestly small, more heavily
  compressed JPEG layer, shown SMALLER than the space allotted for it
  in the block). If no layer reaches the target (the source itself is
  smaller than PHOTO_MAX_WIDTH/HEIGHT), the same layer as ABestFileId
  below is used — there's nowhere bigger to find. ABestFileId/
  ABestLocalPath is the layer with the maximum width*height, for "Save
  as"/"Show in folder" (saving needs the original, not the preview
  copy) — chosen by area, not array order, since TDLib's ordering of
  sizes from smallest to largest isn't relied upon. }
procedure TTdMessages.ExtractPhotoMeta(AContent: TJSONObject; const AType: utf8string;
  out AWidth, AHeight: integer; out AMinithumb: RawByteString;
  out AFileId: integer; out ALocalPath: utf8string;
  out ABestFileId: integer; out ABestLocalPath: utf8string);
var
  PhotoObj, MiniObj, SizeObj, FileObj, LocalObj: TJSONObject;
  Arr: TJSONArray;
  I, PreviewIdx, LargestIdx, W, H: integer;
  LargestArea, PreviewArea, Area: Int64;
  B64: utf8string;
begin
  AWidth := 0;
  AHeight := 0;
  AMinithumb := '';
  AFileId := 0;
  ALocalPath := '';
  ABestFileId := 0;
  ABestLocalPath := '';
  if (AContent = nil) or (AType <> 'messagePhoto') then begin
    Exit;
  end;
  PhotoObj := JGetObj(AContent, 'photo');
  if PhotoObj = nil then begin
    Exit;
  end;

  MiniObj := JGetObj(PhotoObj, 'minithumbnail');
  if MiniObj <> nil then begin
    B64 := JGetStr(MiniObj, 'data');
    if B64 <> '' then begin
      AMinithumb := DecodeStringBase64(string(B64));
    end;
  end;

  Arr := JGetArr(PhotoObj, 'sizes');
  if (Arr = nil) or (Arr.Count = 0) then begin
    Exit;
  end;
  LargestIdx := 0;
  LargestArea := -1;
  PreviewIdx := -1;
  PreviewArea := -1;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    W := JGetInt(TJSONObject(Arr.Items[I]), 'width');
    H := JGetInt(TJSONObject(Arr.Items[I]), 'height');
    Area := Int64(W) * H;
    if Area > LargestArea then begin
      LargestArea := Area;
      LargestIdx := I;
    end;
    if (W >= PHOTO_MAX_WIDTH) and (H >= PHOTO_MAX_HEIGHT) then begin
      if (PreviewArea < 0) or (Area < PreviewArea) then begin
        PreviewArea := Area;
        PreviewIdx := I;
      end;
    end;
  end;
  if PreviewIdx < 0 then begin
    PreviewIdx := LargestIdx;
  end;

  if Arr.Items[PreviewIdx].JSONType = jtObject then begin
    SizeObj := TJSONObject(Arr.Items[PreviewIdx]);
    AWidth := JGetInt(SizeObj, 'width');
    AHeight := JGetInt(SizeObj, 'height');
    FileObj := JGetObj(SizeObj, 'photo');
    if FileObj <> nil then begin
      AFileId := JGetInt(FileObj, 'id');
      LocalObj := JGetObj(FileObj, 'local');
      if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
        ALocalPath := JGetStr(LocalObj, 'path');
      end;
    end;
  end;

  if Arr.Items[LargestIdx].JSONType = jtObject then begin
    SizeObj := TJSONObject(Arr.Items[LargestIdx]);
    FileObj := JGetObj(SizeObj, 'photo');
    if FileObj <> nil then begin
      ABestFileId := JGetInt(FileObj, 'id');
      LocalObj := JGetObj(FileObj, 'local');
      if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
        ABestLocalPath := JGetStr(LocalObj, 'path');
      end;
    end;
  end;
end;

{ messageAnimation.animation — content.animation.minithumbnail is the
  same kind of tiny JPEG as a photo's (base64, the data field), no
  download needed; content.animation.animation is the downloadable
  TDLib file object itself (the same double-name scheme as
  content.audio.audio) — confirmed from tdlib_raw.log (real "GIF"
  messages have been observed there), not from memory. Unlike a photo,
  there's ONE layer, not an array of sizes: Telegram delivers a "GIF"
  as a single whole MP4 file, with no set of preview sizes. }
procedure TTdMessages.ExtractAnimMeta(AContent: TJSONObject; const AType: utf8string;
  out AWidth, AHeight, ADuration: integer; out AMinithumb: RawByteString;
  out AFileId: integer; out ALocalPath: utf8string);
var
  AnimObj, MiniObj, FileObj, LocalObj: TJSONObject;
  B64: utf8string;
begin
  AWidth := 0;
  AHeight := 0;
  ADuration := 0;
  AMinithumb := '';
  AFileId := 0;
  ALocalPath := '';
  if (AContent = nil) or (AType <> 'messageAnimation') then begin
    Exit;
  end;
  AnimObj := JGetObj(AContent, 'animation');
  if AnimObj = nil then begin
    Exit;
  end;
  AWidth := JGetInt(AnimObj, 'width');
  AHeight := JGetInt(AnimObj, 'height');
  ADuration := JGetInt(AnimObj, 'duration');

  MiniObj := JGetObj(AnimObj, 'minithumbnail');
  if MiniObj <> nil then begin
    B64 := JGetStr(MiniObj, 'data');
    if B64 <> '' then begin
      AMinithumb := DecodeStringBase64(string(B64));
    end;
  end;

  FileObj := JGetObj(AnimObj, 'animation');
  if FileObj = nil then begin
    Exit;
  end;
  AFileId := JGetInt(FileObj, 'id');
  LocalObj := JGetObj(FileObj, 'local');
  if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
    ALocalPath := JGetStr(LocalObj, 'path');
  end;
end;

{ messageVideo.video — the same double-"video" JSON naming
  (content.video.video is the downloadable TDLib file object,
  content.video is metadata) as content.animation.animation —
  confirmed from tdlib_raw.log (55 matches against real video
  messages), not from memory. One layer, like a "GIF", not an array of
  sizes like a photo.

  content.video.thumbnail is a SEPARATE object, not the same thing as
  content.video.video: a fixed JPEG frame (not base64, its own
  downloadable file, nested one level deeper — thumbnail.file.id/
  thumbnail.file.local), used for the chat preview in place of the
  earlier blur from a minithumbnail (see the comment on
  TMsgRow.VideoThumbFileId for why). thumbnail.width/height sit at the
  same level as file, not inside it — known immediately from the
  message's metadata, without waiting for the JPEG itself to
  download. }
procedure TTdMessages.ExtractVideoMeta(AContent: TJSONObject; const AType: utf8string;
  out AWidth, AHeight, ADuration: integer;
  out AThumbFileId, AThumbWidth, AThumbHeight: integer; out AThumbLocalPath: utf8string;
  out AFileId: integer; out ALocalPath: utf8string);
var
  VideoObj, ThumbObj, ThumbFileObj, FileObj, LocalObj: TJSONObject;
begin
  AWidth := 0;
  AHeight := 0;
  ADuration := 0;
  AThumbFileId := 0;
  AThumbWidth := 0;
  AThumbHeight := 0;
  AThumbLocalPath := '';
  AFileId := 0;
  ALocalPath := '';
  if (AContent = nil) or (AType <> 'messageVideo') then begin
    Exit;
  end;
  VideoObj := JGetObj(AContent, 'video');
  if VideoObj = nil then begin
    Exit;
  end;
  AWidth := JGetInt(VideoObj, 'width');
  AHeight := JGetInt(VideoObj, 'height');
  ADuration := JGetInt(VideoObj, 'duration');

  ThumbObj := JGetObj(VideoObj, 'thumbnail');
  if ThumbObj <> nil then begin
    AThumbWidth := JGetInt(ThumbObj, 'width');
    AThumbHeight := JGetInt(ThumbObj, 'height');
    ThumbFileObj := JGetObj(ThumbObj, 'file');
    if ThumbFileObj <> nil then begin
      AThumbFileId := JGetInt(ThumbFileObj, 'id');
      LocalObj := JGetObj(ThumbFileObj, 'local');
      if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
        AThumbLocalPath := JGetStr(LocalObj, 'path');
      end;
    end;
  end;

  FileObj := JGetObj(VideoObj, 'video');
  if FileObj = nil then begin
    Exit;
  end;
  AFileId := JGetInt(FileObj, 'id');
  LocalObj := JGetObj(FileObj, 'local');
  if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
    ALocalPath := JGetStr(LocalObj, 'path');
  end;
end;

procedure TTdMessages.ExtractStickerMeta(AContent: TJSONObject; const AType: utf8string;
  out AWidth, AHeight: integer; out AFormat: TStickerFormat;
  out AFileId: integer; out ALocalPath: utf8string);
var
  StickerObj, EmojiObj, FormatObj, FileObj, LocalObj: TJSONObject;
  FmtType: utf8string;
begin
  AWidth := 0;
  AHeight := 0;
  AFormat := sfWebp;
  AFileId := 0;
  ALocalPath := '';
  if AContent = nil then begin
    Exit;
  end;
  if AType = 'messageSticker' then begin
    StickerObj := JGetObj(AContent, 'sticker');
  end else if AType = 'messageAnimatedEmoji' then begin
    { content.animated_emoji.sticker is the same sticker object as a
      regular sticker, one level deeper (see the comment in
      ContentKindFromType). animated_emoji can in principle arrive
      without a sticker at all (TDLib formally allows sticker=null when
      no animation is configured for that emoji) — JGetObj returns nil,
      handled below by the same general Exit as a regular sticker. }
    EmojiObj := JGetObj(AContent, 'animated_emoji');
    StickerObj := JGetObj(EmojiObj, 'sticker');
  end else begin
    Exit;
  end;
  if StickerObj = nil then begin
    Exit;
  end;
  AWidth := JGetInt(StickerObj, 'width');
  AHeight := JGetInt(StickerObj, 'height');

  FormatObj := JGetObj(StickerObj, 'format');
  FmtType := JGetStr(FormatObj, '@type');
  if FmtType = 'stickerFormatTgs' then begin
    AFormat := sfTgs;
  end else if FmtType = 'stickerFormatWebm' then begin
    AFormat := sfWebm;
  end else begin
    AFormat := sfWebp;
  end;

  { content.sticker.sticker uses the same double-name scheme as
    video/audio/animation, but HERE the field comes AFTER thumbnail
    (cross-checked against the official docs.core.telegram.org/tdlib,
    not guessed and not assumed by analogy with the other types, which
    order it differently). }
  FileObj := JGetObj(StickerObj, 'sticker');
  if FileObj = nil then begin
    Exit;
  end;
  AFileId := JGetInt(FileObj, 'id');
  LocalObj := JGetObj(FileObj, 'local');
  if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
    ALocalPath := JGetStr(LocalObj, 'path');
  end;
end;

procedure TTdMessages.ApplyMessage(AMsg: TJSONObject);
var
  R: TMsgRow;
  Id, MsgChatId: Int64;
  T: utf8string;
  ContentObj, SenderObj, FwdObj, OriginObj, ReplyObj: TJSONObject;
  SenderType, St, OriginType: utf8string;
  NewContentRaw: utf8string;
  WasNew: boolean;
begin
  if AMsg = nil then begin
    Exit;
  end;
  MsgChatId := JGetInt64(AMsg, 'chat_id');
  if (FChatId <> 0) and (MsgChatId <> FChatId) then begin
    Exit;
  end;
  Id := JGetInt64(AMsg, 'id');
  if Id = 0 then begin
    Exit;
  end;

  WasNew := Lookup(Id) = nil;
  R := Obtain(Id);
  R.ChatId := MsgChatId;
  R.Date := JGetInt64(AMsg, 'date');
  R.EditDate := JGetInt64(AMsg, 'edit_date');
  R.IsOutgoing := JGetBool(AMsg, 'is_outgoing');

  SenderObj := JGetObj(AMsg, 'sender_id');
  SenderType := JGetStr(SenderObj, '@type');
  if SenderType = 'messageSenderUser' then begin
    R.SenderUserId := JGetInt64(SenderObj, 'user_id');
    R.SenderChatId := 0;
  end else if SenderType = 'messageSenderChat' then begin
    R.SenderChatId := JGetInt64(SenderObj, 'chat_id');
    R.SenderUserId := 0;
  end;

  { forward_info is absent from ordinary messages (JGetObj returns nil)
    — origin is parsed by @type, see the comment on TMsgForwardKind. }
  FwdObj := JGetObj(AMsg, 'forward_info');
  if FwdObj = nil then begin
    R.ForwardKind := mfoNone;
  end else begin
    OriginObj := JGetObj(FwdObj, 'origin');
    OriginType := JGetStr(OriginObj, '@type');
    R.ForwardDate := JGetInt64(FwdObj, 'date');
    R.ForwardUserId := 0;
    R.ForwardChatId := 0;
    R.ForwardMessageId := 0;
    R.ForwardSenderName := '';
    if OriginType = 'messageOriginUser' then begin
      R.ForwardKind := mfoUser;
      R.ForwardUserId := JGetInt64(OriginObj, 'sender_user_id');
    end else if OriginType = 'messageOriginChat' then begin
      R.ForwardKind := mfoChat;
      R.ForwardChatId := JGetInt64(OriginObj, 'sender_chat_id');
      R.ForwardSenderName := JGetStr(OriginObj, 'author_signature');
    end else if OriginType = 'messageOriginChannel' then begin
      R.ForwardKind := mfoChannel;
      R.ForwardChatId := JGetInt64(OriginObj, 'chat_id');
      R.ForwardMessageId := JGetInt64(OriginObj, 'message_id');
      R.ForwardSenderName := JGetStr(OriginObj, 'author_signature');
    end else if OriginType = 'messageOriginHiddenUser' then begin
      R.ForwardKind := mfoHiddenUser;
      R.ForwardSenderName := JGetStr(OriginObj, 'sender_name');
    end else begin
      R.ForwardKind := mfoNone;
    end;
  end;

  { reply_to — messageReplyToMessage only (a reply to a message);
    messageReplyToStory (a reply to a story) isn't parsed,
    ReplyMessageId stays 0 — the quote simply isn't drawn then, same as
    with no reply_to at all. TDLib itself does NOT include the quoted
    message's content here — only chat_id/message_id (confirmed from
    tdlib_raw.log); the text/name for display is resolved separately
    and lazily by ReplyPreview. }
  ReplyObj := JGetObj(AMsg, 'reply_to');
  if (ReplyObj <> nil) and (JGetStr(ReplyObj, '@type') = 'messageReplyToMessage') then begin
    R.ReplyChatId := JGetInt64(ReplyObj, 'chat_id');
    R.ReplyMessageId := JGetInt64(ReplyObj, 'message_id');
  end else begin
    R.ReplyChatId := 0;
    R.ReplyMessageId := 0;
  end;

  St := JGetStr(JGetObj(AMsg, 'sending_state'), '@type');
  if St = 'messageSendingStatePending' then begin
    R.Delivery := mdsPending;
  end else if St = 'messageSendingStateFailed' then begin
    R.Delivery := mdsFailed;
  end else begin
    R.Delivery := mdsDelivered;
  end;

  { Reactions are unrelated to content — parsed unconditionally, ahead
    of the "same content, early return" check below: a message can be
    re-delivered byte-for-byte identical in content (overlapping
    pagination pages, a repeated getChatHistory) while its reaction
    counts have moved on since the last time it was seen. }
  ExtractReactions(JGetObj(AMsg, 'interaction_info'), R.Reactions);

  ContentObj := JGetObj(AMsg, 'content');
  if ContentObj <> nil then begin
    T := JGetStr(ContentObj, '@type');
    NewContentRaw := utf8string(ContentObj.AsJSON);
  end else begin
    T := '';
    NewContentRaw := '';
  end;

  { The exact same message can arrive again, byte for byte —
    overlapping pagination pages, a repeated getChatHistory, etc. If
    the content hasn't changed, entity parsing isn't rerun and
    LayoutCache isn't invalidated: for messages with media, content
    includes a base64 preview, and parsing plus the resulting
    text-wrap recompute noticeably load the main thread — with a batch
    of fifty such messages, that shows up as the UI stalling. }
  if (not WasNew) and (R.ContentRaw = NewContentRaw) then begin
    Touch;
    Exit;
  end;

  R.ContentRaw := NewContentRaw;
  R.Kind := ContentKindFromType(T);
  ExtractFormatted(ContentObj, T, R.PlainText, R.Entities);
  ExtractAudioMeta(ContentObj, T, R.AudioDuration, R.AudioTitle, R.AudioPerformer, R.AudioFileName,
    R.AudioFileId, R.AudioLocalPath);
  ExtractVoiceMeta(ContentObj, T, R.VoiceDuration, R.VoiceFileId, R.VoiceLocalPath);
  ExtractDocMeta(ContentObj, T, R.DocFileName, R.DocFileSize, R.DocFileId, R.DocLocalPath);
  ExtractPhotoMeta(ContentObj, T, R.PhotoWidth, R.PhotoHeight, R.PhotoMinithumb,
    R.PhotoFileId, R.PhotoLocalPath, R.PhotoBestFileId, R.PhotoBestLocalPath);
  ExtractAnimMeta(ContentObj, T, R.AnimWidth, R.AnimHeight, R.AnimDuration,
    R.AnimMinithumb, R.AnimFileId, R.AnimLocalPath);
  ExtractVideoMeta(ContentObj, T, R.VideoWidth, R.VideoHeight, R.VideoDuration,
    R.VideoThumbFileId, R.VideoThumbWidth, R.VideoThumbHeight, R.VideoThumbLocalPath,
    R.VideoFileId, R.VideoLocalPath);
  ExtractStickerMeta(ContentObj, T, R.StickerWidth, R.StickerHeight, R.StickerFormat,
    R.StickerFileId, R.StickerLocalPath);

  if R.LayoutCache <> nil then begin
    R.LayoutCache.Free;
    R.LayoutCache := nil;
  end;

  Touch;
end;

procedure TTdMessages.ApplyContentUpdate(AChatId, AMessageId: Int64;
  ANewContent: TJSONObject);
var
  R: TMsgRow;
  T: utf8string;
begin
  if (AChatId <> FChatId) or (ANewContent = nil) then begin
    Exit;
  end;
  R := Lookup(AMessageId);
  if R = nil then begin
    Exit;
  end;
  T := JGetStr(ANewContent, '@type');
  R.Kind := ContentKindFromType(T);
  R.ContentRaw := utf8string(ANewContent.AsJSON);
  ExtractFormatted(ANewContent, T, R.PlainText, R.Entities);
  ExtractAudioMeta(ANewContent, T, R.AudioDuration, R.AudioTitle, R.AudioPerformer, R.AudioFileName,
    R.AudioFileId, R.AudioLocalPath);
  ExtractVoiceMeta(ANewContent, T, R.VoiceDuration, R.VoiceFileId, R.VoiceLocalPath);
  ExtractDocMeta(ANewContent, T, R.DocFileName, R.DocFileSize, R.DocFileId, R.DocLocalPath);
  ExtractPhotoMeta(ANewContent, T, R.PhotoWidth, R.PhotoHeight, R.PhotoMinithumb,
    R.PhotoFileId, R.PhotoLocalPath, R.PhotoBestFileId, R.PhotoBestLocalPath);
  ExtractAnimMeta(ANewContent, T, R.AnimWidth, R.AnimHeight, R.AnimDuration,
    R.AnimMinithumb, R.AnimFileId, R.AnimLocalPath);
  ExtractVideoMeta(ANewContent, T, R.VideoWidth, R.VideoHeight, R.VideoDuration,
    R.VideoThumbFileId, R.VideoThumbWidth, R.VideoThumbHeight, R.VideoThumbLocalPath,
    R.VideoFileId, R.VideoLocalPath);
  ExtractStickerMeta(ANewContent, T, R.StickerWidth, R.StickerHeight, R.StickerFormat,
    R.StickerFileId, R.StickerLocalPath);
  if R.LayoutCache <> nil then begin
    R.LayoutCache.Free;
    R.LayoutCache := nil;
  end;
  Touch;
end;

procedure TTdMessages.SendTextDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    ApplyMessage(AResp.Obj);
  end else if Assigned(FOnActionError) then begin
    FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'send');
  end;
end;

{ Escapes reserved MarkdownV2 punctuation in a string. All reserved
  characters are single ASCII bytes (never a continuation byte of a
  multi-byte UTF-8 sequence), so operating on utf8string as a plain
  byte array is safe. Used both directly — on the WHOLE message, in
  SendFormattedText, because a bare '.', '!' or '>' the user simply
  typed (not one of the toolbar's own formatting markers, msginput.pas)
  makes TDLib reject the ENTIRE send with a parse error, not silently
  ignore just that character — and recursively, on the CONTENT of a
  matched formatting span, so a literal reserved character or nested
  markup INSIDE a bold/quote/etc. span also comes out escaped/parsed
  correctly. Reserved set and escaping rule are exactly
  core.telegram.org/bots/api's MarkdownV2 style, not guessed. }
function EscapeMarkdownV2(const AText: utf8string): utf8string;
const
  RESERVED = ['_','*','[',']','(',')','~','`','>','#','+','-','=','|',
              '{','}','.','!','\'];
var
  S, Res: string;
  L, I: integer;

  function AtLineStart(APos: integer): boolean;
  begin
    Result := (APos = 1) or (S[APos - 1] = #10);
  end;

  { Consumes a symmetric AMarker...AMarker span starting at S[I] (the
    caller has already confirmed the opening marker is present).
    ABreakOnNewline=False lets the span cross line breaks — needed only
    for the ``` code-block marker, since a literal '*'/'_'/etc. run
    accidentally spanning several unrelated lines is far more likely
    than an intentional bold/italic/etc. run that does. Appends the two
    literal markers plus the recursively-escaped content to Res and
    advances I past the closing marker; returns False (I untouched) if
    no closing marker turns up, so the caller falls back to treating
    the opening character as ordinary literal text. }
  function TryWrapper(const AMarker: string; ABreakOnNewline: boolean): boolean;
  var
    MarkLen, ClosePos, K: integer;
    Inner: string;
  begin
    Result := False;
    MarkLen := Length(AMarker);
    ClosePos := 0;
    K := I + MarkLen;
    while K <= L do begin
      if ABreakOnNewline and (S[K] = #10) then begin
        Break;
      end;
      if Copy(S, K, MarkLen) = AMarker then begin
        ClosePos := K;
        Break;
      end;
      Inc(K);
    end;
    if (ClosePos = 0) or (ClosePos = I + MarkLen) then begin
      Exit;   { no closing marker, or an empty span — leave as literal }
    end;
    Inner := Copy(S, I + MarkLen, ClosePos - (I + MarkLen));
    Res := Res + AMarker + string(EscapeMarkdownV2(utf8string(Inner))) + AMarker;
    I := ClosePos + MarkLen;
    Result := True;
  end;

  { [text](url) — the one construct that isn't a symmetric delimiter,
    so it needs its own matcher. Per the MarkdownV2 spec, only ')' and
    '\' inside the URL itself need escaping; the link text is escaped
    the same recursive way as any other span's content. }
  function TryLink: boolean;
  var
    CloseBracket, CloseParen, K: integer;
    LinkText, Url: string;
  begin
    Result := False;
    CloseBracket := 0;
    K := I + 1;
    while K <= L do begin
      if S[K] = #10 then begin
        Break;
      end;
      if S[K] = ']' then begin
        CloseBracket := K;
        Break;
      end;
      Inc(K);
    end;
    if (CloseBracket = 0) or (CloseBracket + 1 > L) or (S[CloseBracket + 1] <> '(') then begin
      Exit;
    end;
    CloseParen := 0;
    K := CloseBracket + 2;
    while K <= L do begin
      if S[K] = #10 then begin
        Break;
      end;
      if S[K] = ')' then begin
        CloseParen := K;
        Break;
      end;
      Inc(K);
    end;
    if CloseParen = 0 then begin
      Exit;
    end;
    LinkText := Copy(S, I + 1, CloseBracket - (I + 1));
    Url := Copy(S, CloseBracket + 2, CloseParen - (CloseBracket + 2));
    Url := StringReplace(Url, '\', '\\', [rfReplaceAll]);
    Url := StringReplace(Url, ')', '\)', [rfReplaceAll]);
    Res := Res + '[' + string(EscapeMarkdownV2(utf8string(LinkText))) + '](' + Url + ')';
    I := CloseParen + 1;
    Result := True;
  end;

begin
  S := string(AText);
  L := Length(S);
  I := 1;
  Res := '';
  while I <= L do begin
    { A '>' at the very start of a line is the blockquote marker, kept
      literal; the same character anywhere else must be escaped. }
    if (S[I] = '>') and AtLineStart(I) then begin
      Res := Res + '>';
      Inc(I);
      Continue;
    end;
    if (Copy(S, I, 3) = '```') and TryWrapper('```', False) then begin
      Continue;
    end;
    if (S[I] = '[') and TryLink then begin
      Continue;
    end;
    if (Copy(S, I, 2) = '__') and TryWrapper('__', True) then begin
      Continue;
    end;
    if (Copy(S, I, 2) = '||') and TryWrapper('||', True) then begin
      Continue;
    end;
    case S[I] of
      '*': if TryWrapper('*', True) then Continue;
      '_': if TryWrapper('_', True) then Continue;
      '~': if TryWrapper('~', True) then Continue;
      '`': if TryWrapper('`', True) then Continue;
    end;
    if S[I] in RESERVED then begin
      Res := Res + '\' + S[I];
    end else begin
      Res := Res + S[I];
    end;
    Inc(I);
  end;
  Result := utf8string(Res);
end;

{ Escapes literal '&'/'<'/'>' for HTML parse mode, recognizing — and
  passing through unescaped — exactly the tags the message input
  toolbar itself inserts (msginput.pas); anything else starting with
  '<' is just literal text and gets escaped like any other character.
  Mirrors EscapeMarkdownV2's role for the other parse mode: without
  this, a message containing a bare '<'/'>'/'&' that isn't one of our
  own tags makes TDLib reject the whole send with a parse error, same
  failure mode as the MarkdownV2 case. }
function EscapeHtml(const AText: utf8string): utf8string;
const
  TAGS: array[0..15] of string = (
    '<b>', '</b>', '<i>', '</i>', '<u>', '</u>', '<s>', '</s>',
    '<code>', '</code>', '<pre>', '</pre>',
    '<tg-spoiler>', '</tg-spoiler>', '<blockquote>', '</blockquote>'
  );
var
  S, Res, Url: string;
  L, I, K, TagLen: integer;
  Matched: boolean;
  CloseQuote: integer;
begin
  S := string(AText);
  L := Length(S);
  I := 1;
  Res := '';
  while I <= L do begin
    Matched := False;
    if S[I] = '<' then begin
      for K := Low(TAGS) to High(TAGS) do begin
        TagLen := Length(TAGS[K]);
        if Copy(S, I, TagLen) = TAGS[K] then begin
          Res := Res + TAGS[K];
          Inc(I, TagLen);
          Matched := True;
          Break;
        end;
      end;
      if (not Matched) and (Copy(S, I, 9) = '<a href="') then begin
        CloseQuote := 0;
        K := I + 9;
        while K <= L do begin
          if S[K] = '"' then begin
            CloseQuote := K;
            Break;
          end;
          Inc(K);
        end;
        if (CloseQuote > 0) and (CloseQuote + 1 <= L) and (S[CloseQuote + 1] = '>') then begin
          Url := Copy(S, I + 9, CloseQuote - (I + 9));
          Url := StringReplace(Url, '&', '&amp;', [rfReplaceAll]);
          Res := Res + '<a href="' + Url + '">';
          I := CloseQuote + 2;
          Matched := True;
        end;
      end;
      if (not Matched) and (Copy(S, I, 4) = '</a>') then begin
        Res := Res + '</a>';
        Inc(I, 4);
        Matched := True;
      end;
    end;
    if Matched then begin
      Continue;
    end;
    case S[I] of
      '&': Res := Res + '&amp;';
      '<': Res := Res + '&lt;';
      '>': Res := Res + '&gt;';
    else
      Res := Res + S[I];
    end;
    Inc(I);
  end;
  Result := utf8string(Res);
end;

procedure TTdMessages.SendFormattedText(const AMarkupText: utf8string; AIsHtml: boolean);
var
  ModeObj: TJSONObject;
  TextVal: TJSONString;
  Body: utf8string;
  EscapedText: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) or (Trim(string(AMarkupText)) = '') then begin
    Exit;
  end;

  { The message can freely contain reserved punctuation ('.', '!', '>',
    '<', '&', ...) that has nothing to do with the toolbar's own
    formatting syntax — both parse modes REQUIRE such characters to be
    escaped, or TDLib rejects the ENTIRE message with a parse error
    (see the two Escape* functions above for exactly which characters/
    constructs each mode treats as its own, everything else literal). }
  if AIsHtml then begin
    EscapedText := EscapeHtml(AMarkupText);
  end else begin
    EscapedText := EscapeMarkdownV2(AMarkupText);
  end;

  ModeObj := TJSONObject.Create;
  if AIsHtml then begin
    ModeObj.Strings['@type'] := 'textParseModeHTML';
  end else begin
    ModeObj.Strings['@type'] := 'textParseModeMarkdown';
    { Version 2 = Bot API MarkdownV2 syntax (*bold*, _italic_,
      __underline__, ~strike~, ||spoiler||, `code`, [text](url), a '>'
      prefix per line for blockquote) — the exact syntax the message
      input toolbar's buttons insert (msginput.pas), confirmed against
      core.telegram.org/bots/api and TDLib's own textParseModeMarkdown
      docs, not guessed. Version 0/1 is the older, INCOMPATIBLE legacy
      syntax (single _/* delimiters only, no underline/strikethrough/
      spoiler at all) — not what gets typed here. }
    ModeObj.Integers['version'] := 2;
  end;

  { A JSONString's own .AsJSON is the properly quoted-and-escaped JSON
    string literal on its own — the same "build via fpjson, not string
    concatenation" rule SendText already follows above, needed here too
    since marked-up text can contain quotes/backslashes/newlines. }
  TextVal := TJSONString.Create(string(EscapedText));
  try
    Body := '"text":' + utf8string(TextVal.AsJSON) +
            ',"parse_mode":' + utf8string(ModeObj.AsJSON);
  finally
    TextVal.Free;
    ModeObj.Free;
  end;

  FReq.SendRequest('parseTextEntities', Body, @ParseEntitiesDone);
end;

procedure TTdMessages.ParseEntitiesDone(Sender: TObject; const AResp: TTdResponse);
var
  Clean: TJSONObject;
  EntitiesArr: TJSONArray;
  Body: utf8string;
begin
  if not AResp.Success then begin
    if Assigned(FOnActionError) then begin
      FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'parse');
    end;
    Exit;
  end;
  if (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;

  { AResp.Obj is the raw response object, which — like every request in
    this project's plumbing (tdreq.pas) — carries the request's own
    "@extra" tag mixed in alongside the real result fields; that tag has
    no business riding along inside a message we're about to send, so a
    clean formattedText is rebuilt here with just @type/text/entities.
    The entities array is CLONED, not referenced — AResp.Obj is only
    valid inside this callback (see TTdResponse's own comment), and
    SendRequest below is asynchronous. }
  Clean := TJSONObject.Create;
  try
    Clean.Strings['@type'] := 'formattedText';
    Clean.Strings['text'] := string(JGetStr(AResp.Obj, 'text'));
    EntitiesArr := JGetArr(AResp.Obj, 'entities');
    if EntitiesArr <> nil then begin
      Clean.Add('entities', EntitiesArr.Clone as TJSONArray);
    end;
    Body := '"chat_id":' + utf8string(IntToStr(FChatId)) +
            ',"input_message_content":{"@type":"inputMessageText","text":' +
            utf8string(Clean.AsJSON) + '}';
  finally
    Clean.Free;
  end;

  { Same final step as SendText: the sendMessage response is the new
    message object itself, no separate temporary id needed. }
  FReq.SendRequest('sendMessage', Body, @SendTextDone);
end;

procedure TTdMessages.MarkRead(const AMessageIds: array of Int64);
var
  Ids: utf8string;
  I: integer;
begin
  if (FReq = nil) or (FChatId = 0) or (Length(AMessageIds) = 0) then begin
    Exit;
  end;
  Ids := '';
  for I := 0 to High(AMessageIds) do begin
    if Ids <> '' then begin
      Ids := Ids + ',';
    end;
    Ids := Ids + utf8string(IntToStr(AMessageIds[I]));
  end;
  FReq.SendRequest('viewMessages',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_ids":[' + Ids + ']' +
    ',"source":{"@type":"messageSourceChatHistory"},"force_read":true',
    @ActionDone);
end;

procedure TTdMessages.ActionDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    Exit;
  end;
  if Assigned(FOnActionError) then begin
    FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, '');
  end;
end;

procedure TTdMessages.JumpTo(AMessageId: Int64);
begin
  if (FReq = nil) or (FChatId = 0) or (AMessageId = 0) then begin
    Exit;
  end;
  if Lookup(AMessageId) <> nil then begin
    { Already loaded — e.g. a repeat click on the same quote, or the
      message fell within the window of an earlier ordinary history
      load. No RPC needed, ready is signaled right away. (Also the
      common case while a filter is on and the target happens to be a
      result itself — nothing below applies then.) }
    if Assigned(FOnJumpReady) then begin
      FOnJumpReady(Self, AMessageId);
    end;
    Exit;
  end;
  if SearchActive then begin
    { Following a quote to a message that is NOT one of the results
      means leaving the filtered view: the batch fetched below is
      ordinary history around the target, and dropping it into a result
      list would fill that list with messages matching nothing. So the
      filter is dropped first — which is also the sensible behavior,
      the same "jump to the message in its real context" the official
      client does from a search result.

      Clear, not SetSearchFilter('', ''): the latter would start its
      own LoadOlder for the newest page, racing the jump request about
      to go out and scrolling the user somewhere they didn't ask for.
      The header bar's buttons follow via
      TFrameHistory.UpdateSearchStatus, which watches for exactly this
      "the model dropped the filter by itself" edge. }
    Clear;
    if Assigned(FOnChanged) then begin
      FOnChanged(Self);
    end;
  end;
  { offset:-(N) means "N more messages NEWER than from_message_id"
    (official docs.core.telegram.org/tdlib, getChatHistory.offset), in
    addition to AMessageId itself and older ones, up to limit. This
    puts the message somewhere in the middle of the batch rather than
    right at the end — showing part of the conversation around it, not
    just what came before. }
  FReq.SendRequest('getChatHistory',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"from_message_id":' + utf8string(IntToStr(AMessageId)) +
    ',"offset":' + utf8string(IntToStr(-(FLoadLimit div 2))) +
    ',"limit":' + utf8string(IntToStr(FLoadLimit)) +
    ',"only_local":false', @JumpDone, PtrInt(AMessageId));
end;

procedure TTdMessages.JumpDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  TargetId: Int64;
begin
  TargetId := Int64(AResp.Tag);
  if not AResp.Success then begin
    if Assigned(FOnActionError) then begin
      FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'jump');
    end;
    Exit;
  end;

  Arr := JGetArr(AResp.Obj, 'messages');
  if Arr <> nil then begin
    { The same order as HistoryDone: getChatHistory returns newest to
      oldest, applied in reverse. }
    for I := Arr.Count - 1 downto 0 do begin
      if Arr.Items[I].JSONType = jtObject then begin
        try
          ApplyMessage(TJSONObject(Arr.Items[I]));
        except
          on E: Exception do begin
            if Assigned(FOnActionError) then begin
              FOnActionError(Self, 0, utf8string(E.Message), 'jump-parse');
            end;
          end;
        end;
      end;
    end;
  end;

  { ApplyMessage above only marks FDirty (Touch) — the actual FRows
    rebuild happens on a delay, via the 50ms timer. The caller (see
    framehistory.pas: TMsgScroller.ScrollToMessage) needs a ready,
    up-to-date FRows/FOffsets RIGHT AT the moment of OnJumpReady —
    hence a synchronous Rebuild here, instead of waiting for the timer
    as in the normal update flow. }
  Rebuild(nil);

  if Assigned(FOnJumpReady) then begin
    FOnJumpReady(Self, TargetId);
  end;
end;

function TTdMessages.IsReplyPending(AId: Int64): boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to High(FReplyPending) do begin
    if FReplyPending[I] = AId then begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure TTdMessages.MarkReplyPending(AId: Int64);
begin
  SetLength(FReplyPending, Length(FReplyPending) + 1);
  FReplyPending[High(FReplyPending)] := AId;
end;

procedure TTdMessages.ClearReplyPending(AId: Int64);
var
  I, J: integer;
begin
  for I := 0 to High(FReplyPending) do begin
    if FReplyPending[I] = AId then begin
      for J := I to High(FReplyPending) - 1 do begin
        FReplyPending[J] := FReplyPending[J + 1];
      end;
      SetLength(FReplyPending, Length(FReplyPending) - 1);
      Exit;
    end;
  end;
end;

{ The same "content type -> preview label" mapping as MessagePreview
  (tdchats.pas), but from a TMsgRow's already-parsed Kind/PlainText
  rather than raw JSON — avoids reparsing ContentRaw on every repaint
  of an already-loaded quote (the only path that needs this: the
  message is already in FAll, see ReplyPreview). For messages fetched
  via getRepliedMessage, MessagePreview itself is used directly on the
  response's raw JSON — see GetRepliedDone. }
function ReplyKindLabel(AKind: TMsgContentKind; const APlainText: utf8string): utf8string;
begin
  case AKind of
    mckText:      Result := APlainText;
    mckAudio:     Result := 'Audio';
    mckPhoto:     Result := 'Photo';
    mckAnimation: Result := 'GIF';
    mckSticker:   Result := 'Sticker';
    mckVoiceNote: Result := 'Voice message';
    mckFile:      Result := 'File';
  else
    Result := 'Message';
  end;
end;

function TTdMessages.ReplyPreview(AChatId, AMessageId: Int64;
  out ASenderUserId, ASenderChatId: Int64; out APreviewText: utf8string): boolean;
var
  R: TMsgRow;
  Idx: integer;
begin
  Result := False;
  ASenderUserId := 0;
  ASenderChatId := 0;
  APreviewText := '';
  if (AMessageId = 0) or (AChatId <> FChatId) then begin
    Exit;
  end;

  R := Lookup(AMessageId);
  if R <> nil then begin
    ASenderUserId := R.SenderUserId;
    ASenderChatId := R.SenderChatId;
    APreviewText := ReplyKindLabel(R.Kind, R.PlainText);
    Result := True;
    Exit;
  end;

  Idx := FReplyCache.IndexOf(AMessageId);
  if Idx >= 0 then begin
    ASenderUserId := FReplyCache.Data[Idx].SenderUserId;
    ASenderChatId := FReplyCache.Data[Idx].SenderChatId;
    APreviewText := FReplyCache.Data[Idx].PreviewText;
    Result := True;
    Exit;
  end;

  RequestReply(AMessageId);
end;

procedure TTdMessages.RequestReply(AMessageId: Int64);
begin
  if (FReq = nil) or (FChatId = 0) or IsReplyPending(AMessageId) then begin
    Exit;
  end;
  MarkReplyPending(AMessageId);
  FReq.SendRequest('getRepliedMessage',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_id":' + utf8string(IntToStr(AMessageId)),
    @GetRepliedDone, PtrInt(AMessageId));
end;

procedure TTdMessages.GetRepliedDone(Sender: TObject; const AResp: TTdResponse);
var
  Id: Int64;
  P: TMsgReplyPreview;
  SenderObj: TJSONObject;
  SenderType: utf8string;
  UnusedGlyphs: TPreviewGlyphArray;   { the reply quote box shows plain text, no custom-emoji rendering (yet) }
begin
  Id := Int64(AResp.Tag);
  ClearReplyPending(Id);
  if not AResp.Success then begin
    { Silently doesn't show a quote — the same approach as a getUser
      miss in tdusers.pas: the quoted message may have been deleted,
      not a reason to clutter the status bar for every such case in
      the history. }
    Exit;
  end;

  P := TMsgReplyPreview.Create;
  SenderObj := JGetObj(AResp.Obj, 'sender_id');
  SenderType := JGetStr(SenderObj, '@type');
  if SenderType = 'messageSenderUser' then begin
    P.SenderUserId := JGetInt64(SenderObj, 'user_id');
  end else if SenderType = 'messageSenderChat' then begin
    P.SenderChatId := JGetInt64(SenderObj, 'chat_id');
  end;
  P.PreviewText := MessagePreview(JGetObj(AResp.Obj, 'content'), UnusedGlyphs);

  if FReplyCache.IndexOf(Id) < 0 then begin
    FReplyCache.Add(Id, P);
  end else begin
    P.Free;   { shouldn't happen (see IsReplyPending), but avoid a leak just in case }
  end;
  Touch;
end;

{ Audio-file download — the same approach as TTdChats.EnsureAvatar/
  DownloadDone/ApplyFile (tdchats.pas) for avatars, adapted to TMsgRow
  instead of TChatRow: the file may already be on disk, in which case
  the path arrives directly in the downloadFile response and updateFile
  may never come at all — both cases lead to ApplyAudioFile. }
procedure TTdMessages.EnsureAudioFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.AudioFileId = 0) or (ARow.AudioLocalPath <> '') or ARow.AudioDownloadRequested then begin
    Exit;
  end;
  ARow.AudioDownloadRequested := True;
  if FByFile.IndexOf(ARow.AudioFileId) < 0 then begin
    FByFile.Add(ARow.AudioFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.AudioDownloadRequested := False;
    Exit;
  end;
  { priority 32 — the highest: unlike avatars (background, shouldn't
    delay history), this is an explicit user request to listen — it
    shouldn't be made to wait. }
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.AudioFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadAudioDone, ARow.AudioFileId);
end;

procedure TTdMessages.DownloadAudioDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyAudioFile(AResp.Obj);
    Exit;
  end;
  Idx := FByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FByFile.Data[Idx].AudioDownloadRequested := False;
  end;
end;

procedure TTdMessages.ApplyAudioFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;

  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  R := FByFile.Data[Idx];
  if R.AudioLocalPath = Path then begin
    Exit;
  end;
  R.AudioLocalPath := Path;
  Touch;
end;

{ Voice-note download — an exact copy of EnsureAudioFile/
  DownloadAudioDone/ApplyAudioFile above, kept separate precisely
  because audio's file_id and a voice note's file_id use separate maps
  (FByFile/FVoiceByFile), the same principle already used for
  documents/photos. }
procedure TTdMessages.EnsureVoiceFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.VoiceFileId = 0) or (ARow.VoiceLocalPath <> '') or ARow.VoiceDownloadRequested then begin
    Exit;
  end;
  ARow.VoiceDownloadRequested := True;
  if FVoiceByFile.IndexOf(ARow.VoiceFileId) < 0 then begin
    FVoiceByFile.Add(ARow.VoiceFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.VoiceDownloadRequested := False;
    Exit;
  end;
  { priority 32 — the same logic as audio: an explicit user request to
    listen, not a background download. }
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.VoiceFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadVoiceDone, ARow.VoiceFileId);
end;

procedure TTdMessages.DownloadVoiceDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyVoiceFile(AResp.Obj);
    Exit;
  end;
  Idx := FVoiceByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FVoiceByFile.Data[Idx].VoiceDownloadRequested := False;
  end;
end;

procedure TTdMessages.ApplyVoiceFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FVoiceByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;

  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  R := FVoiceByFile.Data[Idx];
  if R.VoiceLocalPath = Path then begin
    Exit;
  end;
  R.VoiceLocalPath := Path;
  Touch;
end;

procedure TTdMessages.EnsurePlayableFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  case ARow.Kind of
    mckAudio:     EnsureAudioFile(ARow);
    mckVoiceNote: EnsureVoiceFile(ARow);
  end;
end;

{ Document-file download — an exact copy of EnsureAudioFile/
  DownloadAudioDone/ApplyAudioFile above, kept separate precisely
  because audio's file_id and a document's file_id use separate maps
  (FByFile/FDocByFile), see the comment on TDocFileMap. }
procedure TTdMessages.EnsureDocFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.DocFileId = 0) or (ARow.DocLocalPath <> '') or ARow.DocDownloadRequested then begin
    Exit;
  end;
  ARow.DocDownloadRequested := True;
  if FDocByFile.IndexOf(ARow.DocFileId) < 0 then begin
    FDocByFile.Add(ARow.DocFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.DocDownloadRequested := False;
    Exit;
  end;
  { priority 32 — the highest, same as audio: an explicit user request
    "I want to save this file", not a background download. }
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.DocFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadDocDone, ARow.DocFileId);
end;

procedure TTdMessages.DownloadDocDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyDocFile(AResp.Obj);
    Exit;
  end;
  Idx := FDocByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FDocByFile.Data[Idx].DocDownloadRequested := False;
  end;
end;

procedure TTdMessages.ApplyDocFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FDocByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;

  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  R := FDocByFile.Data[Idx];
  if R.DocLocalPath = Path then begin
    Exit;
  end;
  R.DocLocalPath := Path;
  Touch;
end;

{ Photo download — an exact copy of EnsureDocFile/DownloadDocDone/
  ApplyDocFile above, kept separate for the same reason a document is
  kept separate from audio (see the comment on TPhotoFileMap). }
procedure TTdMessages.EnsurePhotoFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.PhotoFileId = 0) or (ARow.PhotoLocalPath <> '') or ARow.PhotoDownloadRequested then begin
    Exit;
  end;
  ARow.PhotoDownloadRequested := True;
  if FPhotoByFile.IndexOf(ARow.PhotoFileId) < 0 then begin
    FPhotoByFile.Add(ARow.PhotoFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.PhotoDownloadRequested := False;
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.PhotoFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadPhotoDone, ARow.PhotoFileId);
end;

procedure TTdMessages.DownloadPhotoDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyPhotoFile(AResp.Obj);
    Exit;
  end;
  Idx := FPhotoByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FPhotoByFile.Data[Idx].PhotoDownloadRequested := False;
  end;
end;

{ Bucket 0..DOWNLOAD_PROGRESS_W-1 (the progress bar's own pixel width,
  constants.pas) that ADownloaded/ATotal would currently fill — the
  natural throttle for how often a progress change is even worth a
  Touch (and everything downstream of it: the 50ms coalesce timer,
  RebuildOffsets over the WHOLE loaded history, a full TMsgScroller
  repaint — see ApplyPhotoFile/ApplyVideoFile below). Real downloads
  deliver updateFile roughly every 64KB (confirmed from tdlib_raw.log,
  not assumed) — for the auto-download prefetch window's ordinary case
  of several multi-megabyte files downloading AT ONCE
  (AUTODL_PREFETCH_MESSAGES, framehistory.pas), that adds up to
  hundreds of Touch calls a second without this throttle — no single
  byte-level delta moves a 100px bar by even one visible pixel anyway.
  -1 (never equal to a real bucket) when the total isn't known yet. }
function ProgressBarPixel(ADownloaded, ATotal: Int64): integer;
begin
  if ATotal <= 0 then begin
    Result := -1;
  end else begin
    Result := (ADownloaded * DOWNLOAD_PROGRESS_W) div ATotal;
  end;
end;

procedure TTdMessages.ApplyPhotoFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
  Downloaded, Total: Int64;
  OldPixel: integer;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FPhotoByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;
  R := FPhotoByFile.Data[Idx];

  Local := JGetObj(AFile, 'local');

  { Progress — read on EVERY update, not just the final one, unlike the
    completion check below. size is TDLib's confirmed final size (0 if
    it isn't known yet, which can briefly be true right after a
    download starts); expected_size is its own best estimate for that
    same window — falling back to it keeps the bar moving instead of
    sitting at "no total" for the first update or two. }
  Downloaded := JGetInt64(Local, 'downloaded_size');
  Total := JGetInt64(AFile, 'size');
  if Total = 0 then begin
    Total := JGetInt64(AFile, 'expected_size');
  end;
  OldPixel := ProgressBarPixel(R.PhotoDownloadedSize, R.PhotoTotalSize);
  R.PhotoDownloadedSize := Downloaded;
  R.PhotoTotalSize := Total;
  if ProgressBarPixel(Downloaded, Total) <> OldPixel then begin
    Touch;
  end;

  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  if R.PhotoLocalPath = Path then begin
    Exit;
  end;
  R.PhotoLocalPath := Path;
  Touch;
end;

{ The original (largest layer) — an exact copy of EnsurePhotoFile/
  DownloadPhotoDone/ApplyPhotoFile above, with its own separate map
  (FPhotoBestByFile), because the original's file_id — and so its
  TDLib cache path — is DIFFERENT from the preview copy's (see the
  comment on TMsgRow.PhotoBestFileId). }
procedure TTdMessages.EnsurePhotoBestFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.PhotoBestFileId = 0) or (ARow.PhotoBestLocalPath <> '') or ARow.PhotoBestDownloadRequested then begin
    Exit;
  end;
  ARow.PhotoBestDownloadRequested := True;
  if FPhotoBestByFile.IndexOf(ARow.PhotoBestFileId) < 0 then begin
    FPhotoBestByFile.Add(ARow.PhotoBestFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.PhotoBestDownloadRequested := False;
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.PhotoBestFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadPhotoBestDone, ARow.PhotoBestFileId);
end;

procedure TTdMessages.DownloadPhotoBestDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyPhotoBestFile(AResp.Obj);
    Exit;
  end;
  Idx := FPhotoBestByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FPhotoBestByFile.Data[Idx].PhotoBestDownloadRequested := False;
  end;
end;

procedure TTdMessages.ApplyPhotoBestFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FPhotoBestByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;

  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  R := FPhotoBestByFile.Data[Idx];
  if R.PhotoBestLocalPath = Path then begin
    Exit;
  end;
  R.PhotoBestLocalPath := Path;
  Touch;
end;

{ A "GIF" — one file, an exact copy of EnsureDocFile/DownloadDocDone/
  ApplyDocFile in shape (not EnsurePhotoFile, which has two layers —
  animation is simpler), with its own map FAnimByFile. priority 32 is
  the same "explicit user interest, not background" as the rest of the
  Ensure*File methods. }
procedure TTdMessages.EnsureAnimFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.AnimFileId = 0) or (ARow.AnimLocalPath <> '') or ARow.AnimDownloadRequested then begin
    Exit;
  end;
  ARow.AnimDownloadRequested := True;
  if FAnimByFile.IndexOf(ARow.AnimFileId) < 0 then begin
    FAnimByFile.Add(ARow.AnimFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.AnimDownloadRequested := False;
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.AnimFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadAnimDone, ARow.AnimFileId);
end;

procedure TTdMessages.DownloadAnimDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyAnimFile(AResp.Obj);
    Exit;
  end;
  Idx := FAnimByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FAnimByFile.Data[Idx].AnimDownloadRequested := False;
  end;
end;

procedure TTdMessages.ApplyAnimFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FAnimByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;

  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  R := FAnimByFile.Data[Idx];
  if R.AnimLocalPath = Path then begin
    Exit;
  end;
  R.AnimLocalPath := Path;
  Touch;
end;

{ A video message — the same one-file approach as a "GIF" above, its
  own map FVideoByFile. }
procedure TTdMessages.EnsureVideoFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.VideoFileId = 0) or (ARow.VideoLocalPath <> '') or ARow.VideoDownloadRequested then begin
    Exit;
  end;
  ARow.VideoDownloadRequested := True;
  if FVideoByFile.IndexOf(ARow.VideoFileId) < 0 then begin
    FVideoByFile.Add(ARow.VideoFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.VideoDownloadRequested := False;
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.VideoFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadVideoDone, ARow.VideoFileId);
end;

procedure TTdMessages.DownloadVideoDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyVideoFile(AResp.Obj);
    Exit;
  end;
  Idx := FVideoByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FVideoByFile.Data[Idx].VideoDownloadRequested := False;
  end;
end;

procedure TTdMessages.ApplyVideoFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
  Downloaded, Total: Int64;
  OldPixel: integer;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FVideoByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;
  R := FVideoByFile.Data[Idx];

  Local := JGetObj(AFile, 'local');

  { Progress — see the identical comment in ApplyPhotoFile, including
    the pixel-bucket throttle on Touch (ProgressBarPixel). }
  Downloaded := JGetInt64(Local, 'downloaded_size');
  Total := JGetInt64(AFile, 'size');
  if Total = 0 then begin
    Total := JGetInt64(AFile, 'expected_size');
  end;
  OldPixel := ProgressBarPixel(R.VideoDownloadedSize, R.VideoTotalSize);
  R.VideoDownloadedSize := Downloaded;
  R.VideoTotalSize := Total;
  if ProgressBarPixel(Downloaded, Total) <> OldPixel then begin
    Touch;
  end;

  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  if R.VideoLocalPath = Path then begin
    Exit;
  end;
  R.VideoLocalPath := Path;
  Touch;
end;

{ The video preview frame — WITHOUT the Auto download settings gate
  (see the comment on TMsgRow.VideoThumbFileId) — an exact copy of
  EnsureVideoFile/DownloadVideoDone/ApplyVideoFile in shape, its own
  map FVideoThumbByFile (its own file_id, not shared with the video
  itself). }
procedure TTdMessages.EnsureVideoThumbFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.VideoThumbFileId = 0) or (ARow.VideoThumbLocalPath <> '') or
     ARow.VideoThumbDownloadRequested then begin
    Exit;
  end;
  ARow.VideoThumbDownloadRequested := True;
  if FVideoThumbByFile.IndexOf(ARow.VideoThumbFileId) < 0 then begin
    FVideoThumbByFile.Add(ARow.VideoThumbFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.VideoThumbDownloadRequested := False;
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.VideoThumbFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadVideoThumbDone, ARow.VideoThumbFileId);
end;

procedure TTdMessages.DownloadVideoThumbDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyVideoThumbFile(AResp.Obj);
    Exit;
  end;
  Idx := FVideoThumbByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FVideoThumbByFile.Data[Idx].VideoThumbDownloadRequested := False;
  end;
end;

procedure TTdMessages.ApplyVideoThumbFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FVideoThumbByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;

  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  R := FVideoThumbByFile.Data[Idx];
  if R.VideoThumbLocalPath = Path then begin
    Exit;
  end;
  R.VideoThumbLocalPath := Path;
  Touch;
end;

{ Stickers — with full animation, including TGS, chosen from the start
  — are downloaded WITHOUT the Auto download settings gate at all (see
  TMsgScroller.MaybeAutoDownload, framehistory.pas) — sticker files are
  typically tiny (single-digit to tens of KB for TGS/webp, rarely more
  for webm), and the whole point of a sticker is an instant visual
  response, not a deliberate "I want to look at this" like video/file.
  EnsureStickerFile/DownloadStickerDone/ApplyStickerFile are an exact
  copy of EnsureVideoFile/DownloadVideoDone/ApplyVideoFile in shape,
  with their own map FStickerByFile. }
procedure TTdMessages.EnsureStickerFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.StickerFileId = 0) or (ARow.StickerLocalPath <> '') or ARow.StickerDownloadRequested then begin
    Exit;
  end;
  ARow.StickerDownloadRequested := True;
  if FStickerByFile.IndexOf(ARow.StickerFileId) < 0 then begin
    FStickerByFile.Add(ARow.StickerFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.StickerDownloadRequested := False;
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.StickerFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadStickerDone, ARow.StickerFileId);
end;

procedure TTdMessages.DownloadStickerDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyStickerFile(AResp.Obj);
    Exit;
  end;
  Idx := FStickerByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FStickerByFile.Data[Idx].StickerDownloadRequested := False;
  end;
end;

procedure TTdMessages.ApplyStickerFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FStickerByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;

  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  R := FStickerByFile.Data[Idx];
  if R.StickerLocalPath = Path then begin
    Exit;
  end;
  R.StickerLocalPath := Path;
  Touch;
end;

function TTdMessages.IsCustomEmojiPending(AId: Int64): boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to High(FCustomEmojiPending) do begin
    if FCustomEmojiPending[I] = AId then begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure TTdMessages.MarkCustomEmojiPending(AId: Int64);
begin
  SetLength(FCustomEmojiPending, Length(FCustomEmojiPending) + 1);
  FCustomEmojiPending[High(FCustomEmojiPending)] := AId;
end;

procedure TTdMessages.ClearCustomEmojiPending(AId: Int64);
var
  I, J: integer;
begin
  for I := 0 to High(FCustomEmojiPending) do begin
    if FCustomEmojiPending[I] = AId then begin
      for J := I to High(FCustomEmojiPending) - 1 do begin
        FCustomEmojiPending[J] := FCustomEmojiPending[J + 1];
      end;
      SetLength(FCustomEmojiPending, Length(FCustomEmojiPending) - 1);
      Exit;
    end;
  end;
end;

{ Batched metadata fetch for every distinct custom_emoji_id used by
  ARow.Entities OR ARow.Reactions (a reactionTypeCustomEmoji reaction
  draws through the exact same customemoji.pas cache as a mekCustomEmoji
  text entity — one combined batch, not two separate requests) not
  already known to customemoji.pas — mirrors RequestReply/GetRepliedDone
  in shape (one-off targeted request, own pending list), but as a batch
  of up to however many new ids this ONE row introduces (TDLib allows up
  to 200 per call; a single message realistically never has anywhere
  near that many). }
procedure TTdMessages.EnsureCustomEmojiForRow(ARow: TMsgRow);
var
  I, N: integer;
  Ids: array of Int64;
  Id: Int64;
  Body: utf8string;
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  SetLength(Ids, Length(ARow.Entities) + Length(ARow.Reactions));
  N := 0;
  for I := 0 to High(ARow.Entities) do begin
    if ARow.Entities[I].Kind <> mekCustomEmoji then begin
      Continue;
    end;
    Id := ARow.Entities[I].CustomEmojiId;
    if (Id = 0) or CustomEmojiKnown(Id) or IsCustomEmojiPending(Id) then begin
      Continue;
    end;
    Ids[N] := Id;
    Inc(N);
    MarkCustomEmojiPending(Id);
  end;
  for I := 0 to High(ARow.Reactions) do begin
    if ARow.Reactions[I].Kind <> rcCustomEmoji then begin
      Continue;
    end;
    Id := ARow.Reactions[I].CustomEmojiId;
    if (Id = 0) or CustomEmojiKnown(Id) or IsCustomEmojiPending(Id) then begin
      Continue;
    end;
    Ids[N] := Id;
    Inc(N);
    MarkCustomEmojiPending(Id);
  end;
  if N = 0 then begin
    Exit;
  end;

  Body := '"custom_emoji_ids":[';
  for I := 0 to N - 1 do begin
    if I > 0 then begin
      Body := Body + ',';
    end;
    Body := Body + '"' + utf8string(IntToStr(Ids[I])) + '"';
  end;
  Body := Body + ']';
  FReq.SendRequest('getCustomEmojiStickers', Body, @GetCustomEmojiStickersDone);
end;

{ Ids in the request that TDLib doesn't return ("only found stickers
  are returned") stay marked pending for the rest of this session — the
  same accepted no-retry tradeoff already used for a getRepliedMessage
  miss (GetRepliedDone) or a failed file download elsewhere in this
  file: rare in practice, and not worth a per-batch id/Tag correlation
  mechanism to distinguish "not found" from "not requested yet". }
procedure TTdMessages.GetCustomEmojiStickersDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  StObj, FormatObj, FullTypeObj, FileObj, LocalObj: TJSONObject;
  Id: Int64;
  Format: TCustomEmojiFormat;
  FmtType: utf8string;
  FileId: integer;
  LocalPath: utf8string;
begin
  if not AResp.Success then begin
    Exit;
  end;
  Arr := JGetArr(AResp.Obj, 'stickers');
  if Arr = nil then begin
    Exit;
  end;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    StObj := TJSONObject(Arr.Items[I]);
    FullTypeObj := JGetObj(StObj, 'full_type');
    if JGetStr(FullTypeObj, '@type') <> 'stickerFullTypeCustomEmoji' then begin
      Continue;
    end;
    Id := JGetInt64(FullTypeObj, 'custom_emoji_id');
    if Id = 0 then begin
      Continue;
    end;
    ClearCustomEmojiPending(Id);

    FormatObj := JGetObj(StObj, 'format');
    FmtType := JGetStr(FormatObj, '@type');
    if FmtType = 'stickerFormatTgs' then begin
      Format := cmfTgs;
    end else if FmtType = 'stickerFormatWebm' then begin
      Format := cmfWebm;
    end else begin
      Format := cmfWebp;
    end;

    FileObj := JGetObj(StObj, 'sticker');
    FileId := JGetInt(FileObj, 'id');
    LocalPath := '';
    LocalObj := JGetObj(FileObj, 'local');
    if JGetBool(LocalObj, 'is_downloading_completed') then begin
      LocalPath := JGetStr(LocalObj, 'path');
    end;
    CustomEmojiSetSticker(Id, FileId, Format, LocalPath);

    if LocalPath = '' then begin
      if CustomEmojiNeedsDownload(Id) then begin
        CustomEmojiMarkDownloadRequested(Id);
        FReq.SendRequest('downloadFile',
          '"file_id":' + utf8string(IntToStr(FileId)) +
          ',"priority":32,"offset":0,"limit":0,"synchronous":false',
          @DownloadCustomEmojiDone, PtrInt(FileId));
      end;
    end else begin
      Touch;
    end;
  end;
end;

procedure TTdMessages.DownloadCustomEmojiDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    ApplyCustomEmojiFile(AResp.Obj);
  end;
end;

procedure TTdMessages.ApplyCustomEmojiFile(AFile: TJSONObject);
var
  FileId: integer;
  Id: Int64;
  Local: TJSONObject;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Id := CustomEmojiIdForFile(FileId);
  if Id = 0 then begin
    Exit;
  end;
  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;
  CustomEmojiSetLocalPath(Id, Path);
  Touch;
end;

procedure TTdMessages.TdUpdate(const AJson: utf8string; AData: TJSONObject);
var
  Obj: TJSONObject;
  T: utf8string;
  Id, OldId: Int64;
  R: TMsgRow;
  Arr: TJSONArray;
  I, Idx: integer;
begin
  { AData is already parsed by the receive thread (tdrecv.pas) — this
    used to have its own cheap Pos-based check before its own GetJSON;
    parsing now happens once for all subscribers, so that check is no
    longer needed. }
  if AData = nil then begin
    Exit;
  end;
  Obj := AData;
  T := JGetStr(Obj, '@type');

  { Message updates arrive in a stream, dozens per second in an active
    chat — one unexpected JSON shape (a content type not seen before,
    etc.) must not crash or hang the whole application:
    TTdAccount.HandleUpdate calls each subscriber's TdUpdate without a
    try/except of its own, so an exception from here would escape
    unhandled. }
  try
    if T = 'updateNewMessage' then begin
      { Not while a filter/search is showing: a message arriving in the
        chat has no reason to match the active filter or query, and
        dropping it into FAll would silently pollute the result list
        with something the user never asked to see (and, being the
        newest id, right at the bottom where it looks like a match).
        It is not lost either — leaving the filter reloads the ordinary
        history from TDLib. Updates to messages ALREADY in the list
        (edits, reactions, delivery state, files) stay live below;
        those are about rows that really are part of the result. }
      if not SearchActive then begin
        ApplyMessage(JGetObj(Obj, 'message'));
      end;
    end else if T = 'updateMessageContent' then begin
      ApplyContentUpdate(JGetInt64(Obj, 'chat_id'), JGetInt64(Obj, 'message_id'),
        JGetObj(Obj, 'new_content'));
    end else if T = 'updateFile' then begin
      ApplyAudioFile(JGetObj(Obj, 'file'));
      ApplyVoiceFile(JGetObj(Obj, 'file'));
      ApplyDocFile(JGetObj(Obj, 'file'));
      ApplyPhotoFile(JGetObj(Obj, 'file'));
      ApplyPhotoBestFile(JGetObj(Obj, 'file'));
      ApplyAnimFile(JGetObj(Obj, 'file'));
      ApplyVideoFile(JGetObj(Obj, 'file'));
      ApplyVideoThumbFile(JGetObj(Obj, 'file'));
      ApplyStickerFile(JGetObj(Obj, 'file'));
      ApplyCustomEmojiFile(JGetObj(Obj, 'file'));
    end else if T = 'updateMessageEdited' then begin
      if JGetInt64(Obj, 'chat_id') = FChatId then begin
        R := Lookup(JGetInt64(Obj, 'message_id'));
        if R <> nil then begin
          R.EditDate := JGetInt64(Obj, 'edit_date');
          Touch;
        end;
      end;
    end else if T = 'updateMessageInteractionInfo' then begin
      { Reactions (view/forward counts too, not tracked) changing on an
        already-loaded message — a new/removed reaction from anyone,
        not just this account. Confirmed from tdlib_raw.log. }
      if JGetInt64(Obj, 'chat_id') = FChatId then begin
        R := Lookup(JGetInt64(Obj, 'message_id'));
        if R <> nil then begin
          ExtractReactions(JGetObj(Obj, 'interaction_info'), R.Reactions);
          Touch;
        end;
      end;
    end else if T = 'updateMessageSendSucceeded' then begin
      { The temporary entry is replaced with the new one wholesale —
        simpler and more reliable than trying to reuse the same object
        under a different id. }
      OldId := JGetInt64(Obj, 'old_message_id');
      if OldId <> 0 then begin
        Idx := FAll.IndexOf(OldId);
        if Idx >= 0 then begin
          FAll.Data[Idx].Free;
          FAll.Delete(Idx);
        end;
      end;
      { Same reasoning as updateNewMessage above — a message just sent
        from the input box is not a search result. (Its temporary entry
        was never added either, for the same reason, so the removal
        above simply finds nothing.) }
      if not SearchActive then begin
        ApplyMessage(JGetObj(Obj, 'message'));
      end;
    end else if T = 'updateMessageSendFailed' then begin
      R := Lookup(JGetInt64(Obj, 'old_message_id'));
      if R <> nil then begin
        R.Delivery := mdsFailed;
        Touch;
      end;
    end else if T = 'updateDeleteMessages' then begin
      { from_cache:true means TDLib evicted the message from ITS OWN
        cache (usually because openChat wasn't sent for the chat
        recently/promptly enough), not that it was actually deleted.
        FAll is our own, already-loaded copy; discarding it because of
        someone else's cache eviction has no justification — and that's
        exactly what used to happen, which could shrink a chat left
        open for hours down to a single message. openChat/closeChat are
        now called from OpenChat, so this shouldn't happen at all for
        the ACTIVE chat anymore — but the check stays: cheap, and a
        safeguard for the future. }
      if (JGetInt64(Obj, 'chat_id') = FChatId) and (not JGetBool(Obj, 'from_cache')) then begin
        Arr := JGetArr(Obj, 'message_ids');
        if Arr <> nil then begin
          for I := 0 to Arr.Count - 1 do begin
            Id := 0;
            if Arr.Items[I].JSONType = jtNumber then begin
              Id := Arr.Items[I].AsInt64;
            end else if Arr.Items[I].JSONType = jtString then begin
              TryStrToInt64(Arr.Items[I].AsString, Id);
            end;
            if Id = 0 then begin
              Continue;
            end;
            Idx := FAll.IndexOf(Id);
            if Idx >= 0 then begin
              FAll.Data[Idx].Free;
              FAll.Delete(Idx);
            end;
          end;
          Touch;
        end;
      end;
    end;
  except
    on E: Exception do begin
      if Assigned(FOnActionError) then begin
        FOnActionError(Self, 0, utf8string(E.Message), 'update-parse');
      end;
    end;
  end;
end;

procedure TTdMessages.TdStateChanged(AState: TTdAuthState);
begin
  { On logout/client shutdown, the open chat's history stops mattering
    — the chat itself is likely about to change too. Unlike TTdChats,
    no auto-load happens on tasReady: until OpenChat is called
    explicitly (the user hasn't opened a chat), there's nothing to
    load. }
  if TdIsShuttingState(AState) then begin
    Clear;
    FChatId := 0;
  end;
end;

procedure TTdMessages.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Authorization errors don't concern this model. }
end;

end.
