unit tdmessages;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, base64, fgl, ExtCtrls, fpjson, jsonparser,
  constants, tdauth, tdsession, tdreq, tdchats;

type
  TMsgContentKind = (mckText, mckAudio, mckPhoto, mckAnimation, mckSticker,
    mckVoiceNote, mckFile, mckVideo, mckPoll, mckOther);

  { One media download waiting for a free slot — see
    TTdMessages.RequestFileDownload. }
  TQueuedDownload = record
    FileId: integer;
    Callback: TTdResponseEvent;
  end;

  { One media download in flight. NextOffset/Stalls are only used while
    a speed limit is set: the download is then handed out one byte
    window at a time (see TTdMessages.GrantChunk). Unthrottled, the
    request is a single open-ended downloadFile and these stay 0. }
  TActiveDownload = record
    FileId: integer;
    Callback: TTdResponseEvent;
    NextOffset: Int64;
    Stalls: integer;
    { Running as one open-ended request rather than paced windows.
      GaveUp tells the two reasons apart: no limit is set (and the
      moment one is, this download should start being paced), or pacing
      was tried on this file and got nowhere (and must not be retried). }
    Unthrottled: boolean;
    GaveUp: boolean;
  end;

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
    mekBlockQuote, mekMention, mekMentionName);

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
    { mekMentionName only: textEntityTypeMentionName.user_id — упоминание
      человека без username (текст — его имя). }
    UserId: Int64;
    { mekPre only, and only from textEntityTypePreCode - TDLib names
      the language itself, even for a fence that carried no tag. Empty
      for a plain code block. Shown in the block's header, the way the
      official client shows it. }
    Language:  utf8string;
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

  { One pollOption. Both the question and every option's text are a
    formattedText in TDLib, not a plain string — checked against
    tdlib_raw.log, not assumed; only the .text is kept here, entities
    inside poll text are not rendered (see TPollWidget). }
  TPollOption = record
    Text:          utf8string;
    VoterCount:    integer;
    { TDLib computes this itself (0..100) — no need to divide by
      TotalVoters here, and no rounding of our own to disagree with
      what the official clients show. }
    VotePercentage: integer;
    IsChosen:      boolean;
    IsBeingChosen: boolean;   { a vote of ours is in flight }
  end;
  TPollOptionArray = array of TPollOption;

  { content.poll of a messagePoll. One record rather than a dozen loose
    TMsgRow fields: unlike the media kinds, none of these are shared
    with anything else, and ExtractPollMeta fills them as a unit. }
  TMsgPoll = record
    Id:             Int64;
    Question:       utf8string;
    Options:        TPollOptionArray;
    TotalVoters:    integer;
    IsClosed:       boolean;
    IsAnonymous:    boolean;
    AllowsMultiple: boolean;
    AllowsRevoting: boolean;
    { type is pollTypeRegular or pollTypeQuiz; a quiz carries
      correct_option_idS — an ARRAY, despite there being at most one
      (the plural is the actual spelling in the payload, confirmed on a
      real quiz in tdlib_raw.log). -1 when there is no quiz answer to
      show: either not a quiz, or not answered yet (TDLib withholds it
      until then). }
    IsQuiz:         boolean;
    CorrectOption:  integer;
  end;

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
    { message.is_pinned. Only the context menu reads it, to decide
      whether the entry says Pin or Unpin - messageProperties answers
      whether pinning is ALLOWED, never whether it has happened. }
    IsPinned:        boolean;
    { media_album_id: messages sent together as one album share it, and
      it is 0 for everything else. Telegram gives no other way to tell
      an album apart - the messages are ordinary separate messages that
      merely arrived together, so the id is the only thing tying them. }
    AlbumId:         Int64;
    Kind:            TMsgContentKind;
    ContentRaw:      utf8string;
    { message.reply_markup как есть (JSON) — кнопки бота: инлайн под
      сообщением или клавиатура над полем ввода. Разбирает мост
      (webapi.pas, KeyboardRowsJson); '' — кнопок нет. }
    ReplyMarkupRaw:  utf8string;
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
    { The album cover shown at the left of TAudioWidget. Two possible
      sources, both plain "thumbnail" objects (format/width/height/
      file), confirmed from tdlib_raw.log: content.audio.
      album_cover_thumbnail — the art actually embedded in the file —
      and content.audio.external_album_covers — what Telegram found by
      title/performer when the file carries none. ExtractAudioMeta
      prefers the former and picks the smallest of the latter that
      still covers AUDIO_COVER_SIZE.
      Downloaded WITHOUT the Auto download gate, the same reasoning as
      the video preview frame and stickers: tens of KB, and it is the
      placeholder the widget is showing in the meantime.
      AudioCoverFileId=0 means the track has no cover at all (then the
      widget keeps the headphones placeholder). }
    AudioCoverFileId:            integer;
    AudioCoverLocalPath:         utf8string;
    AudioCoverDownloadRequested: boolean;
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
    { messageText.link_preview — the card Telegram builds on its own
      servers for a link in the text. Nothing is fetched by us: the
      whole thing (site, title, description, and a photo ready to
      download) arrives inside the message.

      LinkPhoto* is ONE picture, whatever the preview happens to carry:
      the article's image, the photo itself, or the video player's
      thumbnail - they are all `photo` objects in the same shape (see
      ExtractLinkPreview for which of the forty LinkPreviewType
      variants actually reach us). LinkLarge is show_large_media, the
      server's own opinion on whether this one deserves the big
      picture or the small square beside the text. }
    LinkUrl:       utf8string;
    LinkDisplay:   utf8string;
    LinkSite:      utf8string;
    LinkTitle:     utf8string;
    LinkDesc:      utf8string;
    LinkLarge:     boolean;
    LinkPhotoW, LinkPhotoH:  integer;
    LinkMinithumb:           RawByteString;
    LinkPhotoFileId:         integer;
    LinkPhotoPath:           utf8string;
    LinkPhotoRequested:      boolean;
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
    { The natural size of THAT largest layer, not of the preview one.
      PhotoWidth/Height above describe the medium layer that the chat
      row shows; the viewer opens PhotoBestLocalPath, so fitting it to
      the window needs the original's own dimensions — using the
      preview's would cap the picture at preview size. }
    PhotoBestWidth, PhotoBestHeight: integer;
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
    { Ход передачи ОСНОВНОГО файла сообщения — любого вида, вверх или
      вниз (см. ApplyXferFile). Для кольца вокруг значка на странице. }
    XferDone:   Int64;
    XferTotal:  Int64;
    XferUp:     boolean;
    XferActive: boolean;
    { Файл, который передаётся, — его и отменяет CancelTransfer. }
    XferFileId: integer;
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
    { message.interaction_info.reply_info — the comments under a
      channel post.

      TDLib fills it "only in channels with a discussion supergroup",
      which is exactly the condition "this post has comments": no
      discussion group, no reply_info, no button. CommentUnread is
      last_message_id > last_read_inbox_message_id, the same test the
      official clients use to mark the button. }
    { HasComments is the real question - "this post takes comments" -
      and it is NOT CommentCount > 0. A post nobody has commented on
      yet still has reply_info, still shows the button, and that button
      is the only way to leave the first comment. }
    HasComments:   boolean;
    CommentCount:  integer;
    CommentUnread: boolean;
    { message.interaction_info.reactions.reactions — empty if the
      message has no reactions (the common case). Set unconditionally
      in ApplyMessage (independent of Kind/content — any message type
      can carry reactions) and refreshed live via
      updateMessageInteractionInfo, see TdUpdate. Display only, for
      now: no UI to add/remove a reaction of your own yet. }
    Reactions: TMsgReactionArray;
    { interaction_info.reactions.can_get_added_reactions (td_api.tl):
      можно ли спросить, кто поставил реакции. Без него страница список
      не предлагает вовсе — и не спрашивает зря. }
    CanSeeReactors: boolean;
    { content.poll — meaningful for Kind=mckPoll only. Refreshed the
      ordinary way, through ApplyContentUpdate: every vote changes the
      content object itself, so unlike Reactions this needs no update
      of its own. }
    Poll: TMsgPoll;
    { msglayout's layout cache. Kept as an opaque TObject rather than
      TMsgLayout — otherwise tdmessages would need to know about
      msglayout, creating a unit cycle. Freed in the destructor via a
      plain Free; the virtual destructor takes care of the rest. }
    LayoutCache:     TObject;
    destructor Destroy; override;
  end;

  TMsgMap = specialize TFPGMap<Int64, TMsgRow>;
  TInt64List = specialize TFPGList<Int64>;

  { What a send needs to remember across parseTextEntities.

    The parse is a round trip of its own, and everything decided BEFORE
    it - which message this answers, whether it is silent, whether it
    is an edit rather than a new message - has to survive to the other
    side. It rides on the request's own Tag, which is an index into
    FSends: FPC 3.2 has no closures, and a field on Self would work
    until two sends overlapped and then the second one's settings would
    decide the first one's message. Silence alone used to travel as the
    Tag directly; three things no longer fit in it. }
  TPendingSend = record
    Busy: boolean;
    Silent: boolean;
    ReplyTo: Int64;   { 0 - not a reply }
    EditId: Int64;    { 0 - a new message rather than an edit }
  end;

  { Отправка файлов, ждущая разбора подписи (parseTextEntities) — то же,
    что TPendingSend, плюс сами файлы и как их слать. }
  TPendingFiles = record
    Busy: boolean;
    Paths: array of utf8string;
    { 'media' — фото и видео (по расширению), 'audio', иначе документом. }
    Mode: utf8string;
    { На каждый путь — готовый кусок полей inputVideo (duration, width,
      height, thumbnail) или ''; см. SendFiles. }
    Extras: array of utf8string;
    Silent: boolean;
    ReplyTo: Int64;
  end;

  { Один запрос sendMessage/sendMessageAlbum и пути его файлов по
    порядку: ответ TDLib приходит сообщениями в том же порядке, и только
    так видно, какой временный файл какому сообщению принадлежит. }
  TFileBatch = record
    Busy: boolean;
    Paths: array of utf8string;
  end;

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
  { Album-cover file_id -> message — a separate file_id from the audio
    itself (TAudioFileMap above), its own map for the same reason as
    TVideoThumbFileMap. }
  TAudioCoverFileMap = specialize TFPGMap<integer, TMsgRow>;
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

  { Прыжок к сообщению в полёте: в каком чате, к какому id и сколько раз
    уже повторён (JumpDone, JUMP_RETRY_MAX). }
  TJumpState = record
    ChatId: Int64;
    Target: Int64;
    Retries: integer;
  end;

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
    { id временных сообщений, уже заменённых настоящими
      (updateMessageSendSucceeded). Ответ на sendMessage несёт ТО ЖЕ
      временное сообщение и мог прийти в модель позже замены — оно
      возвращалось в историю с часиками и висело до смены чата (живой
      случай, tdlib_raw.log 2026-10-06 10:13). ApplyMessage их не
      впускает. }
    FReplaced: TInt64List;
    FRows:    TFPList;    { the same set, in chronological order }
    FTimer:   TTimer;
    FDirty:   boolean;
    FChatId:  Int64;
    FLoadingOlder: boolean;
    FOldestLoaded: boolean;
    { The unread marker for the CURRENTLY open chat: the id of the last
      message that was already read at the moment the chat was opened.
      The divider goes before the first message newer than it.

      Frozen on open ON PURPOSE. Scrolling marks messages read within
      the same second (TMsgScroller.MarkVisibleAsRead), so a marker
      that followed the live last_read_inbox_message_id would slide
      down and vanish while the user is still reading — the official
      clients keep it where it was until the chat is left, and so does
      this. 0 means "no divider" (the chat had nothing unread). }
    { COMMENT THREAD MODE. Non-zero FThreadPostId means the history
      being shown is the comments under one channel post rather than a
      chat's own messages.

      Three ids, and they are three different things:
        FChatId          - the DISCUSSION supergroup. The comments live
                           there, so this is what sending, reading and
                           every id lookup work against, exactly as in
                           an ordinary chat.
        FThreadChatId /  - the CHANNEL and the POST. getMessageThreadHistory
        FThreadPostId      is asked in terms of the original message,
                           not of the discussion group (checked against
                           td_api.tl, which says so outright).
        FThreadId        - message_thread_id, which is what a reply has
                           to name to land in this thread rather than
                           loose in the group.

      FThreadBack is the chat to return to when the thread is closed. }
    FThreadChatId: Int64;
    FThreadPostId: Int64;
    FThreadId: Int64;
    FThreadBack: Int64;
    { What OpenThread asked about, held until the answer comes back. }
    FPendingThreadChat: Int64;
    FPendingThreadMsg: Int64;
    FUnreadFromId: Int64;
    { Extra history pages still allowed while looking for the boundary,
      and whether that search has finished one way or the other (found
      it, ran out of history, or ran out of pages). }
    FUnreadBackfill: integer;
    FUnreadReady: boolean;
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
      next_from_message_id cursor, NOT the "oldest loaded id" anchor
      getChatHistory walks back with (search results aren't a
      contiguous id range, so that has no meaning here); 0 on the
      first request means "start at the newest
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
    { Extra OnChanged subscribers, alongside the single-slot FOnChanged
      above. The plain event is assigned — whoever assigns last wins —
      so a second view (the web UI, webapi.pas) could not listen without
      silently stealing the notification from the first. Additive on
      purpose: the existing frame keeps using OnChanged exactly as it
      did, and nothing about it changes. }
    FChangeListeners: array of TTdMessagesEvent;
    FOnLoadingChanged: TTdMessagesEvent;
    FOnActionError: TTdMessagesErrorEvent;
    FOnJumpReady: TTdMessagesJumpEvent;
    FJump: TJumpState;

    { Previews of quoted (reply_to) messages not yet in FAll — see
      ReplyPreview/RequestReply/GetRepliedDone. Deliberately kept
      separate from FAll: getRepliedMessage is a one-off, targeted
      "what is that message" request, not part of sequential
      pagination, and dumping its result into FAll would break the
      assumption that FAll is a CONTIGUOUS, gap-free range of history,
      which LoadOlder/its anchor depends on (see the comments there). }
    FReplyCache: TReplyMap;
    FReplyPending: array of Int64;
    { Slots for sends waiting on their parseTextEntities - see
      TPendingSend. Reused rather than appended to for ever; there are
      never more than a couple in flight. }
    FSends: array of TPendingSend;
    { То же для файлов — см. TPendingFiles и TFileBatch. }
    FFileSends: array of TPendingFiles;
    FFileBatches: array of TFileBatch;

    { Audio-file downloads — see EnsureAudioFile/ApplyAudioFile. }
    FByFile: TAudioFileMap;
    { Album-cover downloads — see
      EnsureAudioCoverFile/ApplyAudioCoverFile. }
    FAudioCoverByFile: TAudioCoverFileMap;
    { Voice-note downloads — see EnsureVoiceFile/ApplyVoiceFile. }
    FVoiceByFile: TVoiceFileMap;
    { Document-file downloads — see EnsureDocFile/ApplyDocFile. }
    FDocByFile: TDocFileMap;
    { Photo downloads — see EnsurePhotoFile/ApplyPhotoFile. }
    FPhotoByFile: TPhotoFileMap;
    { The same map, for the picture inside a link preview. Its own,
      because one row can carry both: a photo message whose caption
      holds a link would otherwise have the two fight over the slot. }
    FLinkByFile: TPhotoFileMap;
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
    { Media downloads in flight and waiting — see RequestFileDownload.
      Only file ids and callbacks are kept, never row references: rows
      are freed wholesale on Clear, and a queue entry can easily
      outlive the row it was queued for. }
    FActiveDownloads: array of TActiveDownload;
    FQueuedDownloads: array of TQueuedDownload;
    { Hands the byte windows out, one per tick, round-robin over the
      active throttled downloads — see GrantChunk. Runs only while a
      speed limit is set AND something is downloading. }
    FChunkTimer: TTimer;
    FChunkCursor: integer;
    { Token bucket for the speed cap, in bytes, shared by every paced
      download of this instance. Refilled at the configured rate on
      each tick and charged with what the downloads actually fetched,
      so it goes NEGATIVE whenever TDLib overshoots the window it was
      given — which is the normal case, since TDLib rounds any window
      up to a whole part. Waiting for it to climb back above zero is
      what actually enforces the rate. }
    FByteBudget: Int64;

    procedure NotifyChanged;
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
    procedure ExtractPollMeta(AContent: TJSONObject; const AType: utf8string;
      out APoll: TMsgPoll);
    procedure ExtractAudioMeta(AContent: TJSONObject; const AType: utf8string;
      out ADuration: integer; out ATitle, APerformer, AFileName: utf8string;
      out ACoverFileId: integer; out ACoverLocalPath: utf8string;
      out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadAudioCoverDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyAudioCoverFile(AFile: TJSONObject);
    procedure DownloadAudioDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyAudioFile(AFile: TJSONObject);
    procedure ExtractVoiceMeta(AContent: TJSONObject; const AType: utf8string;
      out ADuration: integer; out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadVoiceDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyVoiceFile(AFile: TJSONObject);
    function ActiveDownloadIndex(AFileId: integer): integer;
    function QueuedDownloadIndex(AFileId: integer): integer;
    { The single funnel every media downloadFile goes through. Sends
      straight away while fewer than DownloadConcurrency files are in
      flight, queues otherwise; a repeat request for a file already in
      flight or already queued is dropped. }
    procedure RequestFileDownload(AFileId: integer; ACallback: TTdResponseEvent);
    procedure SendFileDownload(AFileId: integer; ACallback: TTdResponseEvent);
    { Frees the slot AFileId was holding (a no-op for a file that never
      went through here) and starts whatever was waiting behind it. }
    procedure ReleaseDownloadSlot(AFileId: integer);
    procedure PumpDownloadQueue;
    { Issues the next byte window for one throttled download and moves
      the round-robin cursor on. }
    procedure ChunkTick(Sender: TObject);
    procedure GrantChunk(AIndex: integer);
    procedure UpdateChunkTimer;
    { Bytes the budget gains per tick — the configured rate spread over
      one timer interval. }
    function RefillBytes: Int64;
    { How big a window to ask for right now: whatever the budget has
      saved up, but never less than one TDLib part (a smaller request
      would be rounded up anyway, so asking for less only misleads). }
    function WindowBytes: Int64;
    { Reads a TDLib file object and releases its slot if TDLib is done
      with it — finished, or not downloading any more. }
    procedure NoteFileDownloadState(AFile: TJSONObject);
    procedure ExtractDocMeta(AContent: TJSONObject; const AType: utf8string;
      out AFileName: utf8string; out AFileSize: Int64;
      out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadDocDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyDocFile(AFile: TJSONObject);
    procedure ExtractReplyInfo(AInteractionInfo: TJSONObject; ARow: TMsgRow);
    procedure ExtractLinkPreview(AContent: TJSONObject; const AType: utf8string;
      ARow: TMsgRow);
    procedure DownloadLinkDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyLinkFile(AFile: TJSONObject);
    procedure ExtractPhotoMeta(AContent: TJSONObject; const AType: utf8string;
      out AWidth, AHeight: integer; out AMinithumb: RawByteString;
      out AFileId: integer; out ALocalPath: utf8string;
      out ABestFileId: integer; out ABestLocalPath: utf8string;
      out ABestWidth, ABestHeight: integer);
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
    { A path this model is holding can stop being true. }
    procedure ForgetFile(var APath: utf8string; var ARequested: boolean);
    procedure ForgetRowFiles(ARow: TMsgRow);
    procedure Rebuild(Sender: TObject);
    procedure SetLoadingOlder(AValue: boolean);
    function GetSearchActive: boolean;
    procedure SearchDone(Sender: TObject; const AResp: TTdResponse);
    procedure HistoryDone(Sender: TObject; const AResp: TTdResponse);
    procedure PurgeFileMap(AMap: TAudioFileMap; AGone: TFPList);
    procedure ScheduleLoad(ADelayMs: integer);
    procedure RetryTick(Sender: TObject);
    procedure CheckUnreadBackfill;
    procedure SendMediaByFileId(const AContent: utf8string; ASilent: boolean);
    function TakeSendSlot(ASilent: boolean; AReplyTo, AEditId: Int64): PtrInt;
    procedure FilesParseDone(Sender: TObject; const AResp: TTdResponse);
    procedure DoSendFiles(ASlot: PtrInt; const ACaptionJson: utf8string);
    procedure FilesSentDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyXferUpdate(AFile: TJSONObject);
    procedure SendTextDone(Sender: TObject; const AResp: TTdResponse);
    procedure EditTextDone(Sender: TObject; const AResp: TTdResponse);
    procedure ActionOnlyDone(Sender: TObject; const AResp: TTdResponse);
    { Callback for SendFormattedText's own parseTextEntities request —
      see that method's comment for the two-step reason it's needed. }
    procedure ParseEntitiesDone(Sender: TObject; const AResp: TTdResponse);
    procedure ActionDone(Sender: TObject; const AResp: TTdResponse);
    procedure JumpDone(Sender: TObject; const AResp: TTdResponse);
    procedure RequestJump(AMessageId: Int64);
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
    { AUnreadFrom is the chat's last_read_inbox_message_id, and asks
      for the history to open at the first unread message with a
      divider above it; 0 (or a jump target, which wins) opens at the
      bottom as before. The caller passes it rather than this unit
      looking it up: the chat list lives in tdchats, whose rows this
      unit has no instance of. }
    { Opens the comment thread of one post. AChatId/AMessageId are the
      POST's - the channel's - and the history that follows comes from
      the linked discussion group. Answers False when this message has
      no thread (TDLib says so through can_get_message_thread; asking
      anyway just returns an error, which is handled). }
    procedure OpenThread(AChatId, AMessageId: Int64);
    { Back out of the thread, to the chat the post was read in. }
    procedure CloseThread;
    { Join a chat. The answer says whether it worked outright or a
      request went off for approval - see chatJoinResult in td_api.tl. }
    procedure JoinChat(AChatId: Int64);
    property ThreadPostId: Int64 read FThreadPostId;
    property ThreadChatId: Int64 read FThreadChatId;
    { message_thread_id открытой ветки (0 — не ветка): в группе
      обсуждения это id корневого сообщения — копии поста. }
    property ThreadId: Int64 read FThreadId;
    { Относится ли сообщение к открытой ветке. Вне ветки — всегда да. }
    function InOpenThread(AMsg: TJSONObject): boolean;
    procedure OpenChat(AChatId: Int64; AJumpToMessageId: Int64 = 0;
      AUnreadFrom: Int64 = 0);
    function TopicPart: utf8string;
    procedure ThreadDone(Sender: TObject; const AResp: TTdResponse);
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
      written in.

      ASilent sends with messageSendOptions.disable_notification
      (field checked against td_api.tl, not remembered): the message
      itself is perfectly ordinary and still counts as unread — only
      the recipient's alert sound/vibration is suppressed. It has to
      ride along through the parse step to reach the sendMessage on the
      far side of it, see ParseEntitiesDone. }
    procedure SendFormattedText(const AMarkupText: utf8string; AIsHtml: boolean;
      ASilent: boolean; AReplyTo: Int64 = 0);

    { Файлы с диска (inputFileLocal) — то, что страница загрузила через
      POST /upload. AAsPhoto: сжатыми фото (inputMessagePhoto), иначе
      документами без сжатия (inputMessageDocument) — поля сверены с
      td_api.tl. Больше одного — альбомами по SEND_ALBUM_MAX
      (sendMessageAlbum, 2..10 сообщений одного рода).

      Подпись — та же разметка, что у сообщения, через тот же
      parseTextEntities. Достаётся ПЕРВОМУ файлу у фото (так она
      становится подписью альбома) и ПОСЛЕДНЕМУ у документов — чтобы
      стояла после списка файлов, а не посреди него.

      Временный файл НЕ удаляется, когда сообщение ушло: TDLib держит
      его как локальную копию файла сообщения, и удалённый он превращал
      отправленное видео в пустой плеер (живой случай). Папку загрузок
      подчищает сервер при следующем старте.

      AExtras — на каждый путь кусок полей inputVideo от страницы
      (длительность, размеры, миниатюра) или ''. Без них TDLib ставит
      320x320 и длительность 0 (живой лог) — превью квадратное. }
    procedure SendFiles(const APaths: array of utf8string; const AExtras: array of utf8string;
      const AMode: utf8string;
      const ACaption: utf8string; AIsHtml, ASilent: boolean; AReplyTo: Int64);

    { Отмена передачи по клику на кольцо. Скачивание — cancelDownloadFile
      (td_api.tl) плюс снятие из нашей очереди и сброс пометки
      «запрошено», чтобы следующий клик снова начинал загрузку. Закачка
      исходящего — удаление самого сообщения, как у нативного клиента:
      cancelPreliminaryUploadFile — только для предварительной загрузки. }
    procedure CancelTransfer(AMessageId: Int64);

    { Replaces the text of a message already sent. Goes through the
      same parseTextEntities as a new one, so what the toolbar's
      buttons produce means the same thing in an edit as in a send -
      the alternative would be two syntaxes that drift apart.

      Whether a message MAY be edited is not decided here: it is
      messageProperties.can_be_edited, which the caller is expected to
      have asked for (QueryProperties). Editing one that may not be
      simply comes back as an error from Telegram. }
    procedure EditFormattedText(AMessageId: Int64;
      const AMarkupText: utf8string; AIsHtml: boolean);

    { Deletes one message. ARevoke = "for everyone" rather than only
      for this account; which of the two is allowed is again a
      messageProperties question (can_be_deleted_for_all_users /
      can_be_deleted_only_for_self). }
    procedure DeleteMessage(AMessageId: Int64; ARevoke: boolean);

    { Adds or removes THIS account's reaction. Only the ordinary
      (Unicode emoji) kind: a custom emoji reaction is a Premium
      sticker and the panel does not offer them yet.

      update_recent_reactions is true on adding, which is what puts a
      freshly used reaction at the front of the row Telegram offers
      next time - the same behaviour as every official client. }
    procedure ToggleReaction(AMessageId: Int64; const AEmoji: utf8string;
      AAdd: boolean);
    { The Premium kind: a reaction that is a custom emoji rather than a
      character. Same call, different reaction_type - and it is
      Telegram that decides whether this account may use one, so a
      refusal comes back as an ordinary error. }
    procedure ToggleCustomReaction(AMessageId, ACustomEmojiId: Int64;
      AAdd: boolean);

    { Pins or unpins. Pinning is silent (disable_notification) and for
      everyone, matching what the official clients do by default. }
    procedure PinMessage(AMessageId: Int64; AUnpin: boolean);

    { The three per-message QUESTIONS the context menu has to ask
      Telegram before it can draw itself: what may be done to this
      message, which reactions this chat offers, and the public link.

      They take a raw response callback and a tag rather than answering
      into the model, because none of it is model state: properties go
      stale the moment anything changes, and a link is wanted once, by
      one caller, and never again. The caller (webapi) holds the
      request it has to answer and resolves it when the response
      arrives. }
    { Кто поставил реакцию (getMessageAddedReactions; AReactionJson —
      объект ReactionType или '' для всех), кто из участников группы
      прочитал своё сообщение (getMessageViewers) и когда собеседник в
      личке прочитал (getMessageReadDate). Поля и ограничения — по
      td_api.tl: первое — при can_get_added_reactions, второе — при
      can_get_viewers, третье — при can_get_read_date; иначе TDLib
      отвечает ошибкой, и её видит страница. }
    procedure QueryAddedReactions(AMessageId: Int64; const AReactionJson: utf8string;
      ACallback: TTdResponseEvent; ATag: PtrInt);
    procedure QueryViewers(AMessageId: Int64; ACallback: TTdResponseEvent; ATag: PtrInt);
    { Запрос TDLib, не привязанный к открытому чату (разбор ссылок t.me,
      вступление по приглашению): тело — уже готовый JSON без скобок. }
    procedure Request(const AMethod, ABody: utf8string; ACallback: TTdResponseEvent;
      ATag: PtrInt);
    procedure QueryReadDate(AMessageId: Int64; ACallback: TTdResponseEvent; ATag: PtrInt);
    procedure QueryProperties(AMessageId: Int64; ACallback: TTdResponseEvent;
      ATag: PtrInt);
    procedure QueryAvailableReactions(AMessageId: Int64;
      ACallback: TTdResponseEvent; ATag: PtrInt);
    procedure QueryLink(AMessageId: Int64; ACallback: TTdResponseEvent;
      ATag: PtrInt);
    { Sends a sticker, or a saved animation, that is ALREADY on
      Telegram's side: the web UI's picker names one by its TDLib file
      id and nothing else, so nothing is uploaded and nothing has to be
      on this disk first.

      The dimensions are not decoration — inputSticker/inputAnimation
      both carry them, and Telegram shows the message at that aspect
      ratio while the recipient is still fetching the file. They come
      from the sticker/animation object the picker was built from, so
      they are Telegram's own numbers, not a guess.

      Same ASilent meaning, and the same completion path, as
      SendFormattedText. }
    procedure SendSticker(AFileId, AWidth, AHeight: integer;
      const AEmoji: utf8string; ASilent: boolean);
    procedure SendAnimation(AFileId, AWidth, AHeight, ADuration: integer;
      ASilent: boolean);
    { Sends something an INLINE BOT offered - a GIF found through the
      search bot Telegram names for it. Such a result has no file id
      of this account's own: it is sent by naming the query and the
      result back, and Telegram fetches the file itself.

      hide_via_bot stays false, so the message says "via @gif" exactly
      as it does from every other client. }
    procedure SendInlineResult(AQueryId: Int64; const AResultId: utf8string;
      ASilent: boolean);
    { Casts (or retracts) this account's vote on a poll. AOptionIndex is
      an index into ARow.Poll.Options.

      setPollAnswer takes the COMPLETE set of chosen options, not a
      delta, so this works out the new set from what is currently
      chosen: a multi-answer poll toggles the tapped option, a
      single-answer one replaces the choice (or clears it, when the
      tapped option is the one already chosen). Both only when the poll
      still allows it — a closed poll, or an already-answered poll
      that does not allow revoting, is ignored here rather than being
      sent and refused by the server.

      Nothing is written to ARow: the authoritative new counts arrive
      as updateMessageContent, the same path that already refreshes a
      poll when somebody else votes. }
    procedure SetPollAnswer(ARow: TMsgRow; AOptionIndex: integer);
    { Sends an answer that is already fully decided — the complete set
      of chosen option indexes, exactly as setPollAnswer wants it. This
      is what a multiple-answer poll's Vote button submits: there the
      user ticks first and sends once, so there is nothing to derive
      from the current state (SetPollAnswer above does that derivation
      and then ends up here). An empty set is a retraction and is a
      legitimate thing to send. }
    procedure SetPollAnswers(ARow: TMsgRow; const AOptionIndexes: array of integer);
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
    { The track's album cover (see AudioCoverFileId) — WITHOUT the Auto
      download settings gate, the same principle as
      EnsureVideoThumbFile/stickers (see the field's comment). }
    procedure EnsureAudioCoverFile(ARow: TMsgRow);
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
    { The picture inside a link preview. Its own call rather than a
      branch of the photo one: the message is a TEXT message, so there
      is no Kind to switch on - see TWebApi.CmdMediaEnsure. }
    procedure EnsureLinkFile(ARow: TMsgRow);
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
    { То же для произвольных id — эмодзи на кнопках разметки. }
    procedure EnsureCustomEmojiIds(const AIds: array of Int64);

    { A second (third, ...) listener for the same signal OnChanged
      carries. Adding the same method twice is a no-op, so a view that
      re-binds on every chat switch cannot pile up duplicates. }
    procedure AddChangeListener(AEvent: TTdMessagesEvent);
    procedure RemoveChangeListener(AEvent: TTdMessagesEvent);

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property ChatId: Int64 read FChatId;
    property Count: integer read GetCount;
    property Rows[AIndex: integer]: TMsgRow read GetRow; default;
    { Drops everything older than the newest AKeep messages.

      For a reader who has paged a long way back and then returned to
      the end: what they scrolled past is still held, still serialised
      to every view on every change, and of no use to anyone. Only the
      OLDEST end is ever dropped, which is what keeps the invariant
      this unit is built on - the loaded range runs from the newest
      message backwards, without holes. }
    procedure TrimOlder(AKeep: integer);
    property LoadingOlder: boolean read FLoadingOlder;
    property OldestLoaded: boolean read FOldestLoaded;
    { The frozen unread marker, 0 when this chat opened with nothing
      unread. See FUnreadFromId. }
    property UnreadFromId: Int64 read FUnreadFromId;
    { True once the boundary search is over — the view waits for this
      before it positions itself, so it doesn't jump twice while the
      backfill pages are still arriving. }
    property UnreadReady: boolean read FUnreadReady;
    { True when the marker is genuinely INSIDE the loaded range, i.e.
      the oldest loaded message is at or before it. Only then is "the
      first row newer than the marker" really the first unread one —
      otherwise the boundary is somewhere further back than anything
      loaded, and drawing a divider (or scrolling to it) would put it
      in the wrong place. }
    function UnreadCovered: boolean;
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

{ The cap on how many media files may be downloading at the same time,
  shared by every TTdMessages instance (there is one per account, but
  only one account is ever in the foreground). Settings > General
  writes it through TFormMain.SetDownloadConcurrency; the queueing
  itself is per-instance, see TTdMessages.RequestFileDownload. }
procedure SetDownloadConcurrency(AValue: integer);
function DownloadConcurrency: integer;

{ Download speed cap in KB/s, 0 = unlimited. Same story as the
  concurrency cap above: global value, per-instance pacing. }
procedure SetDownloadSpeedLimit(AValue: integer);
function DownloadSpeedLimit: integer;

{ Invisible mode. Set from the presence switch in the status bar
  (main.pas); read by MarkRead, which refuses to send viewMessages while
  it is on.

  The gate lives HERE, next to the request it suppresses, rather than in
  whichever view happened to ask. There are two views now — the native
  window and the browser — and a check that only one of them performs
  would mean the account stops leaking read receipts in one window and
  carries on leaking them in the other. }
procedure SetPresenceInvisible(AValue: boolean);
function PresenceInvisible: boolean;

{ What SendFormattedText hands to TDLib's parseTextEntities. Pure
  functions with no state, declared here so a harness can feed them a
  message and print what the parser would actually see - which is the
  only way to tell "the toolbar's markers" apart from "the user's own
  punctuation" without sending real messages to real people. }
function EscapeMarkdownV2(const AText: utf8string): utf8string;
function EscapeHtml(const AText: utf8string): utf8string;

implementation

uses
  customemoji;

var
  GDownloadConcurrency: integer = DOWNLOAD_CONCURRENCY_DEFAULT;
  GDownloadSpeedLimit: integer = DOWNLOAD_SPEED_DEFAULT_KB;
  { See SetPresenceInvisible. }
  GPresenceInvisible: boolean = False;

procedure SetDownloadConcurrency(AValue: integer);
begin
  if AValue < DOWNLOAD_CONCURRENCY_MIN then begin
    AValue := DOWNLOAD_CONCURRENCY_MIN;
  end;
  if AValue > DOWNLOAD_CONCURRENCY_MAX then begin
    AValue := DOWNLOAD_CONCURRENCY_MAX;
  end;
  GDownloadConcurrency := AValue;
end;

function DownloadConcurrency: integer;
begin
  Result := GDownloadConcurrency;
end;

procedure SetPresenceInvisible(AValue: boolean);
begin
  GPresenceInvisible := AValue;
end;

function PresenceInvisible: boolean;
begin
  Result := GPresenceInvisible;
end;

procedure SetDownloadSpeedLimit(AValue: integer);
begin
  if AValue < DOWNLOAD_SPEED_MIN_KB then begin
    AValue := DOWNLOAD_SPEED_MIN_KB;
  end;
  if AValue > DOWNLOAD_SPEED_MAX_KB then begin
    AValue := DOWNLOAD_SPEED_MAX_KB;
  end;
  GDownloadSpeedLimit := AValue;
end;

function DownloadSpeedLimit: integer;
begin
  Result := GDownloadSpeedLimit;
end;

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
  end else if AType = 'messagePoll' then begin
    Result := mckPoll;
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
  end else if (AType = 'textEntityTypePre')
           or (AType = 'textEntityTypePreCode') then begin
    { Two constructors for one thing, the same way the two blockquote
      kinds are handled below: a fence with a language tag comes back
      as textEntityTypePreCode, and TDLib uses it even when the tag was
      not typed - it answered "language":"php" for a plain ``` block of
      PHP. Mapping only the first one dropped the entity entirely, so a
      code block arrived at both windows as ordinary text.

      The language IS carried: TMsgEntity.Language holds it, and the
      web header shows it the way the official client does. }
    Result := mekPre;
  end else if AType = 'textEntityTypeStrikethrough' then begin
    Result := mekStrikethrough;
  end else if AType = 'textEntityTypeUnderline' then begin
    Result := mekUnderline;
  end else if AType = 'textEntityTypeCustomEmoji' then begin
    Result := mekCustomEmoji;
  end else if AType = 'textEntityTypeMention' then begin
    { @username — текст и есть имя пользователя. }
    Result := mekMention;
  end else if AType = 'textEntityTypeMentionName' then begin
    Result := mekMentionName;
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
  FReplaced := TInt64List.Create;
  FRows := TFPList.Create;
  FReplyCache := TReplyMap.Create;
  FReplyCache.Sorted := True;
  FByFile := TAudioFileMap.Create;
  FByFile.Sorted := True;
  FAudioCoverByFile := TAudioCoverFileMap.Create;
  FAudioCoverByFile.Sorted := True;
  FVoiceByFile := TVoiceFileMap.Create;
  FVoiceByFile.Sorted := True;
  FDocByFile := TDocFileMap.Create;
  FDocByFile.Sorted := True;
  FPhotoByFile := TPhotoFileMap.Create;
  FPhotoByFile.Sorted := True;
  FLinkByFile := TPhotoFileMap.Create;
  FLinkByFile.Sorted := True;
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

  { Hands out the download byte windows while a speed limit is set —
    see the media download queue below. }
  FChunkTimer := TTimer.Create(Self);
  FChunkTimer.Interval := DOWNLOAD_CHUNK_INTERVAL_MS;
  FChunkTimer.OnTimer := @ChunkTick;
  FChunkTimer.Enabled := False;
  FChunkCursor := -1;

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
  FReplaced.Free;
  FRows.Free;
  FAll.Free;
  FReplyCache.Free;
  FByFile.Free;
  FAudioCoverByFile.Free;
  FVoiceByFile.Free;
  FDocByFile.Free;
  FPhotoByFile.Free;
  FLinkByFile.Free;
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
  FAudioCoverByFile.Clear;
  FVoiceByFile.Clear;
  FDocByFile.Clear;
  FPhotoByFile.Clear;
  FLinkByFile.Clear;
  FPhotoBestByFile.Clear;
  FAnimByFile.Clear;
  FVideoByFile.Clear;
  FVideoThumbByFile.Clear;
  FStickerByFile.Clear;
  { Downloads that were still WAITING belong to a view that no longer
    exists — dropped. The ones already in flight are left alone: TDLib
    carries on with them either way, and their updateFile still arrives
    and still frees the slot, which is all FActiveDownloads is for. }
  SetLength(FQueuedDownloads, 0);
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
  FUnreadFromId := 0;
  FUnreadBackfill := 0;
  FUnreadReady := False;
  { NOT the thread fields: Clear runs from inside OpenThread too, and
    wiping them there would undo the very thing being set up. Leaving
    the thread is CloseThread's job, and it goes through OpenChat. }
  FNoProgressRetries := 0;
  FRetryTimer.Enabled := False;
  FDirty := False;
  FTimer.Enabled := False;
end;

procedure TTdMessages.OpenChat(AChatId: Int64; AJumpToMessageId: Int64;
  AUnreadFrom: Int64);
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
  { Opening any ordinary chat leaves the thread behind. }
  FThreadChatId := 0;
  FThreadPostId := 0;
  FThreadId := 0;
  FThreadBack := 0;
  { After Clear (which resets these) and before the first load, so the
    very first HistoryDone already knows whether it is hunting for the
    boundary. An explicit jump target wins: following a quote is a
    deliberate destination, the unread marker is only a default one. }
  if AJumpToMessageId = 0 then begin
    FUnreadFromId := AUnreadFrom;
    FUnreadBackfill := UNREAD_BACKFILL_PAGES;
    FUnreadReady := AUnreadFrom = 0;
  end;
  if (FChatId <> 0) and (FReq <> nil) then begin
    FReq.SendRequest('openChat', '"chat_id":' + utf8string(IntToStr(FChatId)), @ActionDone);
  end;
  NotifyChanged;
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

  NotifyChanged;
end;

{ Fires the single-slot OnChanged and then every extra listener.

  Iterates a COPY: a listener is allowed to remove itself from inside
  the callback, and mutating the array mid-loop would skip its
  neighbour. One listener raising must not rob the others of the signal
  either — a half-delivered change leaves one view showing something
  the model no longer contains. }
procedure TTdMessages.NotifyChanged;
var
  Snapshot: array of TTdMessagesEvent;
  I: integer;
begin
  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
  if Length(FChangeListeners) = 0 then begin
    Exit;
  end;
  SetLength(Snapshot, Length(FChangeListeners));
  for I := 0 to High(FChangeListeners) do begin
    Snapshot[I] := FChangeListeners[I];
  end;
  for I := 0 to High(Snapshot) do begin
    try
      Snapshot[I](Self);
    except
      { swallowed on purpose, see above }
    end;
  end;
end;

procedure TTdMessages.AddChangeListener(AEvent: TTdMessagesEvent);
var
  I: integer;
begin
  if not Assigned(AEvent) then begin
    Exit;
  end;
  for I := 0 to High(FChangeListeners) do begin
    { Method pointers are two words (code + data); comparing them as
      TMethod is the way to ask whether it is the same method on the
      same object. }
    if (TMethod(FChangeListeners[I]).Code = TMethod(AEvent).Code)
      and (TMethod(FChangeListeners[I]).Data = TMethod(AEvent).Data) then begin
      Exit;
    end;
  end;
  SetLength(FChangeListeners, Length(FChangeListeners) + 1);
  FChangeListeners[High(FChangeListeners)] := AEvent;
end;

procedure TTdMessages.RemoveChangeListener(AEvent: TTdMessagesEvent);
var
  I, J: integer;
begin
  for I := 0 to High(FChangeListeners) do begin
    if (TMethod(FChangeListeners[I]).Code = TMethod(AEvent).Code)
      and (TMethod(FChangeListeners[I]).Data = TMethod(AEvent).Data) then begin
      for J := I to High(FChangeListeners) - 1 do begin
        FChangeListeners[J] := FChangeListeners[J + 1];
      end;
      SetLength(FChangeListeners, Length(FChangeListeners) - 1);
      Exit;
    end;
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

  { Synchronously, before any request goes out — the list is already
    empty at this point and the view must show that immediately rather
    than keep the previous filter's results on screen until the
    response arrives. }
  NotifyChanged;
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
  { И общий сигнал изменения: OnLoadingChanged никто не слушает, а веб
    узнаёт loadingOlder только из messages.list по Touch. Пустая страница
    истории (пустой канал) снимала флаг и выходила без Touch — «Loading
    older messages…» висело вечно. }
  Touch;
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

    from_message_id = the oldest known message id ITSELF, with
    offset:0. With offset:0 TDLib EXCLUDES from_message_id and returns
    only messages older than it — measured, not read off the wording
    of the docs (which say "results from exactly the from_message_id"
    and could be read either way): across a whole session's
    tdlib_raw.log, 7 of 7 requests with a non-zero anchor came back
    WITHOUT that anchor among the messages. So the oldest known id is
    exactly the right boundary: nothing is skipped, nothing overlaps.

    This used to subtract TD_MESSAGE_ID_STEP first, aiming at the
    neighbouring id "slot" just older than the oldest known message —
    on the belief that the anchor was inclusive and would otherwise
    come back as a duplicate. Combined with the exclusion above, that
    was an off-by-one that silently DROPPED the message sitting in
    that slot, whenever one really sat there (i.e. whenever the next
    message up had no gap before it). The same log shows it happening
    twice in one session, in two different chats; one of them is how
    this was noticed — a chat whose first page came back with a single
    message, making the very next request skip the message right below
    it. Re-opening the chat "fixed" it only because a from_message_id
    of 0 has no such boundary to get wrong.

    The old comment claimed passing the anchor itself "doesn't move
    history at all in practice". That observation was real but
    mis-attributed: at the time the anchor was read from FRows, i.e.
    it was a stale id from before the last response (see the paragraph
    above, and note both fixes landed in the same pass). With the
    anchor read from FAll there is nothing left for it to describe.

    Whatever is passed here must stay a multiple of
    TD_MESSAGE_ID_STEP or TDLib answers code 400 "Invalid value of
    parameter from_message_id specified" on EVERY request — and since
    an error doesn't move the anchor either, the next LoadOlder
    recomputes the same invalid id and gets the same error, which
    without the guard in HistoryDone (see below) is a tight infinite
    request/error loop, exactly what happened once. A real message id
    satisfies that by construction; a computed one did not, which is
    why the constant had to be the unit of that arithmetic. }
  if FAll.Count = 0 then begin
    Anchor := 0;
    Offset := 0;
  end else begin
    Anchor := FAll.Data[0].Id;
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
  { A thread pages the same way - same anchor, same exclusive
    boundary, same HistoryDone - but the question is asked about the
    POST, not about the chat the answers live in. }
  if FThreadPostId <> 0 then begin
    FReq.SendRequest('getMessageThreadHistory',
      '"chat_id":' + utf8string(IntToStr(FThreadChatId)) +
      ',"message_id":' + utf8string(IntToStr(FThreadPostId)) +
      ',"from_message_id":' + utf8string(IntToStr(Anchor)) +
      ',"offset":' + utf8string(IntToStr(Offset)) +
      ',"limit":' + utf8string(IntToStr(FLoadLimit)),
      @HistoryDone, PtrInt(FChatId));
    Exit;
  end;

  FReq.SendRequest('getChatHistory',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"from_message_id":' + utf8string(IntToStr(Anchor)) +
    ',"offset":' + utf8string(IntToStr(Offset)) +
    ',"limit":' + utf8string(IntToStr(FLoadLimit)) +
    ',"only_local":false', @HistoryDone, PtrInt(FChatId));
end;

{ The topic a message has to name to land in the open thread, as a
  ready-made fragment for a sendMessage body - empty outside thread
  mode. In this schema it is topic_id:MessageTopic, and the variant
  for comments is messageTopicThread (td_api.tl). }
function TTdMessages.TopicPart: utf8string;
begin
  if FThreadId = 0 then begin
    Result := '';
  end else begin
    Result := ',"topic_id":{"@type":"messageTopicThread","message_thread_id":' +
      utf8string(IntToStr(FThreadId)) + '}';
  end;
end;

{ Step one: ask what the thread IS. The answer names the discussion
  group and the thread id; only then can the history be asked for. }
procedure TTdMessages.OpenThread(AChatId, AMessageId: Int64);
begin
  if (FReq = nil) or (AChatId = 0) or (AMessageId = 0) then begin
    Exit;
  end;
  { Remembered rather than carried in the tag: getMessageThreadHistory
    needs BOTH the post's chat and the post's id, and a tag is one
    machine word. Only one of these can be in flight at a time - the
    click that starts it also takes the history away. }
  FPendingThreadChat := AChatId;
  FPendingThreadMsg := AMessageId;
  FReq.SendRequest('getMessageThread',
    '"chat_id":' + utf8string(IntToStr(AChatId)) +
    ',"message_id":' + utf8string(IntToStr(AMessageId)),
    @ThreadDone);
end;

procedure TTdMessages.ThreadDone(Sender: TObject; const AResp: TTdResponse);
var
  Back, Group, Thread: Int64;
begin
  if not AResp.Success then begin
    { A post whose thread cannot be fetched is not an error worth
      showing: the button simply does nothing, and the history stays
      where it was. }
    Exit;
  end;
  Group := JGetInt64(AResp.Obj, 'chat_id');
  Thread := JGetInt64(AResp.Obj, 'message_thread_id');
  if (Group = 0) or (Thread = 0) then begin
    Exit;
  end;
  Back := FChatId;

  if (FChatId <> 0) and (FReq <> nil) then begin
    FReq.SendRequest('closeChat',
      '"chat_id":' + utf8string(IntToStr(FChatId)), @ActionDone);
  end;
  Clear;
  FChatId := Group;
  { The POST, as asked for - this is what the history is requested in
    terms of, and it is NOT the same number as message_thread_id. }
  FThreadChatId := FPendingThreadChat;
  FThreadPostId := FPendingThreadMsg;
  FThreadId := Thread;
  FThreadBack := Back;

  FReq.SendRequest('openChat',
    '"chat_id":' + utf8string(IntToStr(FChatId)), @ActionDone);
  NotifyChanged;
  LoadOlder;
end;

procedure TTdMessages.JoinChat(AChatId: Int64);
begin
  if (FReq = nil) or (AChatId = 0) then begin
    Exit;
  end;
  FReq.SendRequest('joinChat',
    '"chat_id":' + utf8string(IntToStr(AChatId)), @ActionDone);
end;

procedure TTdMessages.CloseThread;
var
  Back, Post: Int64;
begin
  if FThreadPostId = 0 then begin
    Exit;
  end;
  Back := FThreadBack;
  Post := FThreadPostId;
  { OpenChat clears the thread fields itself; it also refuses to do
    anything when asked for the chat already open, hence the reset
    first. }
  FThreadPostId := 0;
  FThreadId := 0;
  FThreadChatId := 0;
  FThreadBack := 0;
  if Back <> 0 then begin
    { Back to the POST, not merely to the channel: the reader came from
      one message and that is where they expect to land. }
    OpenChat(Back, Post);
  end;
end;

{ searchChatMessages -> foundChatMessages, an object carrying
  total_count, messages and next_from_message_id. The messages array is
  named and shaped exactly
  like getChatHistory's, so ApplyMessage is reused verbatim; what is
  genuinely different is paging and the end-of-results signal, and
  neither of getChatHistory's two hard-won workarounds applies:

  - no "walk back from the oldest loaded id" anchor — search results
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
      ScheduleLoad(RETRY_DELAY_MS);
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
      ScheduleLoad(RETRY_DELAY_MS);
    end;
  end else begin
    FNoProgressRetries := 0;
    { A screenful, before the view is left to fend for itself.

      getChatHistory answers the opening request with a SINGLE message
      in every chat measured, and the web view's only way to notice is
      to measure itself: it asks for more when its box turns out taller
      than its contents. That measurement is exactly what a window
      that is not being drawn cannot make - a hidden pane reports zero
      height, and the check that protects against asking forever on
      behalf of a zero-height box also means nothing is asked at all.
      The chat then sits at one message, with too little in it to
      scroll, and therefore nothing to trigger the next page either.

      So the boundary is moved: the model does not hand over a history
      it knows to be shorter than a page. Every step here made real
      progress (that is the branch), so the count strictly grows and
      this ends - at a screenful, or at the end of the chat. }
    if (not FOldestLoaded) and (FAll.Count < FILL_TARGET) then begin
      ScheduleLoad(FILL_DELAY_MS);
    end;
  end;

  CheckUnreadBackfill;
end;

function TTdMessages.UnreadCovered: boolean;
begin
  Result := (FUnreadFromId <> 0) and (FAll.Count > 0)
    and (FAll.Data[0].Id <= FUnreadFromId);
end;

{ History is loaded from the newest end only — that is the invariant
  everything else here depends on (LoadOlder's anchor arithmetic, and
  FAll being one contiguous range from the newest message backwards).
  So opening "at the first unread message" is not a jump into the
  middle of the chat: it is the ordinary newest-first load, repeated
  until the loaded range reaches back PAST the unread marker, after
  which the view can position itself on it. That keeps the single
  paging direction — jumping into the middle instead would leave the
  newest messages unloaded, with no way to page forward to them.

  The page budget is what stops a channel with thousands of unread
  messages from turning this into a request storm; when it runs out,
  the chat just opens at the bottom the way it always did. }
procedure TTdMessages.CheckUnreadBackfill;
begin
  if (FUnreadFromId = 0) or FUnreadReady then begin
    Exit;
  end;
  if UnreadCovered then begin
    FUnreadReady := True;
    Exit;
  end;
  { Out of history, out of budget, or a retry is already pending for
    this same anchor (piling another LoadOlder on top of FRetryTimer
    would just race it). }
  if FOldestLoaded or (FUnreadBackfill <= 0) or FRetryTimer.Enabled then begin
    FUnreadReady := True;
    Exit;
  end;
  Dec(FUnreadBackfill);
  LoadOlder;
end;

{ Arms the one timer both reasons share: a no-progress retry backs
  off, a fill follows up almost at once. }
procedure TTdMessages.ScheduleLoad(ADelayMs: integer);
begin
  FRetryTimer.Enabled := False;
  FRetryTimer.Interval := ADelayMs;
  FRetryTimer.Enabled := True;
end;

{ Forgets rows that are about to be freed.

  Every one of these maps holds a RAW POINTER to a row (file_id ->
  message, see TAudioFileMap), so an entry left behind would be written
  through by the next updateFile for that file. The queues do not need
  the same treatment: TQueuedDownload carries a file id and a callback,
  and every callback looks its row up in one of these maps and leaves
  quietly when it is not there.

  All eleven maps are the same specialisation of TFPGMap, so one
  procedure serves them all. }
procedure TTdMessages.PurgeFileMap(AMap: TAudioFileMap; AGone: TFPList);
var
  I: integer;
begin
  for I := AMap.Count - 1 downto 0 do begin
    if AGone.IndexOf(AMap.Data[I]) >= 0 then begin
      AMap.Delete(I);
    end;
  end;
end;

procedure TTdMessages.TrimOlder(AKeep: integer);
var
  Drop, I: integer;
  Row: TMsgRow;
  Gone: TFPList;
begin
  if (AKeep <= 0) or (FAll.Count <= AKeep) then begin
    Exit;
  end;
  { A filtered view pages by its own rule (FSearchNextFrom), and a
    thread's range is not this chat's - neither is ours to cut. }
  if SearchActive or (FThreadPostId <> 0) then begin
    Exit;
  end;
  Drop := FAll.Count - AKeep;
  Gone := TFPList.Create;
  try
    { FAll is keyed by message id, so index order IS oldest first -
      the same fact LoadOlder's anchor relies on. }
    for I := 0 to Drop - 1 do begin
      Gone.Add(FAll.Data[I]);
    end;
    PurgeFileMap(FByFile, Gone);
    PurgeFileMap(FAudioCoverByFile, Gone);
    PurgeFileMap(FVoiceByFile, Gone);
    PurgeFileMap(FDocByFile, Gone);
    PurgeFileMap(FPhotoByFile, Gone);
    PurgeFileMap(FLinkByFile, Gone);
    PurgeFileMap(FPhotoBestByFile, Gone);
    PurgeFileMap(FAnimByFile, Gone);
    PurgeFileMap(FVideoByFile, Gone);
    PurgeFileMap(FVideoThumbByFile, Gone);
    PurgeFileMap(FStickerByFile, Gone);
    for I := Drop - 1 downto 0 do begin
      Row := FAll.Data[I];
      FAll.Delete(I);
      Row.Free;
    end;
  finally
    Gone.Free;
  end;
  { There is more history below what is held now, whatever the model
    had concluded before. }
  FOldestLoaded := False;
  FNoProgressRetries := 0;
  FRetryTimer.Enabled := False;
  { Rebuilt HERE, not on the coalescing timer. FRows still holds the
    pointers just freed, and Count/Rows read FRows - the caller
    serialises the list the moment this returns, so a deferred rebuild
    means walking freed rows. That is not a theory: it was an access
    violation on the first run. }
  FDirty := True;
  Rebuild(nil);
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
    AEntities[N].Language := '';
    AEntities[N].UserId := 0;
    if EKind = mekMentionName then begin
      AEntities[N].UserId := JGetInt64(TypeObj, 'user_id');
    end;
    if EKind = mekTextUrl then begin
      AEntities[N].URL := JGetStr(TypeObj, 'url');
    end else begin
      AEntities[N].URL := '';
      if EKind = mekCustomEmoji then begin
        AEntities[N].CustomEmojiId := JGetInt64(TypeObj, 'custom_emoji_id');
      end else if EKind = mekPre then begin
        { Absent on textEntityTypePre, present on PreCode. }
        AEntities[N].Language := JGetStr(TypeObj, 'language');
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

{ content.poll of a messagePoll — read off a real poll (and a real
  quiz) in tdlib_raw.log rather than from memory, which is how two
  things that are easy to get wrong were caught: question and option
  text are formattedText objects, not strings, and a quiz's answer
  field is correct_option_idS, an array.

  vote_percentage comes from TDLib, so nothing here divides counts. }
procedure TTdMessages.ExtractPollMeta(AContent: TJSONObject; const AType: utf8string;
  out APoll: TMsgPoll);
var
  PollObj, TypeObj, Item: TJSONObject;
  Arr, Correct: TJSONArray;
  I, N: integer;

  { formattedText -> its plain text. }
  function TextOf(AOwner: TJSONObject; const AName: string): utf8string;
  var
    O: TJSONObject;
  begin
    O := JGetObj(AOwner, AName);
    if O = nil then begin
      Result := '';
    end else begin
      Result := JGetStr(O, 'text');
    end;
  end;

begin
  { Cleared for every message, not just polls: TMsgRow is reused across
    content updates, and a row that stops being a poll must not keep
    the old options around. }
  APoll.Id := 0;
  APoll.Question := '';
  SetLength(APoll.Options, 0);
  APoll.TotalVoters := 0;
  APoll.IsClosed := False;
  APoll.IsAnonymous := False;
  APoll.AllowsMultiple := False;
  APoll.AllowsRevoting := False;
  APoll.IsQuiz := False;
  APoll.CorrectOption := -1;

  if (AContent = nil) or (AType <> 'messagePoll') then begin
    Exit;
  end;
  PollObj := JGetObj(AContent, 'poll');
  if PollObj = nil then begin
    Exit;
  end;

  APoll.Id := JGetInt64(PollObj, 'id');
  APoll.Question := TextOf(PollObj, 'question');
  APoll.TotalVoters := JGetInt(PollObj, 'total_voter_count');
  APoll.IsClosed := JGetBool(PollObj, 'is_closed');
  APoll.IsAnonymous := JGetBool(PollObj, 'is_anonymous');
  APoll.AllowsMultiple := JGetBool(PollObj, 'allows_multiple_answers');
  APoll.AllowsRevoting := JGetBool(PollObj, 'allows_revoting');

  TypeObj := JGetObj(PollObj, 'type');
  if TypeObj <> nil then begin
    APoll.IsQuiz := JGetStr(TypeObj, '@type') = 'pollTypeQuiz';
    if APoll.IsQuiz then begin
      Correct := JGetArr(TypeObj, 'correct_option_ids');
      { Empty until the quiz is answered — TDLib withholds the answer
        on purpose, and -1 is what tells the widget not to mark
        anything green. }
      if (Correct <> nil) and (Correct.Count > 0) then begin
        APoll.CorrectOption := Correct.Integers[0];
      end;
    end;
  end;

  Arr := JGetArr(PollObj, 'options');
  if Arr = nil then begin
    Exit;
  end;
  SetLength(APoll.Options, Arr.Count);
  N := 0;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Types[I] <> jtObject then begin
      Continue;
    end;
    Item := TJSONObject(Arr.Items[I]);
    APoll.Options[N].Text := TextOf(Item, 'text');
    APoll.Options[N].VoterCount := JGetInt(Item, 'voter_count');
    APoll.Options[N].VotePercentage := JGetInt(Item, 'vote_percentage');
    APoll.Options[N].IsChosen := JGetBool(Item, 'is_chosen');
    APoll.Options[N].IsBeingChosen := JGetBool(Item, 'is_being_chosen');
    Inc(N);
  end;
  SetLength(APoll.Options, N);
end;

procedure TTdMessages.SetPollAnswer(ARow: TMsgRow; AOptionIndex: integer);
var
  I: integer;
  Chosen: array of integer;
  AlreadyVoted: boolean;

  procedure AddId(AIdx: integer);
  begin
    SetLength(Chosen, Length(Chosen) + 1);
    Chosen[High(Chosen)] := AIdx;
  end;

begin
  if (FReq = nil) or (FChatId = 0) or (ARow = nil) or (ARow.Kind <> mckPoll) then begin
    Exit;
  end;
  if (AOptionIndex < 0) or (AOptionIndex > High(ARow.Poll.Options)) then begin
    Exit;
  end;
  if ARow.Poll.IsClosed then begin
    Exit;
  end;

  AlreadyVoted := False;
  for I := 0 to High(ARow.Poll.Options) do begin
    if ARow.Poll.Options[I].IsChosen then begin
      AlreadyVoted := True;
      Break;
    end;
  end;

  SetLength(Chosen, 0);
  if ARow.Poll.AllowsMultiple then begin
    { The tapped option is toggled, everything else keeps its state —
      option_ids is the whole answer, so the untouched ones have to be
      resent or they would count as retracted. }
    for I := 0 to High(ARow.Poll.Options) do begin
      if (I = AOptionIndex) <> ARow.Poll.Options[I].IsChosen then begin
        AddId(I);
      end;
    end;
    { Un-ticking the last one leaves an empty answer, which is the
      documented way to retract — but only if the poll allows it. }
    if (Length(Chosen) = 0) and (not ARow.Poll.AllowsRevoting) then begin
      Exit;
    end;
  end else begin
    if AlreadyVoted and (not ARow.Poll.AllowsRevoting) then begin
      Exit;
    end;
    { Tapping the option already chosen retracts the vote; tapping a
      different one moves it. }
    if not ARow.Poll.Options[AOptionIndex].IsChosen then begin
      AddId(AOptionIndex);
    end;
  end;

  SetPollAnswers(ARow, Chosen);
end;

procedure TTdMessages.SetPollAnswers(ARow: TMsgRow; const AOptionIndexes: array of integer);
var
  I: integer;
  Ids: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) or (ARow = nil) or (ARow.Kind <> mckPoll) then begin
    Exit;
  end;
  if ARow.Poll.IsClosed then begin
    Exit;
  end;
  Ids := '';
  for I := 0 to High(AOptionIndexes) do begin
    if (AOptionIndexes[I] < 0) or (AOptionIndexes[I] > High(ARow.Poll.Options)) then begin
      Continue;
    end;
    if Ids <> '' then begin
      Ids := Ids + ',';
    end;
    Ids := Ids + utf8string(IntToStr(AOptionIndexes[I]));
  end;
  FReq.SendRequest('setPollAnswer',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_id":' + utf8string(IntToStr(ARow.Id)) +
    ',"option_ids":[' + Ids + ']',
    @ActionDone);
end;

{ messageAudio.audio — metadata from the file itself (ID3 etc.), which
  TDLib includes directly in content, with no download/decode needed.
  Confirmed from tdlib_raw.log: "content":{"@type":"messageAudio",
  "audio":{"@type":"audio","duration":214,"title":"...","performer":
  "...","file_name":"..."}}. }
procedure TTdMessages.ExtractAudioMeta(AContent: TJSONObject; const AType: utf8string;
  out ADuration: integer; out ATitle, APerformer, AFileName: utf8string;
  out ACoverFileId: integer; out ACoverLocalPath: utf8string;
  out AFileId: integer; out ALocalPath: utf8string);

  { A "thumbnail" object (format/width/height/file) -> its file id and,
    if it happens to be downloaded already, its path. Both cover
    sources below have this exact shape. }
  procedure ReadThumb(AThumb: TJSONObject; out AId: integer; out APath: utf8string);
  var
    FO, LO: TJSONObject;
  begin
    AId := 0;
    APath := '';
    if AThumb = nil then begin
      Exit;
    end;
    FO := JGetObj(AThumb, 'file');
    if FO = nil then begin
      Exit;
    end;
    AId := JGetInt(FO, 'id');
    LO := JGetObj(FO, 'local');
    if (LO <> nil) and JGetBool(LO, 'is_downloading_completed') then begin
      APath := JGetStr(LO, 'path');
    end;
  end;

var
  AudioObj, FileObj, LocalObj, CoverObj, ItemObj: TJSONObject;
  Arr: TJSONArray;
  I, W, H, BestIdx, LargestIdx: integer;
  Area, BestArea, LargestArea: Int64;
begin
  ADuration := 0;
  ATitle := '';
  APerformer := '';
  AFileName := '';
  ACoverFileId := 0;
  ACoverLocalPath := '';
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

  { The album cover, in order of preference (both confirmed from
    tdlib_raw.log, not from memory): album_cover_thumbnail — the art
    embedded in the file itself, usually 300x300; failing that,
    external_album_covers — what Telegram matched by title/performer
    for files that carry none, an ARRAY of the same thumbnail objects
    (100x100 and 600x600 in practice). From the array, the smallest
    entry that still covers AUDIO_COVER_SIZE is taken — the display is
    48px, downloading the 600px one for it would be pure waste — with
    the largest as the fallback when nothing reaches that size.
    album_cover_minithumbnail (a 40x40 inline base64 blur) is
    deliberately NOT used: the cover file is tens of KB and is fetched
    right away without the Auto download gate, so the blur would only
    ever flash for an instant — the same call already made for the
    video preview frame. }
  CoverObj := JGetObj(AudioObj, 'album_cover_thumbnail');
  if CoverObj <> nil then begin
    ReadThumb(CoverObj, ACoverFileId, ACoverLocalPath);
  end;
  if ACoverFileId = 0 then begin
    Arr := JGetArr(AudioObj, 'external_album_covers');
    if (Arr <> nil) and (Arr.Count > 0) then begin
      BestIdx := -1;
      BestArea := -1;
      LargestIdx := -1;
      LargestArea := -1;
      for I := 0 to Arr.Count - 1 do begin
        if Arr.Items[I].JSONType <> jtObject then begin
          Continue;
        end;
        ItemObj := TJSONObject(Arr.Items[I]);
        W := JGetInt(ItemObj, 'width');
        H := JGetInt(ItemObj, 'height');
        Area := Int64(W) * H;
        if Area > LargestArea then begin
          LargestArea := Area;
          LargestIdx := I;
        end;
        if (W >= AUDIO_COVER_SIZE) and (H >= AUDIO_COVER_SIZE) then begin
          if (BestArea < 0) or (Area < BestArea) then begin
            BestArea := Area;
            BestIdx := I;
          end;
        end;
      end;
      if BestIdx < 0 then begin
        BestIdx := LargestIdx;
      end;
      if BestIdx >= 0 then begin
        ReadThumb(TJSONObject(Arr.Items[BestIdx]), ACoverFileId, ACoverLocalPath);
      end;
    end;
  end;

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
{ ---------------- media download queue ----------------

  Everything heavy (photo preview and original, video, GIF, document,
  audio, voice note) goes through RequestFileDownload instead of
  calling downloadFile directly, so that no more than
  DownloadConcurrency of them are in flight at once. Without it, one
  scroll through a media-rich chat with auto-download on fires the
  whole AUTODL_PREFETCH_MESSAGES window at TDLib in a single go and
  every file crawls at a fraction of the bandwidth.

  Deliberately NOT gated: video thumbnails, stickers and custom emoji.
  They are tiny (tens of KB), they are the placeholders the UI shows
  while everything else loads, and queueing them behind a couple of
  multi-megabyte videos would make the chat look broken.

  SPEED LIMIT. TDLib has no bandwidth setting at all — checked against
  the real td_api.tl, not assumed: downloadFile takes a priority (an
  ordering, not a rate) and an offset/limit window, and that window is
  the only lever there is. So a limited download is not one open-ended
  request but a series of them: every DOWNLOAD_CHUNK_INTERVAL_MS one
  download is handed a fresh window of ChunkBytes starting at whatever
  it has already got, and TDLib physically cannot fetch past the end of
  that window until the next one is granted. Windows are handed out
  round-robin, one per tick across ALL throttled downloads, so the cap
  is on the total rather than per file.

  Two things this deliberately does NOT rely on. It does not wait to be
  told a window was filled (no notification is documented for the
  auto-cancel at the end of a limit), and it does not care whether the
  previous window is finished — re-requesting from the current prefix
  simply moves the ceiling, and if the network is slower than the cap
  the ceiling just stays ahead and nothing is throttled twice. If a
  file makes no progress for several windows in a row it is released
  back to a plain unlimited request (see NoteFileDownloadState): a
  speed cap must never be able to wedge a download permanently. }

function TTdMessages.ActiveDownloadIndex(AFileId: integer): integer;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(FActiveDownloads) do begin
    if FActiveDownloads[I].FileId = AFileId then begin
      Result := I;
      Exit;
    end;
  end;
end;

function TTdMessages.QueuedDownloadIndex(AFileId: integer): integer;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(FQueuedDownloads) do begin
    if FQueuedDownloads[I].FileId = AFileId then begin
      Result := I;
      Exit;
    end;
  end;
end;

function TTdMessages.RefillBytes: Int64;
begin
  Result := (Int64(DownloadSpeedLimit) * 1024 * DOWNLOAD_CHUNK_INTERVAL_MS) div 1000;
  if Result < 1 then begin
    Result := 1;
  end;
end;

function TTdMessages.WindowBytes: Int64;
begin
  Result := FByteBudget;
  if Result < TD_DOWNLOAD_PART_BYTES then begin
    Result := TD_DOWNLOAD_PART_BYTES;
  end;
end;

{ Runs for as long as anything is downloading, limit or no limit: the
  limit is a global that can change at any moment and nothing notifies
  this instance, so the tick is also where a change is noticed (see
  ChunkTick). A 250ms timer scanning a handful of entries costs
  nothing. }
procedure TTdMessages.UpdateChunkTimer;
begin
  FChunkTimer.Enabled := Length(FActiveDownloads) > 0;
end;

procedure TTdMessages.SendFileDownload(AFileId: integer; ACallback: TTdResponseEvent);
var
  Idx: integer;
begin
  SetLength(FActiveDownloads, Length(FActiveDownloads) + 1);
  Idx := High(FActiveDownloads);
  FActiveDownloads[Idx].FileId := AFileId;
  FActiveDownloads[Idx].Callback := ACallback;
  FActiveDownloads[Idx].NextOffset := 0;
  FActiveDownloads[Idx].Stalls := 0;
  FActiveDownloads[Idx].Unthrottled := DownloadSpeedLimit <= 0;
  FActiveDownloads[Idx].GaveUp := False;
  if FActiveDownloads[Idx].Unthrottled then begin
    FReq.SendRequest('downloadFile',
      '"file_id":' + utf8string(IntToStr(AFileId)) +
      ',"priority":32,"offset":0,"limit":0,"synchronous":false',
      ACallback, AFileId);
  end else if FByteBudget > 0 then begin
    { The first window right away — waiting a tick before a download
      even starts would be visible on small files. Only while there is
      budget for it, though: granting unconditionally would hand every
      newly started download a free part, and a stream of files smaller
      than one part (previews, scrolling a feed) would then never be
      paced at all — each one finishes inside its free window, releases
      its slot, and the queue starts the next one just as freely. With
      no budget the download simply waits for a tick; ChunkTick's
      round-robin picks it up, it is already in FActiveDownloads. }
    GrantChunk(Idx);
  end;
  UpdateChunkTimer;
end;

procedure TTdMessages.GrantChunk(AIndex: integer);
begin
  if (AIndex < 0) or (AIndex > High(FActiveDownloads)) or (FReq = nil) then begin
    Exit;
  end;
  if FActiveDownloads[AIndex].Unthrottled then begin
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(FActiveDownloads[AIndex].FileId)) +
    ',"priority":32,"offset":' + utf8string(IntToStr(FActiveDownloads[AIndex].NextOffset)) +
    ',"limit":' + utf8string(IntToStr(WindowBytes)) +
    ',"synchronous":false',
    FActiveDownloads[AIndex].Callback, FActiveDownloads[AIndex].FileId);
end;

{ One window per tick, round-robin — that, and not the window size
  alone, is what makes the cap apply to the total rather than to each
  file separately.

  The tick is also where a change to the limit is picked up, in both
  directions. Turning the limit OFF has to hand every paced download
  back to an open-ended request, or it would sit there forever waiting
  for windows that are no longer granted. Turning it ON adopts the
  downloads that started unlimited: re-requesting from offset 0 with a
  window is harmless — TDLib keeps what it already has, reports the
  real prefix back, and pacing continues from there. }
procedure TTdMessages.ChunkTick(Sender: TObject);
var
  I, Tries: integer;
  Cap: Int64;
begin
  if Length(FActiveDownloads) = 0 then begin
    UpdateChunkTimer;
    Exit;
  end;

  if DownloadSpeedLimit <= 0 then begin
    for I := 0 to High(FActiveDownloads) do begin
      if not FActiveDownloads[I].Unthrottled then begin
        FActiveDownloads[I].Unthrottled := True;
        if FReq <> nil then begin
          FReq.SendRequest('downloadFile',
            '"file_id":' + utf8string(IntToStr(FActiveDownloads[I].FileId)) +
            ',"priority":32,"offset":0,"limit":0,"synchronous":false',
            FActiveDownloads[I].Callback, FActiveDownloads[I].FileId);
        end;
      end;
    end;
    Exit;
  end;

  for I := 0 to High(FActiveDownloads) do begin
    if FActiveDownloads[I].Unthrottled and (not FActiveDownloads[I].GaveUp) then begin
      FActiveDownloads[I].Unthrottled := False;
      FActiveDownloads[I].NextOffset := 0;
      FActiveDownloads[I].Stalls := 0;
    end;
  end;

  { Refill, then cap. The cap matters after a lull — several ticks with
    nothing to spend on must not add up to one huge burst the moment a
    download appears. One part plus one tick's worth is enough to keep
    a fast link saturated without letting the bucket hoard. }
  Inc(FByteBudget, RefillBytes);
  Cap := TD_DOWNLOAD_PART_BYTES + RefillBytes;
  if FByteBudget > Cap then begin
    FByteBudget := Cap;
  end;
  if FByteBudget <= 0 then begin
    { Still paying off the last window TDLib overshot — that wait IS
      the throttle. }
    Exit;
  end;

  Tries := 0;
  while Tries <= High(FActiveDownloads) do begin
    Inc(FChunkCursor);
    if FChunkCursor > High(FActiveDownloads) then begin
      FChunkCursor := 0;
    end;
    if not FActiveDownloads[FChunkCursor].Unthrottled then begin
      GrantChunk(FChunkCursor);
      Exit;
    end;
    Inc(Tries);
  end;
end;

procedure TTdMessages.RequestFileDownload(AFileId: integer; ACallback: TTdResponseEvent);
begin
  if (FReq = nil) or (AFileId = 0) then begin
    Exit;
  end;
  if (ActiveDownloadIndex(AFileId) >= 0) or (QueuedDownloadIndex(AFileId) >= 0) then begin
    Exit;
  end;
  if Length(FActiveDownloads) < DownloadConcurrency then begin
    SendFileDownload(AFileId, ACallback);
    Exit;
  end;
  SetLength(FQueuedDownloads, Length(FQueuedDownloads) + 1);
  FQueuedDownloads[High(FQueuedDownloads)].FileId := AFileId;
  FQueuedDownloads[High(FQueuedDownloads)].Callback := ACallback;
end;

procedure TTdMessages.PumpDownloadQueue;
var
  Next: TQueuedDownload;
  I: integer;
begin
  while (Length(FQueuedDownloads) > 0) and (Length(FActiveDownloads) < DownloadConcurrency) do begin
    Next := FQueuedDownloads[0];
    for I := 0 to High(FQueuedDownloads) - 1 do begin
      FQueuedDownloads[I] := FQueuedDownloads[I + 1];
    end;
    SetLength(FQueuedDownloads, Length(FQueuedDownloads) - 1);
    if FReq <> nil then begin
      SendFileDownload(Next.FileId, Next.Callback);
    end;
  end;
end;

procedure TTdMessages.ReleaseDownloadSlot(AFileId: integer);
var
  Idx, I: integer;
begin
  Idx := ActiveDownloadIndex(AFileId);
  if Idx < 0 then begin
    Exit;
  end;
  for I := Idx to High(FActiveDownloads) - 1 do begin
    FActiveDownloads[I] := FActiveDownloads[I + 1];
  end;
  SetLength(FActiveDownloads, Length(FActiveDownloads) - 1);
  UpdateChunkTimer;
  PumpDownloadQueue;
end;

{ A slot is held from the moment downloadFile is sent until TDLib says
  it is no longer downloading that file. Both endings count: completed,
  and stopped without completing (cancelled, or failed). Releasing on
  "not active" is also the safety valve against a leaked slot — an
  updateFile that raced ahead of our own request can free a slot a
  moment early, which at worst means one extra parallel download, while
  the opposite mistake would shrink the cap permanently.

  With a speed limit on, "not active" is the NORMAL state between
  windows and must not release anything — only completion does. What
  this reads instead is how far the file has actually got
  (download_offset + downloaded_prefix_size, exactly as td_api.tl
  defines the pair), which is where the next window will start. }
procedure TTdMessages.NoteFileDownloadState(AFile: TJSONObject);
var
  Local: TJSONObject;
  FileId, Idx: integer;
  Prefix: Int64;
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := ActiveDownloadIndex(FileId);
  if Idx < 0 then begin
    Exit;
  end;
  Local := JGetObj(AFile, 'local');
  if Local = nil then begin
    Exit;
  end;
  if JGetBool(Local, 'is_downloading_completed') then begin
    ReleaseDownloadSlot(FileId);
    Exit;
  end;
  if FActiveDownloads[Idx].Unthrottled then begin
    if not JGetBool(Local, 'is_downloading_active') then begin
      ReleaseDownloadSlot(FileId);
    end;
    Exit;
  end;

  Prefix := JGetInt64(Local, 'download_offset') + JGetInt64(Local, 'downloaded_prefix_size');
  if Prefix > FActiveDownloads[Idx].NextOffset then begin
    { Charge the budget with what was ACTUALLY fetched, not with the
      window that was asked for: TDLib rounds a window up to a whole
      part, so the two differ almost every time, and only the real
      figure keeps the average at the configured rate. }
    Dec(FByteBudget, Prefix - FActiveDownloads[Idx].NextOffset);
    FActiveDownloads[Idx].NextOffset := Prefix;
    FActiveDownloads[Idx].Stalls := 0;
    Exit;
  end;
  if JGetBool(Local, 'is_downloading_active') then begin
    Exit;
  end;
  { Not moving and not downloading: either the window happens to be
    exactly full at this instant, or the windowing is not working for
    this file at all. After a few of these, stop paying for the
    experiment and let it run unlimited — a speed cap that can strand a
    download is worse than no cap. }
  Inc(FActiveDownloads[Idx].Stalls);
  if FActiveDownloads[Idx].Stalls >= 4 then begin
    FActiveDownloads[Idx].Unthrottled := True;
    FActiveDownloads[Idx].GaveUp := True;
    FReq.SendRequest('downloadFile',
      '"file_id":' + utf8string(IntToStr(FileId)) +
      ',"priority":32,"offset":0,"limit":0,"synchronous":false',
      FActiveDownloads[Idx].Callback, FileId);
  end;
end;

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
{ How many comments a channel post has, and whether any are unread.

  reply_info is present only where comments exist at all - TDLib fills
  it for channels that have a discussion supergroup - so its absence is
  the answer "this post takes no comments", not a missing field. }
procedure TTdMessages.ExtractReplyInfo(AInteractionInfo: TJSONObject;
  ARow: TMsgRow);
var
  Info: TJSONObject;
begin
  ARow.HasComments := False;
  ARow.CommentCount := 0;
  ARow.CommentUnread := False;
  if AInteractionInfo = nil then begin
    Exit;
  end;
  Info := JGetObj(AInteractionInfo, 'reply_info');
  if Info = nil then begin
    Exit;
  end;
  ARow.HasComments := True;
  ARow.CommentCount := JGetInt(Info, 'reply_count');
  ARow.CommentUnread :=
    JGetInt64(Info, 'last_message_id') > JGetInt64(Info, 'last_read_inbox_message_id');
end;

{ The link preview inside a text message.

  Telegram builds these itself - the claim is true, and the log shows
  it: `link_preview` rides inside messageText already filled in, so
  there is nothing for this client to fetch or parse out of the page.

  `type` is a union of some forty variants. Measured on this account,
  four of them actually turn up: Photo, EmbeddedVideoPlayer, Article
  and Animation. What they have in common is a `photo` object (under
  `photo` or, for the players, `thumbnail`), which is the only part of
  the union read here. Everything else still gets its card, just
  without a picture - which is also what Article looks like when the
  page has no image, and that happens too (a GitHub link, measured). }
procedure TTdMessages.ExtractLinkPreview(AContent: TJSONObject;
  const AType: utf8string; ARow: TMsgRow);
var
  Prev, TypeObj, PhotoObj, MiniObj, SizeObj, FileObj, LocalObj: TJSONObject;
  Arr: TJSONArray;
  I, BestIdx, W, H: integer;
  BestArea, Area: Int64;
  B64: utf8string;
begin
  ARow.LinkUrl := '';
  ARow.LinkDisplay := '';
  ARow.LinkSite := '';
  ARow.LinkTitle := '';
  ARow.LinkDesc := '';
  ARow.LinkLarge := False;
  ARow.LinkPhotoW := 0;
  ARow.LinkPhotoH := 0;
  ARow.LinkMinithumb := '';
  ARow.LinkPhotoFileId := 0;
  ARow.LinkPhotoPath := '';
  ARow.LinkPhotoRequested := False;
  if (AContent = nil) or (AType <> 'messageText') then begin
    Exit;
  end;
  Prev := JGetObj(AContent, 'link_preview');
  if Prev = nil then begin
    Exit;
  end;

  ARow.LinkUrl := JGetStr(Prev, 'url');
  ARow.LinkDisplay := JGetStr(Prev, 'display_url');
  ARow.LinkSite := JGetStr(Prev, 'site_name');
  ARow.LinkTitle := JGetStr(Prev, 'title');
  { description is a formattedText; the card shows one paragraph, so
    the entities are dropped rather than carried down. }
  ARow.LinkDesc := JGetStr(JGetObj(Prev, 'description'), 'text');
  ARow.LinkLarge := JGetBool(Prev, 'show_large_media');

  TypeObj := JGetObj(Prev, 'type');
  if TypeObj = nil then begin
    Exit;
  end;
  PhotoObj := JGetObj(TypeObj, 'photo');
  if PhotoObj = nil then begin
    PhotoObj := JGetObj(TypeObj, 'thumbnail');
  end;
  if PhotoObj = nil then begin
    Exit;
  end;

  MiniObj := JGetObj(PhotoObj, 'minithumbnail');
  if MiniObj <> nil then begin
    B64 := JGetStr(MiniObj, 'data');
    if B64 <> '' then begin
      ARow.LinkMinithumb := DecodeStringBase64(string(B64));
    end;
  end;

  { The largest layer. A preview picture is small to begin with - the
    card is at most a few hundred pixels wide - so there is no second,
    cheaper layer worth the arithmetic ExtractPhotoMeta does. }
  Arr := JGetArr(PhotoObj, 'sizes');
  if (Arr = nil) or (Arr.Count = 0) then begin
    Exit;
  end;
  BestIdx := 0;
  BestArea := -1;
  for I := 0 to Arr.Count - 1 do begin
    if Arr.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    W := JGetInt(TJSONObject(Arr.Items[I]), 'width');
    H := JGetInt(TJSONObject(Arr.Items[I]), 'height');
    Area := Int64(W) * H;
    if Area > BestArea then begin
      BestArea := Area;
      BestIdx := I;
    end;
  end;
  if Arr.Items[BestIdx].JSONType <> jtObject then begin
    Exit;
  end;
  SizeObj := TJSONObject(Arr.Items[BestIdx]);
  ARow.LinkPhotoW := JGetInt(SizeObj, 'width');
  ARow.LinkPhotoH := JGetInt(SizeObj, 'height');
  FileObj := JGetObj(SizeObj, 'photo');
  if FileObj = nil then begin
    Exit;
  end;
  ARow.LinkPhotoFileId := JGetInt(FileObj, 'id');
  LocalObj := JGetObj(FileObj, 'local');
  if (LocalObj <> nil) and JGetBool(LocalObj, 'is_downloading_completed') then begin
    ARow.LinkPhotoPath := JGetStr(LocalObj, 'path');
  end;
end;

{ Same shape as EnsurePhotoFile, over the link map. }
procedure TTdMessages.EnsureLinkFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.LinkPhotoFileId = 0) or (ARow.LinkPhotoPath <> '')
     or ARow.LinkPhotoRequested then begin
    Exit;
  end;
  ARow.LinkPhotoRequested := True;
  if FLinkByFile.IndexOf(ARow.LinkPhotoFileId) < 0 then begin
    FLinkByFile.Add(ARow.LinkPhotoFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.LinkPhotoRequested := False;
    Exit;
  end;
  RequestFileDownload(ARow.LinkPhotoFileId, @DownloadLinkDone);
end;

procedure TTdMessages.DownloadLinkDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyLinkFile(AResp.Obj);
    NoteFileDownloadState(AResp.Obj);
    Exit;
  end;
  ReleaseDownloadSlot(integer(AResp.Tag));
  Idx := FLinkByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FLinkByFile.Data[Idx].LinkPhotoRequested := False;
  end;
end;

{ No progress bar for this one, unlike ApplyPhotoFile: the card either
  has its picture or wears the blurred stamp, and a preview thumbnail
  is a few kilobytes. }
procedure TTdMessages.ApplyLinkFile(AFile: TJSONObject);
var
  Idx: integer;
  Local: TJSONObject;
  R: TMsgRow;
  Path: utf8string;
begin
  if AFile = nil then begin
    Exit;
  end;
  Idx := FLinkByFile.IndexOf(JGetInt(AFile, 'id'));
  if Idx < 0 then begin
    Exit;
  end;
  R := FLinkByFile.Data[Idx];
  Local := JGetObj(AFile, 'local');
  if (Local = nil) or (not JGetBool(Local, 'is_downloading_completed')) then begin
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if (Path = '') or (Path = R.LinkPhotoPath) then begin
    Exit;
  end;
  R.LinkPhotoPath := Path;
  Touch;
end;

procedure TTdMessages.ExtractPhotoMeta(AContent: TJSONObject; const AType: utf8string;
  out AWidth, AHeight: integer; out AMinithumb: RawByteString;
  out AFileId: integer; out ALocalPath: utf8string;
  out ABestFileId: integer; out ABestLocalPath: utf8string;
  out ABestWidth, ABestHeight: integer);
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
  ABestWidth := 0;
  ABestHeight := 0;
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
    ABestWidth := JGetInt(SizeObj, 'width');
    ABestHeight := JGetInt(SizeObj, 'height');
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

{ ---------------- transfer progress (any media) ---------------- }

{ Основной файл содержимого — тот, ход передачи которого показывает
  страница: документ, трек, голосовое, видео, GIF; у фото — самый
  большой размер (его TDLib закачивает при отправке). nil — у вида нет
  файла, ход которого стоит показывать (стикер, текст). Пути по
  td_api.tl: messageDocument.document.document, messageAudio.audio.audio,
  messageVoiceNote.voice_note.voice, messageVideo.video.video,
  messageAnimation.animation.animation, messagePhoto.photo.sizes[].photo. }
function MainFileObj(AContent: TJSONObject; const AType: utf8string): TJSONObject;
var
  Inner: TJSONObject;
  Sizes: TJSONArray;
begin
  Result := nil;
  if AContent = nil then begin
    Exit;
  end;
  if AType = 'messageDocument' then begin
    Inner := JGetObj(AContent, 'document');
    if Inner <> nil then Result := JGetObj(Inner, 'document');
  end else if AType = 'messageAudio' then begin
    Inner := JGetObj(AContent, 'audio');
    if Inner <> nil then Result := JGetObj(Inner, 'audio');
  end else if AType = 'messageVoiceNote' then begin
    Inner := JGetObj(AContent, 'voice_note');
    if Inner <> nil then Result := JGetObj(Inner, 'voice');
  end else if AType = 'messageVideo' then begin
    Inner := JGetObj(AContent, 'video');
    if Inner <> nil then Result := JGetObj(Inner, 'video');
  end else if AType = 'messageAnimation' then begin
    Inner := JGetObj(AContent, 'animation');
    if Inner <> nil then Result := JGetObj(Inner, 'animation');
  end else if AType = 'messagePhoto' then begin
    Inner := JGetObj(AContent, 'photo');
    if Inner <> nil then begin
      Sizes := JGetArr(Inner, 'sizes');
      if (Sizes <> nil) and (Sizes.Count > 0)
         and (Sizes.Items[Sizes.Count - 1] is TJSONObject) then begin
        Result := JGetObj(TJSONObject(Sizes.Items[Sizes.Count - 1]), 'photo');
      end;
    end;
  end;
end;

{ Доля в сотых — по ней решается, стоит ли перерисовывать: updateFile
  приходит на каждый пакет, а странице хватает шага в процент. }
function XferBucket(ADone, ATotal: Int64): integer;
begin
  if ATotal <= 0 then begin
    Result := -1;
  end else begin
    Result := integer((ADone * 100) div ATotal);
  end;
end;

{ Состояние передачи строки из объекта file. True — изменилось видимое:
  началась или кончилась передача, сменилось направление или процент.

  Закачка (remote.is_uploading_active) важнее скачивания: исходящий
  файл сначала лежит у нас целиком, и local говорит «готово», пока
  remote ещё идёт. size бывает 0, пока TDLib не знает точного размера, —
  тогда expected_size, его же оценка. }
function ApplyXferFile(ARow: TMsgRow; AFile: TJSONObject; AInFlight: boolean): boolean;
var
  Local, Remote: TJSONObject;
  Total, Done: Int64;
  Up, Active: boolean;
begin
  Result := False;
  if (ARow = nil) or (AFile = nil) then begin
    Exit;
  end;
  Local := JGetObj(AFile, 'local');
  Remote := JGetObj(AFile, 'remote');
  Total := JGetInt64(AFile, 'size');
  if Total <= 0 then begin
    Total := JGetInt64(AFile, 'expected_size');
  end;
  Up := False;
  Active := False;
  Done := 0;
  if (Remote <> nil) and JGetBool(Remote, 'is_uploading_active') then begin
    Up := True;
    Active := True;
    Done := JGetInt64(Remote, 'uploaded_size');
  end else if (Local <> nil) and (JGetBool(Local, 'is_downloading_active')
      or (AInFlight and not JGetBool(Local, 'is_downloading_completed'))) then begin
    { AInFlight — файл в нашей очереди загрузок. С ограничением скорости
      TDLib между окнами говорит is_downloading_active = false, и без
      этого кольцо мигало бы на каждом окне. }
    Active := True;
    Done := JGetInt64(Local, 'downloaded_size');
  end else if Local <> nil then begin
    Done := JGetInt64(Local, 'downloaded_size');
  end;

  Result := (Active <> ARow.XferActive) or (Up <> ARow.XferUp)
    or (XferBucket(Done, Total) <> XferBucket(ARow.XferDone, ARow.XferTotal));
  ARow.XferActive := Active;
  ARow.XferUp := Up;
  ARow.XferDone := Done;
  ARow.XferTotal := Total;
  ARow.XferFileId := JGetInt(AFile, 'id');
end;

procedure ResetXfer(ARow: TMsgRow);
begin
  ARow.XferActive := False;
  ARow.XferUp := False;
  ARow.XferDone := 0;
  ARow.XferTotal := 0;
  ARow.XferFileId := 0;
end;

{ Строка, у которой этот файл — один из медиафайлов. У фото их два:
  превью, которое качается для показа, и оригинал, который уходит при
  отправке; ход показывается того, что сейчас передаётся. }
function RowHasFile(ARow: TMsgRow; AFileId: integer): boolean;
begin
  Result := (AFileId <> 0) and (
       (ARow.DocFileId = AFileId) or (ARow.AudioFileId = AFileId)
    or (ARow.VoiceFileId = AFileId) or (ARow.VideoFileId = AFileId)
    or (ARow.AnimFileId = AFileId) or (ARow.PhotoFileId = AFileId)
    or (ARow.PhotoBestFileId = AFileId));
end;

procedure TTdMessages.ApplyXferUpdate(AFile: TJSONObject);
var
  Id, I: integer;
  Changed, InFlight: boolean;
begin
  if AFile = nil then begin
    Exit;
  end;
  Id := JGetInt(AFile, 'id');
  if Id = 0 then begin
    Exit;
  end;
  InFlight := (ActiveDownloadIndex(Id) >= 0) or (QueuedDownloadIndex(Id) >= 0);
  Changed := False;
  for I := 0 to FAll.Count - 1 do begin
    if RowHasFile(FAll.Data[I], Id)
       and ApplyXferFile(FAll.Data[I], AFile, InFlight) then begin
      Changed := True;
    end;
  end;
  if Changed then begin
    Touch;
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
  { Уже заменено настоящим — опоздавший ответ отправки (см. FReplaced). }
  if FReplaced.IndexOf(Id) >= 0 then begin
    Exit;
  end;

  WasNew := Lookup(Id) = nil;
  R := Obtain(Id);
  R.ChatId := MsgChatId;
  R.Date := JGetInt64(AMsg, 'date');
  R.EditDate := JGetInt64(AMsg, 'edit_date');
  R.IsOutgoing := JGetBool(AMsg, 'is_outgoing');
  R.IsPinned := JGetBool(AMsg, 'is_pinned');
  R.AlbumId := JGetInt64(AMsg, 'media_album_id');

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
  { До проверки «содержимое не изменилось» ниже: кнопки меняются и без
    смены содержимого. }
  if JGetObj(AMsg, 'reply_markup') <> nil then begin
    R.ReplyMarkupRaw := utf8string(JGetObj(AMsg, 'reply_markup').AsJSON);
  end else begin
    R.ReplyMarkupRaw := '';
  end;
  ExtractReactions(JGetObj(AMsg, 'interaction_info'), R.Reactions);
  R.CanSeeReactors := JGetBool(JGetObj(JGetObj(AMsg, 'interaction_info'), 'reactions'),
    'can_get_added_reactions');
  ExtractReplyInfo(JGetObj(AMsg, 'interaction_info'), R);

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
    R.AudioCoverFileId, R.AudioCoverLocalPath, R.AudioFileId, R.AudioLocalPath);
  ExtractVoiceMeta(ContentObj, T, R.VoiceDuration, R.VoiceFileId, R.VoiceLocalPath);
  ExtractDocMeta(ContentObj, T, R.DocFileName, R.DocFileSize, R.DocFileId, R.DocLocalPath);
  ExtractLinkPreview(ContentObj, T, R);
  ExtractPhotoMeta(ContentObj, T, R.PhotoWidth, R.PhotoHeight, R.PhotoMinithumb,
    R.PhotoFileId, R.PhotoLocalPath, R.PhotoBestFileId, R.PhotoBestLocalPath,
    R.PhotoBestWidth, R.PhotoBestHeight);
  ExtractAnimMeta(ContentObj, T, R.AnimWidth, R.AnimHeight, R.AnimDuration,
    R.AnimMinithumb, R.AnimFileId, R.AnimLocalPath);
  ExtractVideoMeta(ContentObj, T, R.VideoWidth, R.VideoHeight, R.VideoDuration,
    R.VideoThumbFileId, R.VideoThumbWidth, R.VideoThumbHeight, R.VideoThumbLocalPath,
    R.VideoFileId, R.VideoLocalPath);
  ExtractStickerMeta(ContentObj, T, R.StickerWidth, R.StickerHeight, R.StickerFormat,
    R.StickerFileId, R.StickerLocalPath);
  ExtractPollMeta(ContentObj, T, R.Poll);
  { Состояние передачи — из самого сообщения: исходящее приходит уже
    закачивающимся, а файл, начатый в прошлый раз, — недокачанным. }
  if MainFileObj(ContentObj, T) <> nil then begin
    ApplyXferFile(R, MainFileObj(ContentObj, T),
      ActiveDownloadIndex(JGetInt(MainFileObj(ContentObj, T), 'id')) >= 0);
  end else begin
    ResetXfer(R);
  end;

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
    R.AudioCoverFileId, R.AudioCoverLocalPath, R.AudioFileId, R.AudioLocalPath);
  ExtractVoiceMeta(ANewContent, T, R.VoiceDuration, R.VoiceFileId, R.VoiceLocalPath);
  ExtractDocMeta(ANewContent, T, R.DocFileName, R.DocFileSize, R.DocFileId, R.DocLocalPath);
  ExtractPhotoMeta(ANewContent, T, R.PhotoWidth, R.PhotoHeight, R.PhotoMinithumb,
    R.PhotoFileId, R.PhotoLocalPath, R.PhotoBestFileId, R.PhotoBestLocalPath,
    R.PhotoBestWidth, R.PhotoBestHeight);
  ExtractAnimMeta(ANewContent, T, R.AnimWidth, R.AnimHeight, R.AnimDuration,
    R.AnimMinithumb, R.AnimFileId, R.AnimLocalPath);
  ExtractVideoMeta(ANewContent, T, R.VideoWidth, R.VideoHeight, R.VideoDuration,
    R.VideoThumbFileId, R.VideoThumbWidth, R.VideoThumbHeight, R.VideoThumbLocalPath,
    R.VideoFileId, R.VideoLocalPath);
  ExtractStickerMeta(ANewContent, T, R.StickerWidth, R.StickerHeight, R.StickerFormat,
    R.StickerFileId, R.StickerLocalPath);
  ExtractPollMeta(ANewContent, T, R.Poll);
  if MainFileObj(ANewContent, T) <> nil then begin
    ApplyXferFile(R, MainFileObj(ANewContent, T),
      ActiveDownloadIndex(JGetInt(MainFileObj(ANewContent, T), 'id')) >= 0);
  end else begin
    ResetXfer(R);
  end;
  if R.LayoutCache <> nil then begin
    R.LayoutCache.Free;
    R.LayoutCache := nil;
  end;
  Touch;
end;

{ The two "send something Telegram already has" paths. Shapes checked
  against td_api.tl at 1.8.67, the version this build talks to:

    inputMessageSticker sticker:inputSticker emoji:string
    inputSticker sticker:InputFile thumbnail:inputThumbnail width height
    inputMessageAnimation animation:inputAnimation caption ...
    inputAnimation animation:InputFile thumbnail added_sticker_file_ids
                   duration width height

  Both wrap the file in inputFileId rather than inputFileRemote: the id
  is the one TDLib itself handed out for this session, which is exactly
  what inputFileId takes, and it saves carrying the remote id string
  around just to hand it back.

  The optional members (thumbnail, caption, added_sticker_file_ids) are
  left out entirely. TDLib reads a missing object member as null, and
  null is what they would have to be - there is no thumbnail to offer
  for a file we never uploaded. }
procedure TTdMessages.SendMediaByFileId(const AContent: utf8string; ASilent: boolean);
var
  Body: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;
  Body := '"chat_id":' + utf8string(IntToStr(FChatId)) + TopicPart;
  if ASilent then begin
    Body := Body +
      ',"options":{"@type":"messageSendOptions","disable_notification":true}';
  end;
  Body := Body + ',"input_message_content":' + AContent;
  FReq.SendRequest('sendMessage', Body, @SendTextDone);
end;

procedure TTdMessages.SendSticker(AFileId, AWidth, AHeight: integer;
  const AEmoji: utf8string; ASilent: boolean);
var
  Emoji: TJSONString;
  Content: utf8string;
begin
  { The emoji goes through TJSONString rather than straight into the
    request text: it is whatever Telegram attached to that sticker, and
    a quote or a backslash in it would break the request. }
  Emoji := TJSONString.Create(string(AEmoji));
  try
    Content := '{"@type":"inputMessageSticker","sticker":{"@type":"inputSticker"' +
      ',"sticker":{"@type":"inputFileId","id":' + utf8string(IntToStr(AFileId)) + '}' +
      ',"width":' + utf8string(IntToStr(AWidth)) +
      ',"height":' + utf8string(IntToStr(AHeight)) + '}' +
      ',"emoji":' + utf8string(Emoji.AsJSON) + '}';
  finally
    Emoji.Free;
  end;
  SendMediaByFileId(Content, ASilent);
end;

procedure TTdMessages.SendAnimation(AFileId, AWidth, AHeight, ADuration: integer;
  ASilent: boolean);
var
  Content: utf8string;
begin
  Content := '{"@type":"inputMessageAnimation","animation":{"@type":"inputAnimation"' +
    ',"animation":{"@type":"inputFileId","id":' + utf8string(IntToStr(AFileId)) + '}' +
    ',"duration":' + utf8string(IntToStr(ADuration)) +
    ',"width":' + utf8string(IntToStr(AWidth)) +
    ',"height":' + utf8string(IntToStr(AHeight)) + '}}';
  SendMediaByFileId(Content, ASilent);
end;

procedure TTdMessages.SendInlineResult(AQueryId: Int64;
  const AResultId: utf8string; ASilent: boolean);
var
  Body: utf8string;
  Rid: TJSONString;
begin
  if (FReq = nil) or (FChatId = 0) or (AQueryId = 0) or (AResultId = '') then begin
    Exit;
  end;
  Rid := TJSONString.Create(string(AResultId));
  try
    Body := '"chat_id":' + utf8string(IntToStr(FChatId));
    if ASilent then begin
      Body := Body +
        ',"options":{"@type":"messageSendOptions","disable_notification":true}';
    end;
    { query_id is an int64, and td_api's JSON carries those as TEXT. }
    Body := Body +
      ',"query_id":"' + utf8string(IntToStr(AQueryId)) + '"' +
      ',"result_id":' + utf8string(Rid.AsJSON) +
      ',"hide_via_bot":false';
  finally
    Rid.Free;
  end;
  FReq.SendRequest('sendInlineQueryResultMessage', Body, @SendTextDone);
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

  { Inside a code span the rules are different, and much simpler: per
    the MarkdownV2 spec only '`' and '\' mean anything between
    backticks - underscores, asterisks, brackets, punctuation are all
    literal there.

    Escaping the rest is not merely pointless, it is visible damage: a
    backslash inside a pre/code entity is NOT an escape, so every one
    of them ends up in the message. And recursing into the general
    escaper, which is what used to happen here, re-parses the content
    as markdown - which is how a pasted snippet with two underscores in
    it (add_action, woocommerce_after_register) came out in italics. }
  function EscapeCodeSpan(const AInner: string): string;
  begin
    { Backslash first: doing it after would double the ones just added
      in front of the backticks. }
    Result := StringReplace(AInner, '\', '\\', [rfReplaceAll]);
    Result := StringReplace(Result, '`', '\`', [rfReplaceAll]);
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
  function TryWrapper(const AMarker: string; ABreakOnNewline: boolean;
    ACodeSpan: boolean = False): boolean;
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
    if ACodeSpan then begin
      Res := Res + AMarker + EscapeCodeSpan(Inner) + AMarker;
    end else begin
      Res := Res + AMarker + string(EscapeMarkdownV2(utf8string(Inner))) + AMarker;
    end;
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

  { ![👍](tg://emoji?id=123) — кастомный эмодзи, синтаксис по
    core.telegram.org/bots/api (MarkdownV2). Пропускается только точная
    форма, которую вставляет панель эмодзи: адрес tg://emoji?id= и одни
    цифры. Всё остальное, что начинается с '!', — обычный текст, и '!'
    экранируется как всегда. Эмодзи внутри скобок экранируется, как
    текст ссылки; в нём и так нечего экранировать. }
  function TryCustomEmoji: boolean;
  const
    PREFIX = '](tg://emoji?id=';
  var
    CloseBracket, K, DigitsStart: integer;
    Alt: string;
  begin
    Result := False;
    CloseBracket := 0;
    K := I + 2;
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
    if (CloseBracket = 0) or (CloseBracket = I + 2)
       or (Copy(S, CloseBracket, Length(PREFIX)) <> PREFIX) then begin
      Exit;
    end;
    DigitsStart := CloseBracket + Length(PREFIX);
    K := DigitsStart;
    while (K <= L) and (S[K] in ['0'..'9']) do begin
      Inc(K);
    end;
    if (K = DigitsStart) or (K > L) or (S[K] <> ')') then begin
      Exit;
    end;
    Alt := Copy(S, I + 2, CloseBracket - (I + 2));
    Res := Res + '![' + string(EscapeMarkdownV2(utf8string(Alt))) +
      Copy(S, CloseBracket, K - CloseBracket + 1);
    I := K + 1;
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
    if (Copy(S, I, 3) = '```') and TryWrapper('```', False, True) then begin
      Continue;
    end;
    if (S[I] = '!') and (I < L) and (S[I + 1] = '[') and TryCustomEmoji then begin
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
      '`': if TryWrapper('`', True, True) then Continue;
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
  { Кастомный эмодзи: <tg-emoji emoji-id="123">👍</tg-emoji>, синтаксис
    по core.telegram.org/bots/api. Открывающий тег пропускается только
    с цифрами в emoji-id — так его вставляет панель эмодзи. }
  EMOJI_OPEN = '<tg-emoji emoji-id="';
  EMOJI_CLOSE = '</tg-emoji>';
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
      if (not Matched) and (Copy(S, I, Length(EMOJI_OPEN)) = EMOJI_OPEN) then begin
        K := I + Length(EMOJI_OPEN);
        CloseQuote := K;
        while (CloseQuote <= L) and (S[CloseQuote] in ['0'..'9']) do begin
          Inc(CloseQuote);
        end;
        if (CloseQuote > K) and (CloseQuote + 1 <= L)
           and (S[CloseQuote] = '"') and (S[CloseQuote + 1] = '>') then begin
          Res := Res + Copy(S, I, CloseQuote + 2 - I);
          I := CloseQuote + 2;
          Matched := True;
        end;
      end;
      if (not Matched) and (Copy(S, I, Length(EMOJI_CLOSE)) = EMOJI_CLOSE) then begin
        Res := Res + EMOJI_CLOSE;
        Inc(I, Length(EMOJI_CLOSE));
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

function TTdMessages.TakeSendSlot(ASilent: boolean; AReplyTo, AEditId: Int64): PtrInt;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(FSends) do begin
    if not FSends[I].Busy then begin
      Result := I;
      Break;
    end;
  end;
  if Result < 0 then begin
    SetLength(FSends, Length(FSends) + 1);
    Result := High(FSends);
  end;
  FSends[Result].Busy := True;
  FSends[Result].Silent := ASilent;
  FSends[Result].ReplyTo := AReplyTo;
  FSends[Result].EditId := AEditId;
end;

procedure TTdMessages.SendFormattedText(const AMarkupText: utf8string; AIsHtml: boolean;
  ASilent: boolean; AReplyTo: Int64);
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

  { ASilent belongs to THIS send, but the sendMessage that uses it only
    happens once the parse comes back — so it travels on the request
    itself (tdreq's per-request Tag, which exists for exactly this: FPC
    3.2 has no closures). A field on Self would work until two sends
    overlapped, and then the second one's flag would decide the first
    one's message. }
  FReq.SendRequest('parseTextEntities', Body, @ParseEntitiesDone,
    TakeSendSlot(ASilent, AReplyTo, 0));
end;

{ ---------------- files from the page ---------------- }

{ Сообщение (временный id) -> временный файл, который оно везёт. Общая
  для всех экземпляров: updateMessageSendSucceeded приходит той модели,
  что открыта, а отправить могли из любой. }
var
  GUploadByMsg: TStringList = nil;

procedure NoteUploadMessage(AMsgId: Int64; const APath: utf8string);
begin
  if (AMsgId = 0) or (APath = '') then begin
    Exit;
  end;
  if GUploadByMsg = nil then begin
    GUploadByMsg := TStringList.Create;
  end;
  GUploadByMsg.Values[IntToStr(AMsgId)] := string(APath);
end;

{ Удаляет файл и его каталог (uploads/<id>/ — в нём только этот файл). }
procedure ForgetUploadMessage(AMsgId: Int64; ADelete: boolean = True);
var
  I: integer;
  Path: string;
begin
  if GUploadByMsg = nil then begin
    Exit;
  end;
  I := GUploadByMsg.IndexOfName(IntToStr(AMsgId));
  if I < 0 then begin
    Exit;
  end;
  Path := GUploadByMsg.ValueFromIndex[I];
  GUploadByMsg.Delete(I);
  if ADelete then begin
    DeleteFile(Path);
    RemoveDir(ExtractFileDir(Path));
  end;
end;

procedure TTdMessages.CancelTransfer(AMessageId: Int64);
var
  R: TMsgRow;
  FileId, Q, I: integer;
begin
  R := Lookup(AMessageId);
  if (R = nil) or (FReq = nil) or not R.XferActive then begin
    Exit;
  end;

  if R.XferUp then begin
    DeleteMessage(AMessageId, True);
    { Временная копия больше не нужна. Если TDLib ещё держит файл,
      Windows не даст удалить — тогда его подчистит старт сервера. }
    ForgetUploadMessage(AMessageId);
    Exit;
  end;

  FileId := R.XferFileId;
  if FileId = 0 then begin
    Exit;
  end;
  Q := QueuedDownloadIndex(FileId);
  if Q >= 0 then begin
    for I := Q to High(FQueuedDownloads) - 1 do begin
      FQueuedDownloads[I] := FQueuedDownloads[I + 1];
    end;
    SetLength(FQueuedDownloads, Length(FQueuedDownloads) - 1);
  end;
  FReq.SendRequest('cancelDownloadFile',
    '"file_id":' + utf8string(IntToStr(FileId)) + ',"only_if_pending":false', nil);
  ReleaseDownloadSlot(FileId);

  { Иначе Ensure*File решит, что файл уже запрошен, и повторный клик
    ничего не сделает. }
  if R.DocFileId = FileId then R.DocDownloadRequested := False;
  if R.AudioFileId = FileId then R.AudioDownloadRequested := False;
  if R.VoiceFileId = FileId then R.VoiceDownloadRequested := False;
  if R.VideoFileId = FileId then R.VideoDownloadRequested := False;
  if R.AnimFileId = FileId then R.AnimDownloadRequested := False;
  if R.PhotoFileId = FileId then R.PhotoDownloadRequested := False;
  if R.PhotoBestFileId = FileId then R.PhotoBestDownloadRequested := False;
  ResetXfer(R);
  Touch;
end;

procedure TTdMessages.SendFiles(const APaths: array of utf8string; const AExtras: array of utf8string;
  const AMode: utf8string;
  const ACaption: utf8string; AIsHtml, ASilent: boolean; AReplyTo: Int64);
var
  Slot: PtrInt;
  I: integer;
  ModeObj: TJSONObject;
  TextVal: TJSONString;
  Body, EscapedText: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) or (Length(APaths) = 0) then begin
    Exit;
  end;

  Slot := -1;
  for I := 0 to High(FFileSends) do begin
    if not FFileSends[I].Busy then begin
      Slot := I;
      Break;
    end;
  end;
  if Slot < 0 then begin
    SetLength(FFileSends, Length(FFileSends) + 1);
    Slot := High(FFileSends);
  end;
  FFileSends[Slot].Busy := True;
  SetLength(FFileSends[Slot].Paths, Length(APaths));
  SetLength(FFileSends[Slot].Extras, Length(APaths));
  for I := 0 to High(APaths) do begin
    FFileSends[Slot].Paths[I] := APaths[I];
    if I <= High(AExtras) then begin
      FFileSends[Slot].Extras[I] := AExtras[I];
    end else begin
      FFileSends[Slot].Extras[I] := '';
    end;
  end;
  FFileSends[Slot].Mode := AMode;
  FFileSends[Slot].Silent := ASilent;
  FFileSends[Slot].ReplyTo := AReplyTo;

  if Trim(string(ACaption)) = '' then begin
    DoSendFiles(Slot, '');
    Exit;
  end;

  { Подпись — тем же путём, что текст сообщения: экранирование своих
    знаков (см. EscapeMarkdownV2/EscapeHtml) и parseTextEntities. }
  if AIsHtml then begin
    EscapedText := EscapeHtml(ACaption);
  end else begin
    EscapedText := EscapeMarkdownV2(ACaption);
  end;
  ModeObj := TJSONObject.Create;
  TextVal := TJSONString.Create(string(EscapedText));
  try
    if AIsHtml then begin
      ModeObj.Strings['@type'] := 'textParseModeHTML';
    end else begin
      ModeObj.Strings['@type'] := 'textParseModeMarkdown';
      ModeObj.Integers['version'] := 2;
    end;
    Body := '"text":' + utf8string(TextVal.AsJSON) +
            ',"parse_mode":' + utf8string(ModeObj.AsJSON);
  finally
    TextVal.Free;
    ModeObj.Free;
  end;
  FReq.SendRequest('parseTextEntities', Body, @FilesParseDone, Slot);
end;

procedure TTdMessages.FilesParseDone(Sender: TObject; const AResp: TTdResponse);
var
  Clean: TJSONObject;
  EntitiesArr: TJSONArray;
begin
  if (AResp.Tag < 0) or (AResp.Tag > High(FFileSends)) then begin
    Exit;
  end;
  if not AResp.Success then begin
    FFileSends[AResp.Tag].Busy := False;
    if Assigned(FOnActionError) then begin
      FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'parse');
    end;
    Exit;
  end;
  { Чистый formattedText без "@extra", как в ParseEntitiesDone. }
  Clean := TJSONObject.Create;
  try
    Clean.Strings['@type'] := 'formattedText';
    Clean.Strings['text'] := string(JGetStr(AResp.Obj, 'text'));
    EntitiesArr := JGetArr(AResp.Obj, 'entities');
    if EntitiesArr <> nil then begin
      Clean.Add('entities', EntitiesArr.Clone as TJSONArray);
    end;
    DoSendFiles(AResp.Tag, utf8string(Clean.AsJSON));
  finally
    Clean.Free;
  end;
end;

procedure TTdMessages.DoSendFiles(ASlot: PtrInt; const ACaptionJson: utf8string);
var
  Paths, Extras: array of utf8string;
  Silent: boolean;
  ReplyTo: Int64;
  N, CaptionAt, First, Last, I, B: integer;
  Body, Contents, Content, Mode, Ext: utf8string;
  PathVal: TJSONString;
begin
  Paths := FFileSends[ASlot].Paths;
  Extras := FFileSends[ASlot].Extras;
  FFileSends[ASlot].Extras := nil;
  Mode := FFileSends[ASlot].Mode;
  Silent := FFileSends[ASlot].Silent;
  ReplyTo := FFileSends[ASlot].ReplyTo;
  FFileSends[ASlot].Busy := False;
  FFileSends[ASlot].Paths := nil;
  if (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;

  N := Length(Paths);
  if Mode = 'media' then begin
    CaptionAt := 0;
  end else begin
    CaptionAt := N - 1;
  end;

  First := 0;
  while First < N do begin
    Last := First + SEND_ALBUM_MAX - 1;
    if Last > N - 1 then begin
      Last := N - 1;
    end;

    Contents := '';
    for I := First to Last do begin
      PathVal := TJSONString.Create(string(Paths[I]));
      try
        Ext := LowerCase(utf8string(ExtractFileExt(string(Paths[I]))));
        if (Mode = 'media') and ((Ext = '.mp4') or (Ext = '.mov') or (Ext = '.m4v')
           or (Ext = '.webm') or (Ext = '.mkv')) then begin
          { Видео — inputMessageVideo / inputVideo (td_api.tl), с потоковым
            воспроизведением. }
          Content := '{"@type":"inputMessageVideo","video":{"@type":"inputVideo"' +
            ',"video":{"@type":"inputFileLocal","path":' + utf8string(PathVal.AsJSON) + '}' +
            ',"supports_streaming":true';
          if I <= High(Extras) then begin
            Content := Content + Extras[I];
          end;
          Content := Content + '}';
        end else if Mode = 'media' then begin
          Content := '{"@type":"inputMessagePhoto","photo":{"@type":"inputPhoto"' +
            ',"photo":{"@type":"inputFileLocal","path":' + utf8string(PathVal.AsJSON) + '}}';
        end else if Mode = 'audio' then begin
          { Музыка — inputMessageAudio / inputAudio; название и исполнителя
            TDLib достанет из тегов файла. }
          Content := '{"@type":"inputMessageAudio","audio":{"@type":"inputAudio"' +
            ',"audio":{"@type":"inputFileLocal","path":' + utf8string(PathVal.AsJSON) + '}}';
        end else begin
          Content := '{"@type":"inputMessageDocument","document":{"@type":"inputDocument"' +
            ',"document":{"@type":"inputFileLocal","path":' + utf8string(PathVal.AsJSON) + '}}';
        end;
      finally
        PathVal.Free;
      end;
      if (I = CaptionAt) and (ACaptionJson <> '') then begin
        Content := Content + ',"caption":' + ACaptionJson;
      end;
      Content := Content + '}';
      if Contents <> '' then begin
        Contents := Contents + ',';
      end;
      Contents := Contents + Content;
    end;

    Body := '"chat_id":' + utf8string(IntToStr(FChatId)) + TopicPart;
    if Silent then begin
      Body := Body +
        ',"options":{"@type":"messageSendOptions","disable_notification":true}';
    end;
    { Ответом — только первое сообщение; остальные пачки идут следом. }
    if (First = 0) and (ReplyTo <> 0) then begin
      Body := Body +
        ',"reply_to":{"@type":"inputMessageReplyToMessage","message_id":' +
        utf8string(IntToStr(ReplyTo)) + '}';
    end;

    B := -1;
    for I := 0 to High(FFileBatches) do begin
      if not FFileBatches[I].Busy then begin
        B := I;
        Break;
      end;
    end;
    if B < 0 then begin
      SetLength(FFileBatches, Length(FFileBatches) + 1);
      B := High(FFileBatches);
    end;
    FFileBatches[B].Busy := True;
    SetLength(FFileBatches[B].Paths, Last - First + 1);
    for I := First to Last do begin
      FFileBatches[B].Paths[I - First] := Paths[I];
    end;

    { Один файл — обычное сообщение: sendMessageAlbum берёт от двух. }
    if Last = First then begin
      FReq.SendRequest('sendMessage',
        Body + ',"input_message_content":' + Contents, @FilesSentDone, B);
    end else begin
      FReq.SendRequest('sendMessageAlbum',
        Body + ',"input_message_contents":[' + Contents + ']', @FilesSentDone, B);
    end;
    First := Last + 1;
  end;
end;

procedure TTdMessages.FilesSentDone(Sender: TObject; const AResp: TTdResponse);
var
  Paths: array of utf8string;
  Arr: TJSONArray;
  I: integer;
begin
  if (AResp.Tag < 0) or (AResp.Tag > High(FFileBatches)) then begin
    Exit;
  end;
  Paths := FFileBatches[AResp.Tag].Paths;
  FFileBatches[AResp.Tag].Busy := False;
  FFileBatches[AResp.Tag].Paths := nil;

  if not AResp.Success then begin
    if Assigned(FOnActionError) then begin
      FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'send');
    end;
    Exit;
  end;

  if JGetStr(AResp.Obj, '@type') = 'messages' then begin
    Arr := JGetArr(AResp.Obj, 'messages');
    if Arr = nil then begin
      Exit;
    end;
    for I := 0 to Arr.Count - 1 do begin
      if not (Arr.Items[I] is TJSONObject) then begin
        Continue;
      end;
      if I <= High(Paths) then begin
        NoteUploadMessage(JGetInt64(TJSONObject(Arr.Items[I]), 'id'), Paths[I]);
      end;
      ApplyMessage(TJSONObject(Arr.Items[I]));
    end;
  end else begin
    if Length(Paths) > 0 then begin
      NoteUploadMessage(JGetInt64(AResp.Obj, 'id'), Paths[0]);
    end;
    ApplyMessage(AResp.Obj);
  end;
end;

{ An edit is the same two steps as a send - parse, then act - so it
  shares the parse and differs only in what the second step is. }
procedure TTdMessages.EditFormattedText(AMessageId: Int64;
  const AMarkupText: utf8string; AIsHtml: boolean);
var
  ModeObj: TJSONObject;
  TextVal: TJSONString;
  Body, EscapedText: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) or (AMessageId = 0)
     or (Trim(string(AMarkupText)) = '') then begin
    Exit;
  end;

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
    ModeObj.Integers['version'] := 2;
  end;
  TextVal := TJSONString.Create(string(EscapedText));
  try
    Body := '"text":' + utf8string(TextVal.AsJSON) +
            ',"parse_mode":' + utf8string(ModeObj.AsJSON);
  finally
    TextVal.Free;
    ModeObj.Free;
  end;

  FReq.SendRequest('parseTextEntities', Body, @ParseEntitiesDone,
    TakeSendSlot(False, 0, AMessageId));
end;

procedure TTdMessages.DeleteMessage(AMessageId: Int64; ARevoke: boolean);
const
  BOOLSTR: array[boolean] of utf8string = ('false', 'true');
begin
  if (FReq = nil) or (FChatId = 0) or (AMessageId = 0) then begin
    Exit;
  end;
  { deleteMessages takes a VECTOR even for one message. The row is not
    removed here: updateDeleteMessages comes back and every view is
    already listening for it, so doing it twice would only risk the two
    disagreeing. }
  FReq.SendRequest('deleteMessages',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_ids":[' + utf8string(IntToStr(AMessageId)) + ']' +
    ',"revoke":' + BOOLSTR[ARevoke],
    @ActionOnlyDone);
end;

procedure TTdMessages.ToggleReaction(AMessageId: Int64; const AEmoji: utf8string;
  AAdd: boolean);
var
  E: TJSONString;
  Body: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) or (AMessageId = 0) or (AEmoji = '') then begin
    Exit;
  end;
  E := TJSONString.Create(string(AEmoji));
  try
    Body := '"chat_id":' + utf8string(IntToStr(FChatId)) +
            ',"message_id":' + utf8string(IntToStr(AMessageId)) +
            ',"reaction_type":{"@type":"reactionTypeEmoji","emoji":' +
            utf8string(E.AsJSON) + '}';
  finally
    E.Free;
  end;
  if AAdd then begin
    FReq.SendRequest('addMessageReaction',
      Body + ',"is_big":false,"update_recent_reactions":true', @ActionOnlyDone);
  end else begin
    FReq.SendRequest('removeMessageReaction', Body, @ActionOnlyDone);
  end;
end;

procedure TTdMessages.ToggleCustomReaction(AMessageId, ACustomEmojiId: Int64;
  AAdd: boolean);
var
  Body: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) or (AMessageId = 0) or (ACustomEmojiId = 0) then begin
    Exit;
  end;
  { custom_emoji_id is an int64, and td_api's JSON carries those as
    TEXT - the same rule the ids in the entities already follow. }
  Body := '"chat_id":' + utf8string(IntToStr(FChatId)) +
          ',"message_id":' + utf8string(IntToStr(AMessageId)) +
          ',"reaction_type":{"@type":"reactionTypeCustomEmoji","custom_emoji_id":"' +
          utf8string(IntToStr(ACustomEmojiId)) + '"}';
  if AAdd then begin
    FReq.SendRequest('addMessageReaction',
      Body + ',"is_big":false,"update_recent_reactions":true', @ActionOnlyDone);
  end else begin
    FReq.SendRequest('removeMessageReaction', Body, @ActionOnlyDone);
  end;
end;

procedure TTdMessages.PinMessage(AMessageId: Int64; AUnpin: boolean);
var
  Body: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) or (AMessageId = 0) then begin
    Exit;
  end;
  Body := '"chat_id":' + utf8string(IntToStr(FChatId)) +
          ',"message_id":' + utf8string(IntToStr(AMessageId));
  if AUnpin then begin
    FReq.SendRequest('unpinChatMessage', Body, @ActionOnlyDone);
  end else begin
    FReq.SendRequest('pinChatMessage',
      Body + ',"disable_notification":true,"only_for_self":false',
      @ActionOnlyDone);
  end;
end;

procedure TTdMessages.QueryAddedReactions(AMessageId: Int64;
  const AReactionJson: utf8string; ACallback: TTdResponseEvent; ATag: PtrInt);
var
  Body: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;
  Body := '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_id":' + utf8string(IntToStr(AMessageId));
  if AReactionJson <> '' then begin
    Body := Body + ',"reaction_type":' + AReactionJson;
  end;
  { Сотня — предел запроса; для всплывающего списка этого с избытком. }
  FReq.SendRequest('getMessageAddedReactions',
    Body + ',"offset":"","limit":100', ACallback, ATag);
end;

procedure TTdMessages.Request(const AMethod, ABody: utf8string;
  ACallback: TTdResponseEvent; ATag: PtrInt);
begin
  if FReq = nil then begin
    Exit;
  end;
  FReq.SendRequest(AMethod, ABody, ACallback, ATag);
end;

procedure TTdMessages.QueryViewers(AMessageId: Int64; ACallback: TTdResponseEvent;
  ATag: PtrInt);
begin
  if (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;
  FReq.SendRequest('getMessageViewers',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_id":' + utf8string(IntToStr(AMessageId)), ACallback, ATag);
end;

procedure TTdMessages.QueryReadDate(AMessageId: Int64; ACallback: TTdResponseEvent;
  ATag: PtrInt);
begin
  if (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;
  FReq.SendRequest('getMessageReadDate',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_id":' + utf8string(IntToStr(AMessageId)), ACallback, ATag);
end;

procedure TTdMessages.QueryProperties(AMessageId: Int64;
  ACallback: TTdResponseEvent; ATag: PtrInt);
begin
  if (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;
  FReq.SendRequest('getMessageProperties',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_id":' + utf8string(IntToStr(AMessageId)), ACallback, ATag);
end;

procedure TTdMessages.QueryAvailableReactions(AMessageId: Int64;
  ACallback: TTdResponseEvent; ATag: PtrInt);
begin
  if (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;
  { row_size says how wide the caller's own reaction strip is, and it
    shapes how many TOP reactions come back. td_api.tl allows 5-25;
    asked for the maximum, because the strip scrolls rather than
    stopping at a row - see the note in webapi.pas/MenuReactionsDone. }
  FReq.SendRequest('getMessageAvailableReactions',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_id":' + utf8string(IntToStr(AMessageId)) +
    ',"row_size":25', ACallback, ATag);
end;

procedure TTdMessages.QueryLink(AMessageId: Int64; ACallback: TTdResponseEvent;
  ATag: PtrInt);
begin
  if (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;
  FReq.SendRequest('getMessageLink',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"message_id":' + utf8string(IntToStr(AMessageId)) +
    ',"media_timestamp":0,"for_album":false,"in_message_thread":false',
    ACallback, ATag);
end;

{ For the actions whose only answer is Ok or an error. Every one of
  them is followed by an update that the views already listen to, so
  there is nothing to apply here - only a failure worth reporting. }
procedure TTdMessages.ActionOnlyDone(Sender: TObject; const AResp: TTdResponse);
begin
  if (not AResp.Success) and Assigned(FOnActionError) then begin
    FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'action');
  end;
end;

procedure TTdMessages.EditTextDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    ApplyMessage(AResp.Obj);
  end else if Assigned(FOnActionError) then begin
    FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'edit');
  end;
end;

procedure TTdMessages.ParseEntitiesDone(Sender: TObject; const AResp: TTdResponse);
var
  Clean: TJSONObject;
  EntitiesArr: TJSONArray;
  Body: utf8string;
  Silent: boolean;
  ReplyTo, Edit: Int64;
begin
  { Read out and released FIRST, so the slot cannot leak down any of
    the early exits below. }
  Silent := False;
  ReplyTo := 0;
  Edit := 0;
  if (AResp.Tag >= 0) and (AResp.Tag <= High(FSends)) then begin
    Silent := FSends[AResp.Tag].Silent;
    ReplyTo := FSends[AResp.Tag].ReplyTo;
    Edit := FSends[AResp.Tag].EditId;
    FSends[AResp.Tag].Busy := False;
  end;

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
    Body := '"chat_id":' + utf8string(IntToStr(FChatId));
    { Everything decided before the parse, carried here on the
      request's Tag as an index into FSends (see TPendingSend). }
    if Edit <> 0 then begin
      Body := Body + ',"message_id":' + utf8string(IntToStr(Edit));
    end else begin
      { In a comment thread a new message has to name the thread, or it
        lands loose in the discussion group instead of under the post.
        An EDIT never does: it already belongs where it is. }
      Body := Body + TopicPart;
      if Silent then begin
        { Only sent when it is actually on: everything omitted from
          messageSendOptions defaults to false/absent anyway, so a
          normal send stays byte-for-byte the request it has always
          been. }
        Body := Body +
          ',"options":{"@type":"messageSendOptions","disable_notification":true}';
      end;
      if ReplyTo <> 0 then begin
        Body := Body +
          ',"reply_to":{"@type":"inputMessageReplyToMessage","message_id":' +
          utf8string(IntToStr(ReplyTo)) + '}';
      end;
    end;
    Body := Body +
            ',"input_message_content":{"@type":"inputMessageText","text":' +
            utf8string(Clean.AsJSON) + '}';
  finally
    Clean.Free;
  end;

  { Same final step as SendText: the response is the message object
    itself, new or edited, no separate temporary id needed. }
  if Edit <> 0 then begin
    FReq.SendRequest('editMessageText', Body, @EditTextDone);
  end else begin
    FReq.SendRequest('sendMessage', Body, @SendTextDone);
  end;
end;

procedure TTdMessages.MarkRead(const AMessageIds: array of Int64);
var
  Ids: utf8string;
  I: integer;
begin
  if (FReq = nil) or (FChatId = 0) or (Length(AMessageIds) = 0) then begin
    Exit;
  end;
  { Invisible mode: reading is exactly the signal it is meant to
    withhold. See SetPresenceInvisible. }
  if GPresenceInvisible then begin
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
    NotifyChanged;
  end;
  FJump.ChatId := FChatId;
  FJump.Target := AMessageId;
  FJump.Retries := 0;
  RequestJump(AMessageId);
end;

procedure TTdMessages.RequestJump(AMessageId: Int64);
begin
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

  { Цели в ответе нет — TDLib отдал только локальное (см.
    JUMP_RETRY_MAX). Тот же запрос ещё раз, пока прыжок всё ещё этот:
    чат не сменился и новый прыжок его не перебил. Готовность —
    только когда цель на месте или повторы кончились. }
  if (Lookup(TargetId) = nil) and (FJump.ChatId = FChatId)
    and (FJump.Target = TargetId) and (FJump.Retries < JUMP_RETRY_MAX) then begin
    Inc(FJump.Retries);
    RequestJump(TargetId);
    Exit;
  end;

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
    mckPoll:      Result := 'Poll';
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
  RequestFileDownload(ARow.AudioFileId, @DownloadAudioDone);
end;

procedure TTdMessages.DownloadAudioDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyAudioFile(AResp.Obj);
    { A file TDLib already had on disk comes back complete right here
      and never produces an updateFile — without this the slot it took
      would be held for the rest of the session. }
    NoteFileDownloadState(AResp.Obj);
    Exit;
  end;
  ReleaseDownloadSlot(integer(AResp.Tag));
  Idx := FByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FByFile.Data[Idx].AudioDownloadRequested := False;
  end;
end;

{ The file this row was pointing at is no longer on disk.

  TDLib deletes cached files, and this app asks it to on every start
  (ApplyCacheLimit sends optimizeStorage with a TTL). What comes back
  is awkward: a history response can still carry the OLD record, file
  complete and path filled in, and the correction arrives one line
  later as an updateFile with an empty path and
  is_downloading_completed false. Measured on one session's log: 41 of
  531 completed paths were already gone, and TDLib had said so for
  every single one.

  Until now the Apply*File handlers simply returned on that update and
  kept the stale path. The native window drew a missing image; the web
  was worse, because the page was handed a /media/ link that answers
  404 and the link's TEXT never changed afterwards - so the message
  node was never rebuilt and the broken frame stayed for the rest of
  the session, while clicking it opened the original just fine.

  Forgetting the path also clears the "already asked" flag, so the
  next Ensure* downloads it again instead of trusting a file that is
  not there. }
procedure TTdMessages.ForgetFile(var APath: utf8string; var ARequested: boolean);
begin
  { An empty path is the ordinary state of a file being downloaded -
    every progress update passes through here. Nothing to forget, and
    nothing to tell anyone about. }
  if APath = '' then begin
    Exit;
  end;
  APath := '';
  ARequested := False;
  Touch;
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
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(FByFile.Data[Idx].AudioLocalPath, FByFile.Data[Idx].AudioDownloadRequested);
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

{ The album cover — an exact copy of EnsureVideoThumbFile/
  DownloadVideoThumbDone/ApplyVideoThumbFile in shape, with its own
  map (its own file_id, not shared with the track itself). Like the
  video preview frame it goes through FReq.SendRequest DIRECTLY rather
  than RequestFileDownload: covers are tens of KB and are the artwork
  the widget is standing in for, so queueing them behind a couple of
  multi-megabyte videos would leave the chat looking broken — the same
  exemption stickers and video thumbnails already have. }
procedure TTdMessages.EnsureAudioCoverFile(ARow: TMsgRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  if (ARow.AudioCoverFileId = 0) or (ARow.AudioCoverLocalPath <> '') or
     ARow.AudioCoverDownloadRequested then begin
    Exit;
  end;
  ARow.AudioCoverDownloadRequested := True;
  if FAudioCoverByFile.IndexOf(ARow.AudioCoverFileId) < 0 then begin
    FAudioCoverByFile.Add(ARow.AudioCoverFileId, ARow);
  end;
  if FReq = nil then begin
    ARow.AudioCoverDownloadRequested := False;
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.AudioCoverFileId)) +
    ',"priority":32,"offset":0,"limit":0,"synchronous":false',
    @DownloadAudioCoverDone, ARow.AudioCoverFileId);
end;

procedure TTdMessages.DownloadAudioCoverDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyAudioCoverFile(AResp.Obj);
    Exit;
  end;
  Idx := FAudioCoverByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FAudioCoverByFile.Data[Idx].AudioCoverDownloadRequested := False;
  end;
end;

procedure TTdMessages.ApplyAudioCoverFile(AFile: TJSONObject);
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
  Idx := FAudioCoverByFile.IndexOf(FileId);
  if Idx < 0 then begin
    Exit;
  end;

  Local := JGetObj(AFile, 'local');
  if not JGetBool(Local, 'is_downloading_completed') then begin
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(FAudioCoverByFile.Data[Idx].AudioCoverLocalPath, FAudioCoverByFile.Data[Idx].AudioCoverDownloadRequested);
    Exit;
  end;
  Path := JGetStr(Local, 'path');
  if Path = '' then begin
    Exit;
  end;

  R := FAudioCoverByFile.Data[Idx];
  if R.AudioCoverLocalPath = Path then begin
    Exit;
  end;
  R.AudioCoverLocalPath := Path;
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
  RequestFileDownload(ARow.VoiceFileId, @DownloadVoiceDone);
end;

procedure TTdMessages.DownloadVoiceDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyVoiceFile(AResp.Obj);
    { A file TDLib already had on disk comes back complete right here
      and never produces an updateFile — without this the slot it took
      would be held for the rest of the session. }
    NoteFileDownloadState(AResp.Obj);
    Exit;
  end;
  ReleaseDownloadSlot(integer(AResp.Tag));
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
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(FVoiceByFile.Data[Idx].VoiceLocalPath, FVoiceByFile.Data[Idx].VoiceDownloadRequested);
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
  RequestFileDownload(ARow.DocFileId, @DownloadDocDone);
end;

procedure TTdMessages.DownloadDocDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyDocFile(AResp.Obj);
    { A file TDLib already had on disk comes back complete right here
      and never produces an updateFile — without this the slot it took
      would be held for the rest of the session. }
    NoteFileDownloadState(AResp.Obj);
    Exit;
  end;
  ReleaseDownloadSlot(integer(AResp.Tag));
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
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(FDocByFile.Data[Idx].DocLocalPath, FDocByFile.Data[Idx].DocDownloadRequested);
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
  RequestFileDownload(ARow.PhotoFileId, @DownloadPhotoDone);
end;

procedure TTdMessages.DownloadPhotoDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyPhotoFile(AResp.Obj);
    { A file TDLib already had on disk comes back complete right here
      and never produces an updateFile — without this the slot it took
      would be held for the rest of the session. }
    NoteFileDownloadState(AResp.Obj);
    Exit;
  end;
  ReleaseDownloadSlot(integer(AResp.Tag));
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
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(R.PhotoLocalPath, R.PhotoDownloadRequested);
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
  RequestFileDownload(ARow.PhotoBestFileId, @DownloadPhotoBestDone);
end;

procedure TTdMessages.DownloadPhotoBestDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyPhotoBestFile(AResp.Obj);
    { A file TDLib already had on disk comes back complete right here
      and never produces an updateFile — without this the slot it took
      would be held for the rest of the session. }
    NoteFileDownloadState(AResp.Obj);
    Exit;
  end;
  ReleaseDownloadSlot(integer(AResp.Tag));
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
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(FPhotoBestByFile.Data[Idx].PhotoBestLocalPath, FPhotoBestByFile.Data[Idx].PhotoBestDownloadRequested);
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
{ Takes a row out of every file_id -> row map.

  MUST be called before freeing a row that is not being freed as part
  of Clear (which empties the maps wholesale). The maps hold RAW
  POINTERS to rows, so a row freed while one of its files is still
  downloading leaves ten of them pointing at released memory, and the
  updateFile that arrives a moment later writes a path straight into
  it.

  Found through a sent GIF, which is what made the window reachable at
  all: sending goes pending row -> downloadFile -> answer, and
  updateMessageSendSucceeded frees that pending row IN BETWEEN. The
  file finished 236 ms after the row it belonged to had been freed
  (both timestamps out of tdlib_raw.log). The visible symptom was the
  mild one - the new row never learned the path, so the GIF neither
  played nor appeared to download - but the write itself was into
  freed memory and could have been anything.

  Incoming media was always exposed to the same thing through
  updateDeleteMessages; it just needs a message to be deleted while
  one of its files is in flight, which is rare enough never to have
  been seen. }
procedure TTdMessages.ForgetRowFiles(ARow: TMsgRow);

  { One parameter type for all ten: identical specializations of the
    same generic ARE the same type in FPC, so the aliases below are
    interchangeable here. }
  procedure Purge(AMap: TAudioFileMap);
  var
    I: integer;
  begin
    for I := AMap.Count - 1 downto 0 do begin
      if AMap.Data[I] = ARow then begin
        AMap.Delete(I);
      end;
    end;
  end;

begin
  if ARow = nil then begin
    Exit;
  end;
  Purge(FByFile);
  Purge(FAudioCoverByFile);
  Purge(FVoiceByFile);
  Purge(FDocByFile);
  Purge(FPhotoByFile);
  Purge(FPhotoBestByFile);
  Purge(FAnimByFile);
  Purge(FVideoByFile);
  Purge(FVideoThumbByFile);
  Purge(FStickerByFile);
end;

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
  RequestFileDownload(ARow.AnimFileId, @DownloadAnimDone);
end;

procedure TTdMessages.DownloadAnimDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyAnimFile(AResp.Obj);
    { A file TDLib already had on disk comes back complete right here
      and never produces an updateFile — without this the slot it took
      would be held for the rest of the session. }
    NoteFileDownloadState(AResp.Obj);
    Exit;
  end;
  ReleaseDownloadSlot(integer(AResp.Tag));
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
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(FAnimByFile.Data[Idx].AnimLocalPath, FAnimByFile.Data[Idx].AnimDownloadRequested);
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
  RequestFileDownload(ARow.VideoFileId, @DownloadVideoDone);
end;

procedure TTdMessages.DownloadVideoDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  if AResp.Success then begin
    ApplyVideoFile(AResp.Obj);
    { A file TDLib already had on disk comes back complete right here
      and never produces an updateFile — without this the slot it took
      would be held for the rest of the session. }
    NoteFileDownloadState(AResp.Obj);
    Exit;
  end;
  ReleaseDownloadSlot(integer(AResp.Tag));
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
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(R.VideoLocalPath, R.VideoDownloadRequested);
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
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(FVideoThumbByFile.Data[Idx].VideoThumbLocalPath, FVideoThumbByFile.Data[Idx].VideoThumbDownloadRequested);
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
    { Not "still downloading" only - it is also how a file that has
      been DELETED is reported. See ForgetFile. }
    ForgetFile(FStickerByFile.Data[Idx].StickerLocalPath, FStickerByFile.Data[Idx].StickerDownloadRequested);
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

procedure TTdMessages.EnsureCustomEmojiIds(const AIds: array of Int64);
var
  I, N: integer;
  Body: utf8string;
begin
  if FReq = nil then begin
    Exit;
  end;
  Body := '';
  N := 0;
  for I := 0 to High(AIds) do begin
    if (AIds[I] = 0) or CustomEmojiKnown(AIds[I]) or IsCustomEmojiPending(AIds[I]) then begin
      Continue;
    end;
    MarkCustomEmojiPending(AIds[I]);
    if N > 0 then begin
      Body := Body + ',';
    end;
    Body := Body + '"' + utf8string(IntToStr(AIds[I])) + '"';
    Inc(N);
  end;
  if N = 0 then begin
    Exit;
  end;
  FReq.SendRequest('getCustomEmojiStickers', '"custom_emoji_ids":[' + Body + ']',
    @GetCustomEmojiStickersDone);
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


function TTdMessages.InOpenThread(AMsg: TJSONObject): boolean;
var
  Topic: TJSONObject;
begin
  Result := True;
  if (FThreadId = 0) or (AMsg = nil) then begin
    Exit;
  end;
  if JGetInt64(AMsg, 'id') = FThreadId then begin
    Exit;
  end;
  Topic := JGetObj(AMsg, 'topic_id');
  Result := (JGetStr(Topic, '@type') = 'messageTopicThread')
    and (JGetInt64(Topic, 'message_thread_id') = FThreadId);
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
      { И не в ветку комментариев, если сообщение не из неё: в группе
        обсуждения идут комментарии ко всем постам канала сразу, а
        открыта ветка одного. Принадлежность — topic_id
        (messageTopicThread.message_thread_id, по живому tdlib_raw.log);
        сам корень ветки (копия поста) — по своему id. }
      if not SearchActive and InOpenThread(JGetObj(Obj, 'message')) then begin
        ApplyMessage(JGetObj(Obj, 'message'));
      end;
    end else if T = 'updateMessageContent' then begin
      ApplyContentUpdate(JGetInt64(Obj, 'chat_id'), JGetInt64(Obj, 'message_id'),
        JGetObj(Obj, 'new_content'));
    end else if T = 'updateFile' then begin
      ApplyAudioFile(JGetObj(Obj, 'file'));
      ApplyAudioCoverFile(JGetObj(Obj, 'file'));
      ApplyVoiceFile(JGetObj(Obj, 'file'));
      ApplyDocFile(JGetObj(Obj, 'file'));
      ApplyPhotoFile(JGetObj(Obj, 'file'));
      ApplyLinkFile(JGetObj(Obj, 'file'));
      ApplyPhotoBestFile(JGetObj(Obj, 'file'));
      ApplyAnimFile(JGetObj(Obj, 'file'));
      ApplyVideoFile(JGetObj(Obj, 'file'));
      ApplyVideoThumbFile(JGetObj(Obj, 'file'));
      ApplyStickerFile(JGetObj(Obj, 'file'));
      ApplyCustomEmojiFile(JGetObj(Obj, 'file'));
      { Last, after everyone has read the file: this is what lets the
        next queued download start (see RequestFileDownload). }
      NoteFileDownloadState(JGetObj(Obj, 'file'));
      { Кольцо — ПОСЛЕ слота: «в очереди ли файл» решает, идёт ли
        передача, а остановленный (отменён, сбой) освобождается как раз
        строкой выше. До неё кольцо застревало бы. }
      ApplyXferUpdate(JGetObj(Obj, 'file'));
    end else if T = 'updateMessageEdited' then begin
      if JGetInt64(Obj, 'chat_id') = FChatId then begin
        R := Lookup(JGetInt64(Obj, 'message_id'));
        if R <> nil then begin
          R.EditDate := JGetInt64(Obj, 'edit_date');
          { Боты меняют кнопки правкой (td_api.tl: updateMessageEdited
            несёт reply_markup). }
          if JGetObj(Obj, 'reply_markup') <> nil then begin
            R.ReplyMarkupRaw := utf8string(JGetObj(Obj, 'reply_markup').AsJSON);
          end else begin
            R.ReplyMarkupRaw := '';
          end;
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
          R.CanSeeReactors := JGetBool(JGetObj(JGetObj(Obj, 'interaction_info'), 'reactions'),
            'can_get_added_reactions');
          ExtractReplyInfo(JGetObj(Obj, 'interaction_info'), R);
          Touch;
        end;
      end;
    end else if T = 'updateMessageSendSucceeded' then begin
      { The temporary entry is replaced with the new one wholesale —
        simpler and more reliable than trying to reuse the same object
        under a different id. }
      OldId := JGetInt64(Obj, 'old_message_id');
      { Если сообщение несло файл со страницы — TDLib его закачал, и
        временная копия больше не нужна. }
      { Временный файл остаётся: он теперь локальная копия файла
        сообщения (см. SendFiles). }
      ForgetUploadMessage(OldId, False);
      if OldId <> 0 then begin
        if FReplaced.Count >= REPLACED_IDS_MAX then begin
          FReplaced.Delete(0);
        end;
        FReplaced.Add(OldId);
        Idx := FAll.IndexOf(OldId);
        if Idx >= 0 then begin
          ForgetRowFiles(FAll.Data[Idx]);
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
              ForgetRowFiles(FAll.Data[Idx]);
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

finalization
  FreeAndNil(GUploadByMsg);

end.
