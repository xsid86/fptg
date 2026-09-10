unit framehistory;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  { Windows comes first: units listed later in uses shadow its symbols
    for unqualified use (LCLIntf/LCLType declare some of the same-named
    GDI functions cross-platform) — Windows itself is needed here only
    for CreateRoundRectRgn/SelectClipRgn/DeleteObject
    (TPhotoWidget.DrawBmpRounded, SMOOTH_CORNERS=False branch —
    LCLIntf/LCLType don't have these at all, confirmed by reading the
    LCL sources, not guessed); all three calls are qualified (Windows.),
    but the uses order still matters for overload resolution. }
  Windows,
  Classes, SysUtils, Types, Math, DateUtils, LCLType, LCLIntf,
  Controls, constants, Forms, Graphics, Clipbrd, fgl, StdCtrls, ExtCtrls,
  Dialogs, Menus, ShellApi, BGRABitmap, BGRABitmapTypes, BGRAFilters, avatarcache,
  tdauth, tdcore, tdchats, tdmessages, tdusers, tdaccentcolors, msglayout,
  uiframe, framechats, audioplayer, videoplayer, photodecoder, mediaplayer,
  lottieplayer, customemoji, emojiassets;

type
  { TAudioWidget

    An audio message's UI: backing/outline the same way as the reply
    quote box (AUDIO_COLOR instead of the sender's color), a play/pause
    button (TFrameHistory's ImageList1, assigned via Images), the track
    title, a progress bar. This class draws the UI only — playback
    happens through the interface below (SetPlayback/OnPlayClick/OnSeek),
    with the actual decoding/output living in audioplayer.pas.
    Recycled control: lives in TMsgScroller's pool, Visible is toggled,
    the object itself isn't recreated on every scroll — but the TRACK
    data changes on every reuse for a different message, see SetTrack. }
  TAudioSeekEvent = procedure(Sender: TObject; AFraction: double) of object;

  TAudioWidget = class(TCustomControl)
  private
    FRowId: Int64;
    FTitle, FPerformer, FFileName: utf8string;
    FDuration: integer;
    FImages: TImageList;
    { Playback state — see SetPlayback/TMsgScroller.AudioPlayClick.
      FIsActive=False means this message isn't the one currently
      playing/paused (the ordinary state of most widgets). }
    FIsActive:    boolean;
    FPlaying:     boolean;
    FPositionSec: double;
    { Dragging the thumb — the preview is local (FDragFraction), the
      actual seek (TMsgScroller.AudioSeek — a new TAudioPlayer at that
      position) fires once on mouse release, not on every pixel of
      mouse movement: otherwise the decode thread/wave device would be
      recreated on every MouseMove, expensive and jittery. }
    FDraggingSeek: boolean;
    FDragFraction: double;
    FOnPlayClick: TNotifyEvent;
    FOnSeek: TAudioSeekEvent;
    { Background outside the rounded backing — see WidgetBackdropColor
      and the comment on TPhotoWidget.FBgColor, the same approach. }
    FBgColor: TColor;
    function PlayButtonRect: TRect;
    { Shared content geometry (right of the play button) — a single
      source of truth for both Paint AND the thumb hit test
      (TrackAreaRect/FractionFromX), so they can't drift apart on a
      later edit. Returns False if there's not enough room (see Paint). }
    function ContentGeometry(out AContentX, AContentW, AProgressTop: integer): boolean;
    function TrackAreaRect: TRect;
    function FractionFromX(AX: integer): double;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    { A specific message's data — called from LayoutAudioWidgets every
      time the widget is reused for a (possibly different) message, not
      only when created. Resets playback state (a pooled widget may
      have previously represented the active track) — the actual state
      is restored right after by SetPlayback, if the new ARowId happens
      to be the active track. }
    procedure SetTrack(ARowId: Int64; const ATitle, APerformer, AFileName: utf8string; ADuration: integer);
    procedure SetPlayback(AIsActive, APlaying: boolean; APositionSec: double);
    property Images: TImageList read FImages write FImages;
    property RowId: Int64 read FRowId;
    { A thumb drag is happening RIGHT NOW — LayoutAudioWidgets must skip
      SetPlayback for this pass, otherwise it would overwrite the local
      drag preview with the real (still stale) position on the very
      next Paint. }
    property Dragging: boolean read FDraggingSeek;
    property OnPlayClick: TNotifyEvent read FOnPlayClick write FOnPlayClick;
    property OnSeek: TAudioSeekEvent read FOnSeek write FOnSeek;
    property BackgroundColor: TColor read FBgColor write FBgColor;
  end;

  TAudioMap = specialize TFPGMap<Int64, TAudioWidget>;

  { TFileWidget

    A document-file widget — the same look as the finished TAudioWidget
    (backing/outline/rounding/padding, the same FILE_WIDGET_H=
    AUDIO_WIDGET_H), but without play/pause or a progress bar (a file
    has neither): an icon by file extension on the left (FileIconIndex,
    the FileTypes ImageList on TFrameHistory), the file name on the
    right (where audio's track title sits) and its size below (where
    audio's time sits). Cursor is a hand over the whole widget (not
    just over an icon like audio's play/pause button), a click anywhere
    saves the file. }
  TFileWidget = class(TCustomControl)
  private
    FRowId: Int64;
    FFileName: utf8string;
    FFileSize: Int64;
    FIconIndex: integer;
    FDownloaded: boolean;
    FImages: TImageList;         { FileTypes — icons by extension }
    FDownloadImages: TImageList; { ImageList1 — the "download" icon (AUDIO_ICON_DOWNLOAD) }
    FOnClick: TNotifyEvent;
    { Background outside the rounded backing — see WidgetBackdropColor
      and the comment on TPhotoWidget.FBgColor, the same approach. }
    FBgColor: TColor;
    function IconRect: TRect;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    { ADownloaded: the file already exists on disk (ARow.DocLocalPath<>'')
      — shows the mime-type icon; otherwise shows the "download" icon
      (AUDIO_ICON_DOWNLOAD). }
    procedure SetFile(ARowId: Int64; const AFileName: utf8string; AFileSize: Int64;
      ADownloaded: boolean);
    property Images: TImageList read FImages write FImages;
    property DownloadImages: TImageList read FDownloadImages write FDownloadImages;
    property RowId: Int64 read FRowId;
    { Left click: not downloaded — downloads silently (no dialog);
      downloaded — opens the file with the system's default application
      (see TMsgScroller.FileWidgetClick). The context menu (right
      click) isn't its own — it's a shared form component (see
      TMsgScroller.FilePopupMenu), which LCL shows itself via the
      inherited PopupMenu property. }
    property OnFileClick: TNotifyEvent read FOnClick write FOnClick;
    property BackgroundColor: TColor read FBgColor write FBgColor;
  end;

  { Not TFileMap — that name is already taken by tdchats.TFileMap
    (file_id -> TChatRow, for avatars), and framehistory imports
    tdchats. }
  TFileWidgetMap = specialize TFPGMap<Int64, TFileWidget>;

  { TPhotoWidget

    A photo preview. Unlike TAudioWidget/TFileWidget — NO backing/
    outline card: a photo preview needs no frame around it. Rounding
    and the gray outline that used to be here (PHOTO_CORNER_RADIUS/
    PHOTO_BORDER_COLOR) were removed entirely — the image itself is now
    drawn as-is, rectangular, see DrawBmpRounded (the name is a
    historical leftover). Interaction is the same as TFileWidget: a
    hand cursor over the whole widget, a left click downloads (silently
    if not yet downloaded) or opens the built-in viewer
    (mediaviewer.pas, if already downloaded); the context menu is the
    same shared FilePopupMenu.

    Until the file is downloaded, a blurred placeholder from
    content.photo.minithumbnail (a tiny JPEG, arriving directly in the
    content, no download needed) is shown, with a "download" icon over
    it (the same AUDIO_ICON_DOWNLOAD as TFileWidget). Both decoded
    bitmaps (the blur preview and the real photo) are cached in the
    widget itself — it's recycled (TMsgScroller's pool), and they're
    only recomputed when the widget is actually reused for a DIFFERENT
    message (see SetPhoto), not on every repaint. }
  TPhotoWidget = class(TCustomControl)
  private
    FRowId: Int64;
    FNaturalW, FNaturalH: integer;
    FTargetW, FTargetH: integer;
    FLocalPath: utf8string;
    FDownloaded: boolean;
    FBlurBmp: TBGRABitmap;   { blurred placeholder from minithumbnail, before download }
    FRealBmp: TBGRABitmap;   { the real photo, after download }
    FDownloadImages: TImageList; { ImageList1 — the "download" icon }
    { The message BLOCK's background color at this point
      (BlendWithBackground(SenderColor(R), SENDER_BG_OPACITY,
      clWindow) — the same formula that colors the block itself in
      TMsgScroller.Paint) — NOT bare clWindow: this widget, like
      TAudioWidget/TFileWidget, is a real child control and doesn't let
      the parent's canvas show through, and unlike audio/file, a photo
      has no opaque backing card over that background — without this
      substitution, the preview's corners outside the rounded mask
      would show plain clWindow white, visibly different from the
      block's tinted background ("white triangles in the corners"). }
    FBgColor: TColor;
    FOnClick: TNotifyEvent;
    { Decoding the real (not blur-placeholder) photo happens in a
      background thread, see photodecoder.pas and the comment on
      DecodeDone/SetPhoto. FDecodeThread <> nil means a decode for THIS
      widget is currently in progress; a stale decode that's become
      irrelevant (the widget was reused for a different
      message/path, or the widget itself is being destroyed) is ALWAYS
      explicitly canceled via Cancel BEFORE starting a new one/
      destroying the widget — DoDone for it then simply frees the
      result on its own, never touching this object's fields, so no
      separate "which path was this decode for" check is needed. }
    FDecodeThread: TPhotoDecodeThread;
    procedure ClearBitmaps;
    procedure DrawBmpRounded(ABmp: TBGRABitmap);
    procedure DecodeDone(Sender: TObject);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { AMinithumb is the raw (already base64-decoded) JPEG bytes, can be
      '' (not sent / no longer needed — already downloaded).
      ADownloaded/ALocalPath say whether the real file already exists
      on disk. AMaxW is the actual available column width at this
      point (see ComputePhotoPreviewSize) — without it, the preview
      could overflow the message card on narrow windows. }
    procedure SetPhoto(ARowId: Int64; ANaturalW, ANaturalH: integer;
      const AMinithumb: RawByteString; ADownloaded: boolean; const ALocalPath: utf8string;
      AMaxW: integer);
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    property DownloadImages: TImageList read FDownloadImages write FDownloadImages;
    property BackgroundColor: TColor read FBgColor write FBgColor;
    property RowId: Int64 read FRowId;
    property OnPhotoClick: TNotifyEvent read FOnClick write FOnClick;
  end;

  TPhotoWidgetMap = specialize TFPGMap<Int64, TPhotoWidget>;

  { TAnimationWidget

    A "GIF" (messageAnimation — physically a short MP4/H.264 with no
    sound) — the same interface as TPhotoWidget: a hand cursor over the
    whole widget, PHOTO_CORNER_RADIUS rounding, NO backing/outline
    card. Until downloaded, a blurred placeholder from
    content.animation.minithumbnail (the same decode pipeline as
    photos) is shown, with a "download" icon over it.

    Clicks work like a file: the first click on an undownloaded widget
    only downloads it, with NO auto-play; a second click on an
    already-downloaded, not-yet-playing widget starts looped playback.
    A click on an ALREADY-playing widget does nothing — there are no
    start/stop controls; a "GIF" either isn't playing or loops
    continuously for as long as the widget is alive and visible
    (framehistory.pas decides this through OnAnimClick/StartLoop/
    StopLoop).

    Live playback uses TAnimationPlayer (videoplayer.pas), a background
    decoder thread that loops on its own. EACH widget has its own
    independent thread and its own TTimer poll for new frames
    (PollTick), NOT shared with TMsgScroller.FPlaybackTimer (that one
    tracks the position of the ONE active audio player; any number of
    "GIFs" can loop on screen at once, there's no "only one at a time"
    restriction for video).

    Rounding is ALWAYS done through a cheap GDI region
    (CreateRoundRectRgn/SelectClipRgn, the same approach as
    TPhotoWidget's SMOOTH_CORNERS=False branch), REGARDLESS of the
    global SMOOTH_CORNERS — a deliberate exception among the other 13
    places in this file that round corners: a live video frame updates
    dozens of times a second for EACH simultaneously playing "GIF", and
    recomputing a BGRA mask (ApplyMask/RoundRectAntialias) on every such
    frame is a completely different order of CPU cost than the same
    operation on a static photo (which doesn't repaint in a continuous
    stream). Using DIFFERENT rounding methods for the placeholder and
    the live frame of the SAME widget is also undesirable — the border
    would visibly "flicker" the moment playback starts — so both states
    of the widget are painted with the same cheap method. }
  TAnimationWidget = class(TCustomControl)
  private
    FRowId: Int64;
    FNaturalW, FNaturalH: integer;
    FTargetW, FTargetH: integer;
    FLocalPath: utf8string;
    FDownloaded: boolean;
    FBlurBmp: TBGRABitmap;
    FDownloadImages: TImageList;
    FBgColor: TColor;
    FOnClick: TNotifyEvent;
    FPlayer: TAnimationPlayer;
    FPlaying: boolean;
    FFrameBuf: PByte;           { BGRA, FTargetW*FTargetH*4 bytes }
    FFrameKnownVersion: cardinal;
    FPollTimer: TTimer;
    procedure ClearBitmap;
    procedure PollTick(Sender: TObject);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { The same signature/role as TPhotoWidget.SetPhoto — AMinithumb can
      be '' (not sent / no longer needed), ADownloaded/ALocalPath say
      whether the real file already exists on disk, AMaxW is the
      actual available column width (see ComputePhotoPreviewSize).
      Does NOT start playback itself — only prepares the placeholder/
      "downloaded" state; starting is separate, via StartLoop
      (framehistory.pas decides when: a second click, or
      auto-play from settings). }
    procedure SetAnim(ARowId: Int64; ANaturalW, ANaturalH: integer;
      const AMinithumb: RawByteString; ADownloaded: boolean; const ALocalPath: utf8string;
      AMaxW: integer);
    procedure StartLoop;
    procedure StopLoop;
    property Playing: boolean read FPlaying;
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    property DownloadImages: TImageList read FDownloadImages write FDownloadImages;
    property BackgroundColor: TColor read FBgColor write FBgColor;
    property RowId: Int64 read FRowId;
    property Downloaded: boolean read FDownloaded;
    property LocalPath: utf8string read FLocalPath;
    property OnAnimClick: TNotifyEvent read FOnClick write FOnClick;
  end;

  TAnimationWidgetMap = specialize TFPGMap<Int64, TAnimationWidget>;

  { TVideoWidget

    A video message (messageVideo — real video with sound, unlike a
    "GIF"): sizing and the pre-download placeholder work like
    TPhotoWidget/TAnimationWidget (natural proportions, a "download"
    icon), but with a play/pause button in the center and a scrub bar
    at the bottom "exactly like the one on an audio file, with the same
    time display" (the same AUDIO_TRACK_H/AUDIO_THUMB_H/W/
    AUDIO_PLAYED_OPACITY/AUDIO_REMAIN_OPACITY/FormatAudioTime as
    TAudioWidget — not separately invented numbers).

    The placeholder before the first live frame appears is a sharp
    static frame from content.video.thumbnail (a 320x180 JPEG,
    downloaded unconditionally, see TTdMessages.EnsureVideoThumbFile),
    NOT a blur from the minithumbnail — that was removed since a real
    frame is now downloaded right away as soon as the row is shown,
    independent of the video's own auto-download settings; the window
    in which there's even anything to show instead of a blur became
    narrow enough that the blur is simply dropped, rather than adding
    conditional logic for "blur only if auto-download is off".

    Visibility: in the CHAT (FIsActive always False) — ALWAYS the same
    large centered PLAY icon, regardless of cursor position, the same
    approach as before. In the VIEWER (FIsActive always True, see the
    class comment below) — the center icon is removed entirely,
    play/pause moved into the transport-button row under the scrub bar
    (see PlaybackButtonRect/ControlsVisible): the bar/time/whole button
    row are shown ALWAYS while the video is NOT playing (paused/not yet
    started — the same case that used to show the lone center icon),
    and ONLY on hover (MouseEnter/MouseLeave, FHovering) while the video
    is actively playing — a clean picture, unobstructed, until the user
    explicitly hovers.

    Live playback uses TMediaPlayer (mediaplayer.pas), but NOT from
    here: inline playback in the chat was removed entirely — clicking
    the play button OR the frame itself opens the built-in viewer
    (mediaviewer.pas, TMsgScroller.VideoBodyClick), which holds its own,
    independent TMediaPlayer. Here, in the chat, the widget is just a
    clickable preview (the same role as TPhotoWidget): it has no player
    of its own, is never "active" (FIsActive always False, see
    SetPlayback in LayoutVideoWidgets), so the scrub bar/pause are never
    shown — only the fixed play icon. }
  { Repeat mode for the transport row's button: three states, in the
    order the button cycles through them (mediaviewer.pas,
    VideoWidgetRepeatClick): off -> repeat all (on reaching the end,
    advances to the next video in the chat, wrapping to the first after
    the last) -> repeat one (on reaching the end, replays the same
    file) -> off again. }
  TVideoRepeatMode = (vrmOff, vrmAll, vrmOne);

  TVideoWidget = class(TCustomControl)
  private
    FRowId: Int64;
    FNaturalW, FNaturalH: integer;
    FTargetW, FTargetH: integer;
    FLocalPath: utf8string;
    FDownloaded: boolean;
    FDuration: integer;
    FThumbBmp: TBGRABitmap;     { the sharp frame from content.video.thumbnail, shown until the first live frame arrives — see SetVideoCore }
    FFrameBuf: PByte;           { the latest live frame, BGRA, FTargetW*FTargetH*4 — also what's shown while paused }
    FHaveFrame: boolean;        { whether this widget has ever received a live frame }
    FDownloadImages: TImageList; { the "download" icon }
    FImages: TImageList;         { play/pause — the same ImageList1 as TAudioWidget }
    FBgColor: TColor;
    FHovering: boolean;
    { Playback state — see SetPlayback/UpdateFrame, the same principle
      as TAudioWidget.SetPlayback/FIsActive. }
    FIsActive:    boolean;
    FPlaying:     boolean;
    FPositionSec: double;
    FDraggingSeek: boolean;
    FDragFraction: double;
    FOnClick: TNotifyEvent;       { a click anywhere on an undownloaded widget — download }
    FOnPlayClick: TNotifyEvent;   { a click on the play/pause button (widget center in chat, transport row in the viewer) }
    FOnSeek: TAudioSeekEvent;
    { A click on an already-downloaded video, NOT on the play/pause
      button and NOT on the scrub bar — i.e. on the frame/preview
      itself. The chat's inline player never reacted to this (only
      play/pause) — added specifically for the viewer
      (mediaviewer.pas): "open bigger" needs to be a separate gesture
      from "play inline, small". }
    FOnBodyClick: TNotifyEvent;
    { The transport-button row under the scrub bar, viewer only (see
      the class comment and ControlsVisible below). Prev/next/repeat
      can't be decided by the widget itself (it doesn't know about
      neighboring messages or the repeat mode) — three new events on
      the owner (mediaviewer.pas), the same approach already used for
      OnPlayClick/OnSeek/OnBodyClick. Skip ±10s reuses the ALREADY
      existing OnSeek (the widget computes the target fraction from
      FPositionSec/FDuration itself, see SkipBy) — no new event was
      added for it. }
    FPlaybackImages: TImageList;
    FHasPrevVideo, FHasNextVideo: boolean;
    FRepeatMode: TVideoRepeatMode;
    FOnPrevClick, FOnNextClick, FOnRepeatClick: TNotifyEvent;
    function PlayButtonRect: TRect;
    function ContentGeometry(out AContentX, AContentW, AProgressTop: integer): boolean;
    function TrackAreaRect: TRect;
    function FractionFromX(AX: integer): double;
    { The top edge of the transport-button row — a shared source for
      both Paint (where to draw) and PlaybackButtonRect (where to hit
      test). }
    function ButtonsRowTop: integer;
    { The rectangle for button AIndex (0=prev,1=-10s,2=play/pause,
      3=repeat,4=+10s,5=next) — a row of 6 PLAYBACK_BTN_SIZE buttons,
      with a PLAYBACK_BTN_GAP gap, centered horizontally in ClientRect. }
    function PlaybackButtonRect(AIndex: integer): TRect;
    { Whether to show the transport row/bar/time RIGHT NOW — the same
      condition that decides this block's visibility in Paint (see its
      comment), factored out so MouseDown/MouseMove can never drift
      from what's actually drawn (no clicking an invisible button). }
    function ControlsVisible: boolean;
    { Seeks by ADeltaSec seconds from the current position (negative
      means backward), clamped to [0, FDuration] — through the already
      existing OnSeek (the same path as dragging the thumb), no new
      infrastructure was needed. }
    procedure SkipBy(ADeltaSec: double);
    procedure ClearBitmap;
    procedure SetVideoCore(ARowId: Int64; ANaturalW, ANaturalH: integer;
      const AThumbLocalPath: utf8string; ADownloaded: boolean; const ALocalPath: utf8string;
      ATargetW, ATargetH, ADuration: integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { The same signature/role as TAnimationWidget.SetAnim, plus
      ADuration (seconds, like AudioDuration) — needed by the widget
      for the time label on the scrub bar, even while the video isn't
      active. AThumbLocalPath is the path to the already-downloaded
      content.video.thumbnail (a 320x180 JPEG), '' while not yet
      downloaded (see TMsgRow.VideoThumbFileId and the class comment
      above about dropping the blur). }
    procedure SetVideo(ARowId: Int64; ANaturalW, ANaturalH: integer;
      const AThumbLocalPath: utf8string; ADownloaded: boolean; const ALocalPath: utf8string;
      AMaxW: integer; ADuration: integer);
    { The same as SetVideo, but with an EXPLICIT target size, not via
      ComputePhotoPreviewSize/AMaxW (which always clamps to
      PHOTO_MAX_WIDTH/HEIGHT, the small cap for an inline chat
      preview). Needed by the viewer (mediaviewer.pas) — there the
      video is shown LARGE, fit to the application window's size, not
      the size of a chat row. }
    procedure SetVideoSized(ARowId: Int64; ANaturalW, ANaturalH: integer;
      const AThumbLocalPath: utf8string; ADownloaded: boolean; const ALocalPath: utf8string;
      ATargetW, ATargetH, ADuration: integer);
    procedure SetPlayback(AIsActive, APlaying: boolean; APositionSec: double);
    { Marks that FrameBuf has just been updated (the player itself
      writes DIRECTLY into FrameBuf, see its comment — the caller calls
      TryGetFrame(Widget.FrameBuf, ...), and follows up with this if it
      returned True) and requests a repaint. In the chat, this widget
      has no player of its own and never reaches this at all (see the
      class header) — the method is only used by the viewer
      (mediaviewer.pas). }
    procedure NotifyNewFrame;
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    { A pointer to the widget's own frame buffer — the player's
      TryGetFrame writes directly here, no intermediate copy (the same
      size as TargetWidth*TargetHeight*4, valid until the widget is
      reused for a different size — see SetVideo). }
    property FrameBuf: PByte read FFrameBuf;
    property DownloadImages: TImageList read FDownloadImages write FDownloadImages;
    property Images: TImageList read FImages write FImages;
    property RowId: Int64 read FRowId;
    property Downloaded: boolean read FDownloaded;
    property LocalPath: utf8string read FLocalPath;
    property Dragging: boolean read FDraggingSeek;
    property BackgroundColor: TColor read FBgColor write FBgColor;
    property OnClick: TNotifyEvent read FOnClick write FOnClick;
    property OnPlayClick: TNotifyEvent read FOnPlayClick write FOnPlayClick;
    property OnSeek: TAudioSeekEvent read FOnSeek write FOnSeek;
    property OnBodyClick: TNotifyEvent read FOnBodyClick write FOnBodyClick;
    property PlaybackImages: TImageList read FPlaybackImages write FPlaybackImages;
    { Gray/colored variant of the row's prev/next buttons — the owner
      (mediaviewer.pas) knows about neighboring video messages itself,
      the widget doesn't. }
    property HasPrevVideo: boolean read FHasPrevVideo write FHasPrevVideo;
    property HasNextVideo: boolean read FHasNextVideo write FHasNextVideo;
    { The repeat button's state — deliberately NOT reset in
      SetVideoCore when switching to a different message (see its
      comment) — a sticky mode for the whole viewer session, as
      "repeat" should behave in an ordinary player, not a per-video
      setting. Three states (TVideoRepeatMode), was previously a simple
      on/off. }
    property RepeatMode: TVideoRepeatMode read FRepeatMode write FRepeatMode;
    property OnPrevClick: TNotifyEvent read FOnPrevClick write FOnPrevClick;
    property OnNextClick: TNotifyEvent read FOnNextClick write FOnNextClick;
    property OnRepeatClick: TNotifyEvent read FOnRepeatClick write FOnRepeatClick;
  end;

  TVideoWidgetMap = specialize TFPGMap<Int64, TVideoWidget>;

  { TStickerWidget

    A sticker (messageSticker) — three TDLib formats (see
    TStickerFormat, tdmessages.pas), each with its own decoder, but one
    shared look/interface: NO backing/outline/rounding (a sticker is
    already the right shape by itself — a transparent image/vector,
    needing neither masking nor framing, unlike photo/video/"GIF") and
    NO clicks at all — neither downloading nor starting the animation
    requires a user click (see MaybeAutoDownload/LayoutStickerWidgets,
    framehistory.pas): stickers behave like the official client —
    appearing and playing themselves immediately.

      sfTgs (Lottie/vector) uses TLottiePlayer (lottieplayer.pas, its
      own thread per widget, the same principle as TAnimationPlayer for
      a "GIF" — any number of stickers can be on screen at once, each
      with its own independent thread). The output format is
      ARGB32_Premultiplied (see rlottie.pas) — drawn via
      DrawPremultipliedArgbBuffer (GDI AlphaBlend, below), not
      DrawBgraBuffer: that one can't handle alpha, and stickers are
      almost always transparent.

      sfWebm (video, VP9) uses TAnimationPlayer, the same class and
      decoder as a "GIF" (videoplayer.pas) — the container doesn't
      matter to it, ffmpeg opens the file as ordinary video regardless
      of extension. Drawn via DrawBgraBuffer (an opaque blit, like a
      "GIF") — the VP9 alpha channel (WebM alpha extension) is NOT
      composited through this path (a known gap) — rare in practice
      (the only live example seen in tdlib_raw.log across the whole
      session was TGS), so this wasn't blocked on.

      sfWebp (static) uses TBGRABitmap.Create(path) once (the decoder
      is already part of BGRABitmapPack, see its own comment in
      rlottie.pas about libwebp64.dll), no thread needed — drawn via
      FStaticBmp.Draw, the same alpha compositing already used for
      FBlurBmp on photo/"GIF" in other widgets.

    Polling for a new frame (FPollTimer/PollTick) uses the same
    approach as TAnimationWidget, but is only needed for sfTgs/sfWebm
    (sfWebp has a single frame, nothing to poll). }
  TStickerWidget = class(TCustomControl)
  private
    FRowId: Int64;
    FFormat: TStickerFormat;
    FTargetW, FTargetH: integer;
    FLocalPath: utf8string;
    FBgColor: TColor;
    FPlaying: boolean;
    FLottiePlayer: TLottiePlayer;
    FAnimPlayer: TAnimationPlayer;
    FStaticBmp: TBGRABitmap;
    FFrameBuf: PByte;           { sfTgs — ARGB32_Premultiplied; sfWebm — BGRA; unused for sfWebp }
    FFrameKnownVersion: cardinal;
    { True only once at least one real frame has ALREADY been copied
      into FFrameBuf via TryGetFrame — GetMem does NOT zero memory:
      there's a window of a few milliseconds between StartLoop (the
      buffer is only just allocated) and the first successful PollTick,
      and LCL can easily call Paint within that window (right after
      SetBounds/Visible:=True in LayoutStickerWidgets, BEFORE the first
      tick of the 33ms timer) — without this check, Paint would draw
      garbage from still-uninitialized memory (caught by diagnostics: a
      real dump from the running application turned out to be pure
      noise, not a sticker). The same class of guard TVideoWidget
      already has (FHaveFrame) — set up separately here, since it
      wasn't checked when the pattern was ported from TAnimationWidget
      (which has no such guard at all — the same risk theoretically
      exists there too, not fixed in this pass — see TODO). }
    FHaveFrame: boolean;
    FPollTimer: TTimer;
    procedure ClearBitmaps;
    procedure PollTick(Sender: TObject);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { The same role as TAnimationWidget.SetAnim — prepares the
      "downloaded"/size state, does NOT start the animation itself (see
      StartLoop). }
    procedure SetSticker(ARowId: Int64; AFormat: TStickerFormat;
      ANaturalW, ANaturalH: integer; const ALocalPath: utf8string; AMaxW: integer);
    procedure StartLoop;
    procedure StopLoop;
    property Playing: boolean read FPlaying;
    property TargetWidth: integer read FTargetW;
    property TargetHeight: integer read FTargetH;
    property BackgroundColor: TColor read FBgColor write FBgColor;
    property RowId: Int64 read FRowId;
  end;

  TStickerWidgetMap = specialize TFPGMap<Int64, TStickerWidget>;

  { Key — the id of the user or source chat of a forward (see the field
    on TMsgScroller where two separate instances of this type are set
    up). }
  TForwardAvatarMap = specialize TFPGMap<Int64, TBGRABitmap>;

  { What to do with a document file as soon as it's downloaded —
    "Save as..."/"Show in folder" in the context menu on a not-yet-
    downloaded file first start the download (FPendingSaveMsgId), and
    the action runs afterward, see TMsgScroller.ModelChanged. A click
    on a photo preview has its own DIRECT logic (no deferred action)
    of "first click downloads, second opens" (see PhotoWidgetClick) —
    this enum doesn't apply there. }
  TPendingFileAction = (pfaNone, pfaSaveDialog, pfaShowInFolder);

  { One reaction's computed pill position, in the reaction strip's OWN
    local coordinate space (0,0 = the strip's content origin, i.e.
    AFTER the MSG_PAD_H inset from the block's edge — the same
    convention ForwardMetrics' AInnerW already uses). The single source
    of truth for both RebuildOffsets (how tall the strip needs to be,
    across however many wrapped rows) and PaintReactions (where to
    actually draw each pill) — see TMsgScroller.LayoutReactions, the
    same "compute the geometry once, use it twice" principle as
    ForwardMetrics/ContentRect elsewhere in this file. CountColor isn't
    stored: the count is always clWindowText now, chosen or not (only
    the pill's own fill opacity marks a reaction as mine — see
    CLAUDE.md, "там где есть мои реакции цвет текста тоже черный должен
    быть"). }
  TReactionSlot = record
    PillRect: TRect;
    IconW: integer;
  end;
  TReactionSlotArray = array of TReactionSlot;

  { TMsgScroller

    The heart of the chat frame: does its own virtual scrolling
    (position is FScrollTop, its range synced with the native
    TScrollBar in TFrameHistory via OnScrollRangeChanged/OnScroll — it
    no longer paints its own scrollbar), lays out and paints visible
    messages itself via msglayout.RendererFor, handles its own mouse
    hit testing (links, text selection), holds its own TAudioWidget
    pool. Message heights are cached on TMsgRow.LayoutCache — only
    what actually changed gets recomputed (see RebuildOffsets). }
  TMsgScroller = class(TCustomControl)
  private
    FModel:   TTdMessages;
    FOffsets: array of integer;   { length Count+1, cumulative height }
    { The message id at each FOffsets position — a snapshot from the
      SAME moment as FOffsets itself (filled in the same
      RebuildOffsets loop). Needed by ModelChanged: by the time it's
      called, FModel already reflects the NEW state (TTdMessages.Rebuild
      ran before FOnChanged), while FOffsets is still the OLD one. If
      the top visible row's anchor were read via FModel[index from the
      old FOffsets], after LoadOlder (which inserts messages AT THE
      START, shifting every other index) that would resolve to a
      random unrelated message's id — hence rows appearing to jump
      around. FRowIds is always the same vintage as FOffsets, so this
      mismatch can't happen. }
    FRowIds:  array of Int64;
    FTotalHeight: integer;
    FScrollTop:   integer;

    FSelAnchorMsg, FSelFocusMsg:   Int64;
    FSelAnchorChar, FSelFocusChar: integer;
    FSelecting: boolean;

    FAudioPool:   TFPList;   { of TAudioWidget, every one ever created }
    FAudioActive: TAudioMap; { currently positioned, by message id }
    { Play/pause icons for TAudioWidget — assigned by TFrameHistory
      right after FScroller is created (see its constructor), its own
      list on the form (not framechats.ImageList1 — that one is 16x16,
      this one 32x32). }
    FAudioImages: TImageList;
    { TVideoWidget's transport-button row (in the viewer) — only passed
      along to TMediaViewerPanel.ShowMessage, TMsgScroller itself never
      uses it (in the chat, the widget is never active, the row is
      never drawn, see TVideoWidget). }
    FPlaybackImages: TImageList;

    { The document-file widget — the same pool approach as audio. }
    FFilePool:   TFPList;       { of TFileWidget }
    FFileActive: TFileWidgetMap;
    FFileImages: TImageList;    { FileTypes on TFrameHistory }
    { The shared file context menu (right click) — a form component
      (TFrameHistory.FilePopupMenu, in the LFM, editable by the user in
      the designer), not created here: each TFileWidget gets a
      reference to it via the inherited PopupMenu property (LCL shows
      it itself on right click and sets PopupComponent to the clicked
      widget — the menu item handlers read it from there, see
      TFrameHistory.MenuItemFileSaveAsClick/
      MenuItemFileShowInFolderClick). }
    FFilePopupMenu: TPopupMenu;
    { A click on a not-yet-downloaded file in the context menu ("Save
      as..."/"Show in folder") — EnsureDocFile only requests the
      download; once the path arrives (ModelChanged/Touch), the needed
      action runs on its own (FPendingFileAction says which) — the same
      approach as FPendingPlayMsgId for audio. }
    FPendingSaveMsgId: Int64;
    FPendingFileAction: TPendingFileAction;

    { The photo preview — the same pool approach as audio/file; the
      shared FilePopupMenu/FAudioImages are reused, no separate
      icon-by-type list is needed (there's no "type" — just the photo
      itself). }
    FPhotoPool:   TFPList;       { of TPhotoWidget }
    FPhotoActive: TPhotoWidgetMap;
    { The same approach as FPendingSaveMsgId for files — its own pair
      of fields, not shared: different Kind, different Local fields on
      TMsgRow. }
    FPendingPhotoMsgId: Int64;
    FPendingPhotoAction: TPendingFileAction;

    { "GIFs" (messageAnimation) — the same recycled pool as
      photo/audio/file. Playback is NOT handled here (unlike audio,
      which has one active player for the whole scroller): each
      TAnimationWidget has its own independent TAnimationPlayer, any
      number of "GIFs" can loop at once — playback state lives in the
      widget itself (see TAnimationWidget.FPlayer), the scroller only
      needs the positioning pool. }
    FAnimPool:   TFPList;       { of TAnimationWidget }
    FAnimActive: TAnimationWidgetMap;

    { Stickers (messageSticker) — the same recycled-pool approach as
      "GIFs" (see FAnimPool/FAnimActive above): its own independent
      animation for each visible sticker, state lives in the
      TStickerWidget itself. Unlike a "GIF" — NO click involved:
      downloading (EnsureStickerFile) and starting the animation are
      both unconditional, see MaybeAutoDownload/LayoutStickerWidgets. }
    FStickerPool:   TFPList;       { of TStickerWidget }
    FStickerActive: TStickerWidgetMap;

    { Audio playback — one active player for the whole scroller (same
      as Telegram itself, at most one track plays at a time). The
      widget is a recycled pool (see FAudioActive/FAudioPool above),
      playback state lives HERE, not in the widget: it can scroll off
      screen while the message keeps playing.
      FDonePlayer is a player whose thread is finishing/finished
      (TAudioPlayer.State moved to apsStopped/apsError via
      PlayerStateChanged, called by the thread itself through
      Synchronize) — a TThread cannot be freed FROM INSIDE its own
      Synchronize callback (Free inside it could wait for the thread to
      finish — the very thread currently blocked inside Synchronize,
      waiting on us — deadlock); PlaybackTick frees it safely, from a
      different context (an ordinary timer call, not inside
      Synchronize). }
    FActivePlayer:      TAudioPlayer;
    FActivePlayerMsgId: Int64;
    FDonePlayer:        TAudioPlayer;
    { A click on play while the file isn't downloaded yet —
      EnsureAudioFile only requests the download; once the path arrives
      (ModelChanged/Touch), if it's still wanted (the user may have
      changed their mind / clicked a different track), playback starts
      automatically. }
    FPendingPlayMsgId:  Int64;
    FPlaybackTimer:     TTimer;

    { Video messages (messageVideo) — a recycled pool, the same
      approach as photo/audio/file/"GIF". Video is NO LONGER played
      inline at all — a click on the frame OR the play button (an
      already-downloaded video) opens the viewer (mediaviewer.pas, its
      own independent TMediaPlayer); here, in the chat, the widget is
      just a clickable preview, the same way as TPhotoWidget. There
      used to be "one active player for the whole scroller" (the same
      approach as audio) — all of that infrastructure
      (FActiveVideoPlayer/StartVideoPlayback/VideoSeek/
      VideoPlaybackTick, etc.) was removed entirely along with this
      change: without the click that used to start it, it would have
      been dead, unreachable code. }
    FVideoPool:   TFPList;       { of TVideoWidget }
    FVideoActive: TVideoWidgetMap;

    { Forward-source avatars — small (diameter HEADER_H), their own
      cache rather than avatarcache.TAvatarCache: that one is tailored
      to AVATAR_SIZE=44 and TChatRow (the chat list), while here both
      chats (mfoChat/mfoChannel, by ForwardChatId) and users (mfoUser,
      by ForwardUserId, for whom the project has no downloaded photos
      at all — only TChatRow has them) are needed. Separate maps: a
      user id and a chat id aren't the same namespace, and a value
      collision is possible. Key is the source's Id; values are freed
      in Destroy. }
    FForwardChatAvatars: TForwardAvatarMap;
    FForwardUserAvatars: TForwardAvatarMap;

    { Custom (Premium) emoji in text are canvas-drawn glyphs inside
      PaintRuns, not child widgets — there's no per-occurrence control to
      hang a poll timer off of, unlike TStickerWidget. One shared timer
      instead, same 33ms/30fps cadence as a sticker's own FPollTimer
      (tried 10fps first — visibly slower/choppier motion than intended,
      since sampling the live player only 10x/s discards most of the
      frames it actually renders; a whole-control Invalidate at 30fps is
      less surgical than one widget's own, but not a new cadence
      standard, just the same one already accepted for stickers). While
      customemoji.AnyLiveAnimating is true, it just calls Invalidate,
      same as any other repaint trigger — PaintRuns already re-reads
      whatever frame customemoji.pas currently has on every repaint. }
    FCustomEmojiTimer: TTimer;

    { Debounce timer for MarkVisibleAsRead — see its own comment and
      the constructor. }
    FMarkReadTimer: TTimer;

    FOnScrollRangeChanged: TNotifyEvent;
    FOnNearTop: TNotifyEvent;

    { A cache of "current chat's type -> AUTODL_CHAT_KINDS key" (see
      CurrentChatKind) — computed lazily and only recomputed when the
      chat changes (FChatKindChatId <> FModel.ChatId), not on every
      call: it's called from ClampScrollTop, the hottest spot in this
      file (mouse wheel/scrollbar drag), where TdChatList.Lookup+case
      wouldn't be free. FChatKindChatId=0 means not computed yet (0
      is never a real chat_id). }
    FChatKindChatId: Int64;
    FChatKindCache:  string;
    function CurrentChatKind: string;
    { Auto-download (FormMain.AutoDownloadEnabled) — if enabled for the
      pair (this message's media type, the current chat's type),
      requests the file AHEAD OF TIME (Ensure*File), the same call as
      a first click on the widget makes now, but without opening/
      playing — download only. Idempotent (like the Ensure* calls
      themselves), safe to call any number of times on the same row. }
    procedure MaybeAutoDownload(ARow: TMsgRow);
    { Runs once over the whole [FirstVisible..LastVisible] range —
      called from ModelChanged (opening a chat, new messages, history
      loaded further). }
    procedure AutoDownloadVisible;
    { Runs on every REAL scroll position change (see ClampScrollTop) —
      prefetches AUTODL_PREFETCH_MESSAGES messages ahead in the scroll
      direction (ADirection>0 is down/toward newer, <0 is up/toward
      older), so that by the time a message actually appears on
      screen, its download has been running for a while or already
      finished. This used to prefetch exactly ONE message ahead —
      widened to a whole window in response to a complaint about
      scroll stutter: the network isn't the only source of delay (see
      the related request for background-thread decoding,
      DecodeDone/photodecoder.pas) — but the network itself, when a
      file hasn't even been requested yet by the time its row appears
      on screen, adds its own delay too, and a wider window removes
      that as well. }
    procedure PrefetchAutoDownload(ADirection: integer);
    { Sends viewMessages (via TTdMessages.MarkRead) for the incoming
      (not IsOutgoing) messages currently in [FirstVisible..LastVisible]
      — "reading" a chat, the same thing every real Telegram client
      does. Only when Online: a no-op whenever FormMain.Invisible is
      set (see main.pas/TFormMain.Invisible) — that's the whole point
      of Invisible, this is the one place that would otherwise leak a
      read receipt. Stateless on purpose: no local "already sent"
      tracking, re-sending the same ids is cheap and TDLib itself is
      idempotent about it — matches what official clients do on every
      scroll settle, not just once. }
    procedure MarkVisibleAsRead;
    { FMarkReadTimer's OnTimer — debounces MarkVisibleAsRead so a fast
      wheel fling sends one viewMessages once scrolling actually stops
      instead of one per ClampScrollTop call. }
    procedure MarkReadTick(Sender: TObject);

    procedure AudioPlayClick(Sender: TObject);
    procedure AudioSeek(Sender: TObject; AFraction: double);
    procedure PlayerStateChanged(Sender: TObject);
    procedure PlaybackTick(Sender: TObject);
    { See FCustomEmojiTimer's comment above (fields section). }
    procedure CustomEmojiAnimTick(Sender: TObject);
    procedure FlushDonePlayer;
    procedure StopActivePlayer;
    procedure StartPlayback(ARow: TMsgRow; AStartPositionSec: double = 0);

    { Video (messageVideo) — NO inline playback at all (see the comment
      on FVideoPool): both a click on the play button (an already-
      downloaded video) and a click on the frame itself lead to the
      same VideoBodyClick — the viewer (mediaviewer.pas). Not yet
      downloaded — VideoPlayClick only requests the download
      (EnsureVideoFile), with no auto-start on completion — a repeat
      click, once the file is ready, opens the viewer, the same
      "strictly two clicks" principle as for photos (PhotoWidgetClick). }
    procedure VideoPlayClick(Sender: TObject);
    procedure VideoBodyClick(Sender: TObject);
    procedure LayoutVideoWidgets(ALo, AHi: integer);
    function ObtainVideoWidget: TVideoWidget;

    procedure RebuildOffsets;
    { The left/right bounds of the centered message column — no wider
      than MAX_MSG_W. A single source of truth for RebuildOffsets (text
      wrap width), BlockRect, and ContentRect — otherwise they'd drift
      apart at the slightest edit to one of them. }
    procedure ColumnBounds(out ALeft, ARight: integer);
    { A shared computation for a row with a forward — how much space
      before and after the content the quote takes up (the source's
      header+padding, WITHOUT the content's own height) and how much
      width remains for the content inside it. ARow=nil or not a
      forward: APreH/APostH are the same as without a quote (see the
      implementation), AInnerW=AAvailW unchanged. The single source of
      truth for both RebuildOffsets (row height) and ContentRect/
      ForwardCardRect/ForwardHeaderRect (where to draw), same as
      ColumnBounds. }
    { The ordinary vertical gap from the header/to the bottom edge is
      MSG_PAD_V, except for audio: both of those gaps there match its
      own inner padding (MSG_PAD_H) instead. A single source of truth
      for both ForwardMetrics AND ForwardCardRect — ForwardCardRect
      used to not know about this special case and always add
      MSG_PAD_V, making the audio widget's bottom padding inside a
      forward card narrower than its other three sides (6px instead of
      11px). }
    function ContentPadV(ARow: TMsgRow): integer;
    procedure ForwardMetrics(ARow: TMsgRow; AColW: integer;
      out APreH, APostH, AInnerW: integer);
    { The forward quote's whole frame (for fill/outline) and its own
      "avatar+name+time" row (for drawing and hit-testing a click on
      the name). }
    function ForwardCardRect(AIndex: integer): TRect;
    function ForwardHeaderRect(AIndex: integer): TRect;
    { Height of the reply quote (reply_to) box plus the gap to what
      follows it — 0 if the message has no reply_to. Added to PreH from
      ForwardMetrics (orthogonal properties, see the implementation). }
    function ReplyExtraH(ARow: TMsgRow): integer;
    function ReplyBoxRect(AIndex: integer): TRect;
    procedure PaintReplyBox(AIndex: integer; ARow: TMsgRow);
    { AOwned=True means the caller must free the result itself (a
      "not downloaded yet" snapshot, not cached, see the
      implementation); False means the result is in the cache and must
      not be freed. }
    function ForwardAvatarBmp(ARow: TMsgRow; out AOwned: boolean): TBGRABitmap;
    procedure ClearForwardAvatars;
    procedure PaintForwardCard(AIndex: integer; ARow: TMsgRow);
    function IndexAtY(AY: integer): integer;
    function FirstVisible: integer;
    function LastVisible: integer;
    function BlockRect(AIndex: integer): TRect;
    function ContentRect(AIndex: integer): TRect;
    { The reaction strip at the very bottom of the block — 0/an empty
      Rect when ARow has no reactions. See the comment on REACTION_GAP
      (constants.pas) for the design ("looks like the header"). }
    function ReactionsH(ARow: TMsgRow): integer;
    function ReactionsRect(AIndex: integer): TRect;
    { Wraps reactions onto multiple rows when they don't fit AWidth —
      the single source of truth for both ReactionsH (how tall the
      strip needs to be) and PaintReactions (where each pill actually
      goes), the same "compute once, use twice" principle as
      ForwardMetrics/ContentRect above. See the comment on TReactionSlot. }
    function LayoutReactions(ARow: TMsgRow; AWidth: integer;
      out ATotalH: integer): TReactionSlotArray;
    procedure PaintReactions(AIndex: integer; ARow: TMsgRow);
    procedure LayoutAudioWidgets(ALo, AHi: integer);
    function ObtainAudioWidget: TAudioWidget;
    procedure LayoutFileWidgets(ALo, AHi: integer);
    function ObtainFileWidget: TFileWidget;
    procedure FileWidgetClick(Sender: TObject);
    procedure SaveDocFile(ARow: TMsgRow);
    procedure LayoutPhotoWidgets(ALo, AHi: integer);
    function ObtainPhotoWidget: TPhotoWidget;
    procedure PhotoWidgetClick(Sender: TObject);
    procedure SavePhotoFile(ARow: TMsgRow);
    procedure LayoutAnimationWidgets(ALo, AHi: integer);
    function ObtainAnimationWidget: TAnimationWidget;
    procedure AnimationWidgetClick(Sender: TObject);
    procedure LayoutStickerWidgets(ALo, AHi: integer);
    function ObtainStickerWidget: TStickerWidget;
    function HitTestAt(X, Y: integer; out AIndex: integer): TMsgHit;
    function ResolveSelection(out ALowIdx, AHighIdx, ALowChar, AHighChar: integer): boolean;
    procedure RangeForRow(AIndex, ALowIdx, AHighIdx, ALowChar, AHighChar,
      ATextLen: integer; out ASelStart, ASelEnd: integer);
    procedure ClampScrollTop(AValue: integer);
    procedure SetScrollTop(AValue: integer);
    procedure DoLinkClick(const AUrl: utf8string);
    { A click on a forward quote's source (mfoChannel only — see the
      call site) — doesn't build a shareable link (getMessageLink
      requires membership in the chat, usually not the case for
      someone else's source), but navigates the same way the official
      client does: opens the source chat and scrolls to the message. }
    procedure OpenForwardSource(ARow: TMsgRow);
    { Scrolls to and shows a specific message — called from
      TFrameHistory in response to TTdMessages.OnJumpReady, once the
      needed batch of history has been applied and FOffsets/FRowIds
      reflect it. }
    procedure ScrollToMessage(AMessageId: Int64);
    procedure CopySelection;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: integer;
      MousePos: TPoint): boolean; override;
    procedure KeyDown(var Key: word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { AModel = nil detaches (switching accounts to an empty list). }
    procedure BindModel(AModel: TTdMessages);
    { The model sent OnChanged: recompute offsets, hold the scroll
      anchor (see the implementation — no jump while loading more
      history upward). }
    procedure ModelChanged;
    procedure ScrollToBottom;
    property ScrollTop: integer read FScrollTop write SetScrollTop;
    property TotalHeight: integer read FTotalHeight;
    property OnScrollRangeChanged: TNotifyEvent read FOnScrollRangeChanged write FOnScrollRangeChanged;
    property OnNearTop: TNotifyEvent read FOnNearTop write FOnNearTop;
    property AudioImages: TImageList read FAudioImages write FAudioImages;
    property PlaybackImages: TImageList read FPlaybackImages write FPlaybackImages;
    property FileImages: TImageList read FFileImages write FFileImages;
    property FilePopupMenu: TPopupMenu read FFilePopupMenu write FFilePopupMenu;
    { Handlers for TFrameHistory.FilePopupMenu's items — called from
      there (the LFM resolves OnClick only to methods of the owning
      form, not a dynamically created TMsgScroller), Sender is the
      TFileWidget itself, obtained via PopupMenu.PopupComponent. }
    procedure FileWidgetSaveAsClick(Sender: TObject);
    procedure FileWidgetShowInFolderClick(Sender: TObject);
    { The same two, for TPhotoWidget, the same shared FilePopupMenu. }
    procedure PhotoWidgetSaveAsClick(Sender: TObject);
    procedure PhotoWidgetShowInFolderClick(Sender: TObject);
  end;

  { TFrameHistory

    The chat history screen. Opened via OpenChat(chatId) — the caller
    (main.pas, a click on a chat) decides itself when to show it
    through the navigator. }
  TFrameHistory = class(TFrameBase, ITdActiveListener)
    ImageList1: TImageList;
    FileTypes: TImageList;
    Actions16: TImageList;
    FilePopupMenu: TPopupMenu;
    ImageList2: TImageList;
    playback: TImageList;
    MenuItemFileSaveAs: TMenuItem;
    MenuItemFileShowInFolder: TMenuItem;
    { FilePopupMenu's items (LFM, editable in the designer) — the LFM
      resolves OnClick only to methods of the owning form, so the
      handlers live here, not on TMsgScroller (which is created in
      code, not a form component); they simply forward the call to
      FScroller, taking the source TFileWidget from
      PopupMenu.PopupComponent — the same component shown by a right
      click on that exact widget. }
    procedure MenuItemFileSaveAsClick(Sender: TObject);
    procedure MenuItemFileShowInFolderClick(Sender: TObject);
  private
    FReady: boolean;
    FModel: TTdMessages;
    { The name cache isn't "this frame's model" in the same sense as
      FModel (one open chat's history): it's one per account, survives
      a chat switch, so it gets its own lightweight binding inside
      BindModel/UnbindModel rather than a full Bind/Unbind like FModel. }
    FUsers: TTdUsers;
    { Same principle as FUsers — one per account, a lightweight
      binding, no offsets. }
    FAccentColors: TTdAccentColors;
    FScroller:  TMsgScroller;
    FScrollbar: TScrollBar;
    pnlStatus:  TPanel;
    lblStatus:  TLabel;
    procedure BindModel;
    procedure UnbindModel;
    procedure ModelChanged(Sender: TObject);
    procedure LoadingChanged(Sender: TObject);
    { The name cache/sender avatar got a getUser response — just
      repaint: the block's height doesn't change when a name resolves,
      so a full offset rebuild isn't needed. }
    procedure UsersChanged(Sender: TObject);
    procedure ActionError(Sender: TObject; ACode: integer;
      const AMessage, AAction: utf8string);
    { The needed batch of history around AMessageId has been applied
      (TTdMessages.JumpTo/JumpDone) — following a forward quote: scroll
      to it. }
    procedure JumpReady(Sender: TObject; AMessageId: Int64);
    procedure ScrollerRangeChanged(Sender: TObject);
    procedure ScrollerNearTop(Sender: TObject);
    procedure ScrollbarScroll(Sender: TObject; ScrollCode: TScrollCode; var ScrollPos: integer);
    procedure MaybeLoadMore;
  protected
    procedure Resize; override;
    procedure DoActivate; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;

    { AJumpToMessageId <> 0 means following a forward quote, see
      TTdMessages.OpenChat/JumpTo. }
    procedure OpenChat(AChatId: Int64; AJumpToMessageId: Int64 = 0);

    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;

    { The model of the CURRENTLY open chat — nil if no chat has been
      opened yet. Needed by main.pas (the message input panel,
      msginput.pas): that panel knows nothing about TTdMessages itself,
      sending is resolved by the owner — see the comment on
      TMessageInputPanel. }
    property Model: TTdMessages read FModel;
  end;

implementation

{ main is used in the implementation section, not the interface: main
  itself uses framehistory (the work-area navigator), and using it from
  the interface would create a cycle — the same approach as main/login
  (see main.pas). Needed only for FormMain.Chats.ImageList1 (message
  status icons). }
uses
  main;

{$R *.lfm}

{ A color chosen deterministically from an id — the shared resolver for
  a message's sender (SenderColor), a forward's source
  (ForwardSourceColor), and a reply_to quote's sender (ReplySenderColor):
  three structurally identical cases of "color someone by id", factored
  into one place. Exactly one of AUserId/AChatId is expected to be
  nonzero (as everywhere in the project — a sender is either a user or
  a chat, never both); if both are zero (e.g. mfoHiddenUser), Id=1 is
  used, just so it isn't always the same palette slot. AChatId can be
  negative for channels/supergroups (confirmed from tdlib_raw.log) —
  Abs keeps it from indexing out of the array's bounds. }
function ResolveAccentColor(AUserId, AChatId: Int64): TColor;
var
  Id: Int64;
  AccId: integer;
  C: TChatRow;
  L: TTdChats;
  AC: TTdAccentColors;
begin
  { Telegram already has its own color tied to a contact/chat
    (accent_color_id, from updateUser/updateChatAccentColors — see
    tdaccentcolors.pas) — used in place of a hash by id, when known.
    The SENDER_PALETTE hash remains the fallback: while accent_color_id
    hasn't resolved yet (a new sender's first paint) or for the
    unexpected case where no source provides one at all. }
  AccId := -1;
  if AUserId <> 0 then begin
    if TdUserList <> nil then begin
      AccId := TdUserList.AccentColorId(AUserId);
    end;
  end else if AChatId <> 0 then begin
    L := TdChatList;
    if L <> nil then begin
      C := L.Lookup(AChatId);
      if C <> nil then begin
        AccId := C.AccentColorId;
      end;
    end;
  end;

  if AccId >= 0 then begin
    AC := TdAccentColorList;
    if (AC <> nil) and AC.TryGetColor(AccId, Result) then begin
      Exit;
    end;
  end;

  if AUserId <> 0 then begin
    Id := AUserId;
  end else begin
    Id := AChatId;
  end;
  if Id = 0 then begin
    Id := 1;
  end;
  Result := SENDER_PALETTE[Abs(Id) mod Length(SENDER_PALETTE)];
end;

function SenderColor(ARow: TMsgRow): TColor;
begin
  Result := ResolveAccentColor(ARow.SenderUserId, ARow.SenderChatId);
end;

{ Blends AColor with ABackground by AOpacity (0..1) — the message
  block's backing, "the sender's color, muted, over the background",
  without real alpha compositing (BGRABitmap) — that would be overkill
  for a solid rectangle fill, and Paint fires on every scroll tick.
  ColorToRGB expands system colors (e.g. clWindow) into real RGB —
  without this, blending a pseudo-color would produce garbage. }
function BlendWithBackground(AColor: TColor; AOpacity: double; ABackground: TColor): TColor;
var
  Fg, Bg: longint;
begin
  Fg := ColorToRGB(AColor);
  Bg := ColorToRGB(ABackground);
  Result := RGBToColor(
    Round((Bg and $FF) + AOpacity * ((Fg and $FF) - (Bg and $FF))),
    Round(((Bg shr 8) and $FF) + AOpacity * (((Fg shr 8) and $FF) - ((Bg shr 8) and $FF))),
    Round(((Bg shr 16) and $FF) + AOpacity * (((Fg shr 16) and $FF) - ((Bg shr 16) and $FF)))
  );
end;

{ A single antialiased replacement for GDI Canvas.RoundRect, used for
  EVERY rounded fill/outline in this file (message block, forward
  card, reply quote box, audio/file widget). Draws into a temporary
  transparent BGRA bitmap sized exactly to ABox and composites it onto
  ACanvas with alpha blending (Draw ... False) — whatever is outside
  the rounded shape stays whatever was already on the canvas, nothing
  extra is overwritten.

  AFillColor/ABorderColor = clNone skips the corresponding pass (fill
  only, outline only, or both if both are given). The radius (ARadius)
  is used AS GIVEN — no caller changed a single number when switching
  to this function, only the drawing method changed.

  Three rounds of fixes on TPhotoWidget.DrawBmpRounded (a white gap in
  the corner -> a clipped outline -> a blurry outline) all boiled down
  to one fact: FillRoundRectAntialias/RoundRectAntialias, by default
  (APixelCenteredCoordinates=True, confirmed by reading the BGRABitmap
  source, not guessed), treat an integer coordinate N as the CENTER of
  pixel N, not the boundary between pixels N-1 and N as GDI does. Hence
  the two corrections below, correct from the start, without repeating
  that same trial-and-error path: -0.5 for the fill (its edge must fall
  exactly between "pixel still exists" and "pixel no longer exists")
  and AWidth-ABorderWidth/2-0.5 for the outline's far edge (the line
  itself is centered on its path, ABorderWidth thick — its entire
  extent must stay inside the bitmap). }
procedure PaintRoundRectAA(ACanvas: TCanvas; const ABox: TRect; ARadius: single;
  AOptions: TRoundRectangleOptions; AFillColor, ABorderColor: TColor;
  ABorderWidth: single = 1; AForceSmooth: boolean = False);
var
  W, H, IRadius: integer;
  Bmp: TBGRABitmap;
  Half: single;
begin
  W := ABox.Right - ABox.Left;
  H := ABox.Bottom - ABox.Top;
  if (W <= 0) or (H <= 0) then begin
    Exit;
  end;

  { AForceSmooth (default False, every pre-existing call site unchanged)
    opts a specific caller INTO the antialiased BGRA path below even
    while SMOOTH_CORNERS=False globally — used only by PaintReactions:
    plain GDI RoundRect (the branch this skips into) has no
    antialiasing at all, and at the reaction pill's small radius
    (REACTION_PILL_CORNER_RADIUS) that reads as a visibly jagged,
    not-actually-round curve, reported directly ("не круглые, а
    вытянутые" / "not round, but elongated" — an aliasing artifact, not
    a geometry bug: the ellipse itself IS circular, GDI just can't draw
    it smoothly at this size). Paying the BGRA cost here specifically
    is cheap in aggregate: PaintReactions is a no-op for the vast
    majority of rows (most messages have no reactions at all), unlike
    the message block/header/forward-card corners this same function
    also draws on EVERY row, which is what SMOOTH_CORNERS=False was
    introduced to keep cheap in the first place (see its own comment). }
  if not SMOOTH_CORNERS and not AForceSmooth then begin
    { The older method, from before the switch to BGRA — plain GDI
      Canvas.RoundRect, no TBGRABitmap at all. This branch exists to
      test whether antialiased drawing itself (allocating and filling a
      temporary bitmap on every call, up to 12 per frame in the worst
      case) is actually noticeable in scroll smoothness, not just
      subjectively "looks smoother".
      GDI RoundRect can't do per-corner rounding — the only two AOptions
      combinations actually used in this file are [rrBottomLeftSquare,
      rrBottomRightSquare] (squaring off the bottom of a mini-header)
      and its mirror, [rrTopLeftSquare, rrTopRightSquare] (squaring off
      the TOP of the reaction strip — PaintReactions — which sits flush
      against the block's own rounded bottom edge instead), and every
      call site that requests either one never passes a border
      (ABorderColor=clNone) — using the same older trick of "draw all 4
      corners rounded, then square off one side with a separate
      FillRect" that predates the switch to BGRA. No other AOptions
      combination occurs in this file — this isn't generalized beyond
      what's actually needed. }
    IRadius := Round(ARadius);
    ACanvas.Pen.Style := psClear;
    if ABorderColor <> clNone then begin
      ACanvas.Pen.Style := psSolid;
      ACanvas.Pen.Color := ABorderColor;
      ACanvas.Pen.Width := Round(ABorderWidth);
    end;
    if AFillColor <> clNone then begin
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Brush.Color := AFillColor;
    end else begin
      ACanvas.Brush.Style := bsClear;
    end;
    ACanvas.RoundRect(ABox.Left, ABox.Top, ABox.Right, ABox.Bottom, IRadius * 2, IRadius * 2);
    if AFillColor <> clNone then begin
      ACanvas.Pen.Style := psClear;
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Brush.Color := AFillColor;
      if (rrBottomLeftSquare in AOptions) and (rrBottomRightSquare in AOptions) then begin
        ACanvas.FillRect(Rect(ABox.Left, ABox.Bottom - IRadius, ABox.Right, ABox.Bottom));
      end;
      if (rrTopLeftSquare in AOptions) and (rrTopRightSquare in AOptions) then begin
        ACanvas.FillRect(Rect(ABox.Left, ABox.Top, ABox.Right, ABox.Top + IRadius));
      end;
    end;
    Exit;
  end;

  Bmp := TBGRABitmap.Create(W, H, BGRAPixelTransparent);
  try
    if AFillColor <> clNone then begin
      Bmp.FillRoundRectAntialias(-0.5, -0.5, W - 0.5, H - 0.5, ARadius, ARadius,
        ColorToBGRA(AFillColor), AOptions);
    end;
    if ABorderColor <> clNone then begin
      Half := ABorderWidth / 2;
      Bmp.RoundRectAntialias(Half - 0.5, Half - 0.5, W - Half - 0.5, H - Half - 0.5,
        ARadius, ARadius, ColorToBGRA(ABorderColor), ABorderWidth, AOptions);
    end;
    Bmp.Draw(ACanvas, ABox.Left, ABox.Top, False);
  finally
    Bmp.Free;
  end;
end;

{ Truncates S to AMaxW pixels wide (using the font already set on
  ACanvas), appending "…" — used by both the reply quote and the audio
  widget, both single-line, no word-wrap. }
function TruncateToWidth(ACanvas: TCanvas; const S: string; AMaxW: integer): string;
var
  Lo, Hi, Mid: integer;
begin
  Result := S;
  if ACanvas.TextWidth(Result) <= AMaxW then begin
    Exit;
  end;
  Lo := 0;
  Hi := Length(S);
  while Lo < Hi do begin
    Mid := (Lo + Hi + 1) div 2;
    if ACanvas.TextWidth(Copy(S, 1, Mid) + '…') <= AMaxW then begin
      Lo := Mid;
    end else begin
      Hi := Mid - 1;
    end;
  end;
  if Lo <= 0 then begin
    Result := '…';
  end else begin
    Result := Copy(S, 1, Lo) + '…';
  end;
end;

{ HH:MM:SS, with a leading "-" for negative values (a track's remaining time). }
function FormatAudioTime(ASeconds: integer): string;
var
  H, M, S: integer;
  Neg: boolean;
begin
  Neg := ASeconds < 0;
  if Neg then begin
    ASeconds := -ASeconds;
  end;
  H := ASeconds div 3600;
  M := (ASeconds mod 3600) div 60;
  S := ASeconds mod 60;
  Result := Format('%.2d:%.2d:%.2d', [H, M, S]);
  if Neg then begin
    Result := '-' + Result;
  end;
end;

{ A name by id — a shared resolver, the same approach as
  ResolveAccentColor (a message's sender / a forward's source / a
  reply_to quote's sender). AChatId (an anonymous admin/post on behalf
  of a channel) is resolved through the already-loaded chat list, not
  TTdUsers — it isn't a user. }
function ResolveDisplayName(AUserId, AChatId: Int64): utf8string;
var
  C: TChatRow;
  U: TTdUsers;
  L: TTdChats;
begin
  Result := '';
  if AUserId <> 0 then begin
    U := TdUserList;
    if U <> nil then begin
      Result := U.DisplayName(AUserId);
    end;
  end else if AChatId <> 0 then begin
    L := TdChatList;
    C := nil;
    if L <> nil then begin
      C := L.Lookup(AChatId);
    end;
    if C <> nil then begin
      Result := C.Title;
    end else begin
      Result := 'Channel';
    end;
  end;
end;

function SenderDisplayName(ARow: TMsgRow): utf8string;
begin
  Result := ResolveDisplayName(ARow.SenderUserId, ARow.SenderChatId);
end;

{ Frame index in ImageList1 (framechats.pas) for an outgoing message's
  status icon; -1 means don't draw one (crNone, incoming). }
function ReceiptIconIndex(AKind: TChatReceipt): integer;
begin
  case AKind of
    crSent:    Result := ICON_MSG_SENT;
    crRead:    Result := ICON_MSG_READ;
    crPending: Result := ICON_MSG_PENDING;
    crFailed:  Result := ICON_MSG_FAILED;
  else
    Result := -1;
  end;
end;

{ The display name of a forward's source. mfoChannel/mfoChat are
  resolved through the already-loaded chat list (ForwardChatId) — the
  same approach as SenderDisplayName for anonymous posts from a chat.
  mfoUser goes through the user cache. mfoHiddenUser: TDLib sends a
  ready-made name and nothing else (the sender chose to hide where the
  forward came from). }
function ForwardSourceName(ARow: TMsgRow): utf8string;
var
  C: TChatRow;
  L: TTdChats;
  U: TTdUsers;
begin
  Result := '';
  case ARow.ForwardKind of
    mfoUser: begin
      U := TdUserList;
      if U <> nil then begin
        Result := U.DisplayName(ARow.ForwardUserId);
      end;
    end;
    mfoChat, mfoChannel: begin
      L := TdChatList;
      C := nil;
      if L <> nil then begin
        C := L.Lookup(ARow.ForwardChatId);
      end;
      if C <> nil then begin
        Result := C.Title;
      end else if ARow.ForwardSenderName <> '' then begin
        Result := ARow.ForwardSenderName;
      end else begin
        Result := 'Channel';
      end;
    end;
    mfoHiddenUser: begin
      Result := ARow.ForwardSenderName;
    end;
  end;
  if Result = '' then begin
    Result := 'Unknown';
  end;
end;

{ A forward's source color — the same approach as SenderColor (a real
  accent_color_id, a SENDER_PALETTE hash as fallback), but keyed by
  ForwardUserId/ForwardChatId rather than the message's own sender:
  these are two separately colored parts of one block — who sent the
  forward (the outer header) and where it originally came from (the
  quote). }
function ForwardSourceColor(ARow: TMsgRow): TColor;
var
  Id: Int64;
  AccId: integer;
  C: TChatRow;
  L: TTdChats;
  AC: TTdAccentColors;
begin
  AccId := -1;
  Id := 0;
  case ARow.ForwardKind of
    mfoUser: begin
      Id := ARow.ForwardUserId;
      if TdUserList <> nil then begin
        AccId := TdUserList.AccentColorId(Id);
      end;
    end;
    mfoChat, mfoChannel: begin
      Id := ARow.ForwardChatId;
      L := TdChatList;
      if L <> nil then begin
        C := L.Lookup(Id);
        if C <> nil then begin
          AccId := C.AccentColorId;
        end;
      end;
    end;
  end;

  if AccId >= 0 then begin
    AC := TdAccentColorList;
    if (AC <> nil) and AC.TryGetColor(AccId, Result) then begin
      Exit;
    end;
  end;

  if Id = 0 then begin
    { mfoHiddenUser (and any other case with no numeric id) — a stable
      but arbitrary fallback color: it just must not be 0, otherwise
      it's always the same palette slot for everyone. }
    Id := 1;
  end;
  Result := SENDER_PALETTE[Abs(Id) mod Length(SENDER_PALETTE)];
end;

{ The background color UNDER a rounded widget (audio/file/photo) at
  this point — for their own BackgroundColor: real child controls
  don't let the parent's canvas show through (see the comment on
  TPhotoWidget), and without this substitution, their corners OUTSIDE
  the rounded fill/mask would show plain clWindow white — visibly
  different from what's actually drawn there.

  This formula (BlendWithBackground(SenderColor(R), SENDER_BG_OPACITY,
  clWindow)) used to belong only to TPhotoWidget and always took the
  OUTER block's color — correct for a photo not inside a forward, but
  INSIDE a forward the widget sits on the quote card's own backing
  (its own, independent color — ForwardSourceColor, not SenderColor),
  not the block's — this wasn't accounted for anywhere, including
  LayoutPhotoWidgets: a widget's corner inside a forward was tinted
  with the block's color instead of the card it actually sits in. This
  was caught on the audio widget (white corners inside a colored
  forward card) — the same class of bug as the "white triangles" on
  photos, except TAudioWidget/TFileWidget had no BackgroundColor at
  all: it was assumed their own opaque card covered everything to the
  edge — wrong, a rounded card by definition doesn't reach the edge,
  its corners are rounded, not filled. }
function WidgetBackdropColor(ARow: TMsgRow): TColor;
begin
  if ARow.ForwardKind <> mfoNone then begin
    Result := BlendWithBackground(ForwardSourceColor(ARow), SENDER_BG_OPACITY, clWindow);
  end else begin
    Result := BlendWithBackground(SenderColor(ARow), SENDER_BG_OPACITY, clWindow);
  end;
end;

{ ---------------- TAudioWidget ---------------- }

constructor TAudioWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  FBgColor := clWindow;   { fallback until the first LayoutAudioWidgets }
end;

procedure TAudioWidget.SetTrack(ARowId: Int64; const ATitle, APerformer, AFileName: utf8string; ADuration: integer);
begin
  if ARowId <> FRowId then begin
    { The pooled widget was reused for a DIFFERENT message — the old
      playback/dragging state belongs to a different track, reset it.
      If ARowId is the same (an ordinary repeat pass of
      LayoutAudioWidgets — called on EVERY Paint of the scroller,
      including every tick of the progress timer), the state is NOT
      touched: that's exactly what used to break thumb dragging and
      clicking the bar — the very next Paint (a fraction of a second
      later) would snap FDraggingSeek/position back to zero right
      under the cursor. }
    FIsActive := False;
    FPlaying := False;
    FPositionSec := 0;
    FDraggingSeek := False;
  end;
  FRowId := ARowId;
  FTitle := ATitle;
  FPerformer := APerformer;
  FFileName := AFileName;
  FDuration := ADuration;
  Invalidate;
end;

procedure TAudioWidget.SetPlayback(AIsActive, APlaying: boolean; APositionSec: double);
begin
  FIsActive := AIsActive;
  FPlaying := APlaying;
  FPositionSec := APositionSec;
  Invalidate;
end;

function TAudioWidget.PlayButtonRect: TRect;
var
  Box: TRect;
begin
  Box := ClientRect;
  Result := Rect(Box.Left + MSG_PAD_H, (Box.Top + Box.Bottom - AUDIO_BUTTON_SIZE) div 2,
    Box.Left + MSG_PAD_H + AUDIO_BUTTON_SIZE, (Box.Top + Box.Bottom + AUDIO_BUTTON_SIZE) div 2);
end;

function TAudioWidget.ContentGeometry(out AContentX, AContentW, AProgressTop: integer): boolean;
var
  Box, PlayRect: TRect;
begin
  Box := ClientRect;
  PlayRect := PlayButtonRect;
  AContentX := PlayRect.Right + MSG_PAD_H;
  AContentW := Box.Right - MSG_PAD_H - AContentX;
  AProgressTop := Box.Top + MSG_PAD_H + REPLY_LINE_H + HEADER_PAD_V;
  Result := AContentW >= 10;
end;

function TAudioWidget.TrackAreaRect: TRect;
var
  CX, CW, PT: integer;
begin
  if not ContentGeometry(CX, CW, PT) then begin
    Result := Rect(0, 0, 0, 0);
    Exit;
  end;
  { The hit area extends above and below the visual bar/thumb — makes
    it easier to hit with the mouse, since the thumb itself is only
    AUDIO_THUMB_H pixels. }
  Result := Rect(CX, PT - 4, CX + CW, PT + AUDIO_THUMB_H + 4);
end;

function TAudioWidget.FractionFromX(AX: integer): double;
var
  CX, CW, PT: integer;
begin
  Result := 0;
  if not ContentGeometry(CX, CW, PT) or (CW <= 0) then begin
    Exit;
  end;
  Result := (AX - CX) / CW;
  if Result < 0 then Result := 0;
  if Result > 1 then Result := 1;
end;

procedure TAudioWidget.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then begin
    Exit;
  end;
  if PtInRect(PlayButtonRect, Point(X, Y)) then begin
    if Assigned(FOnPlayClick) then begin
      FOnPlayClick(Self);
    end;
    Exit;
  end;
  { Seeking is only for the active (playing/paused) track — for the
    rest, the thumb is always at the start, there's nothing to drag. }
  if FIsActive and PtInRect(TrackAreaRect, Point(X, Y)) then begin
    FDraggingSeek := True;
    FDragFraction := FractionFromX(X);
    Invalidate;
  end;
end;

procedure TAudioWidget.MouseMove(Shift: TShiftState; X, Y: integer);
begin
  inherited MouseMove(Shift, X, Y);
  if FDraggingSeek then begin
    FDragFraction := FractionFromX(X);
    Invalidate;
    Exit;
  end;
  if PtInRect(PlayButtonRect, Point(X, Y)) or
     (FIsActive and PtInRect(TrackAreaRect, Point(X, Y))) then begin
    Cursor := crHandPoint;
  end else begin
    Cursor := crDefault;
  end;
end;

procedure TAudioWidget.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDraggingSeek and (Button = mbLeft) then begin
    FDraggingSeek := False;
    if Assigned(FOnSeek) then begin
      FOnSeek(Self, FDragFraction);
    end;
    Invalidate;
  end;
end;

procedure TAudioWidget.Paint;
var
  Box, PlayRect, TrackRect, ThumbRect, PlayedRect: TRect;
  Radius, ContentX, ContentW, ProgressTop, PlayedW, IconIdx: integer;
  TitleStr, ElapsedStr, RemainStr: string;
  Frac: double;
begin
  Box := ClientRect;
  Radius := Min(AUDIO_CORNER_RADIUS, (Box.Bottom - Box.Top) div 2);

  { TAudioWidget is a real child control, unlike quotes/forward cards
    it doesn't paint "through" the parent's canvas — a solid
    background is needed outside the rounded corners, FBgColor
    (WidgetBackdropColor, LayoutAudioWidgets) is the real color of the
    block/forward card under the widget at this point, not bare
    clWindow: that showed up as white corners around the rounded
    backing, especially visible inside a colored forward card. }
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(Box);

  { The backing — the same approach as the reply quote box/forward
    card (SENDER_BG_OPACITY), but its own color (AUDIO_COLOR), not tied
    to the sender — the same for any audio. }
  PaintRoundRectAA(Canvas, Box, Radius, [],
    BlendWithBackground(AUDIO_COLOR, SENDER_BG_OPACITY, clWindow), clNone);

  { The play/pause button — left edge, vertically centered. }
  PlayRect := PlayButtonRect;
  if FIsActive and FPlaying then begin
    IconIdx := AUDIO_ICON_PAUSE;
  end else begin
    IconIdx := AUDIO_ICON_PLAY;
  end;
  if (FImages <> nil) and (IconIdx < FImages.Count) then begin
    FImages.Draw(Canvas, PlayRect.Left, PlayRect.Top, IconIdx, True);
  end;

  ContentX := PlayRect.Right + MSG_PAD_H;
  ContentW := Box.Right - MSG_PAD_H - ContentX;
  if ContentW < 10 then begin
    Exit;
  end;

  { The title — performer and track name separated by a dash;
    whichever one is present if the other is missing; the file name if
    there's no metadata at all. }
  if (FPerformer <> '') and (FTitle <> '') then begin
    TitleStr := string(FPerformer) + ' - ' + string(FTitle);
  end else if FTitle <> '' then begin
    TitleStr := string(FTitle);
  end else if FPerformer <> '' then begin
    TitleStr := string(FPerformer);
  end else begin
    TitleStr := string(FFileName);
  end;

  Canvas.Brush.Style := bsClear;
  Canvas.Font.Name := 'default';
  Canvas.Font.Height := -11;
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := AUDIO_COLOR;
  Canvas.TextOut(ContentX, Box.Top + MSG_PAD_H, TruncateToWidth(Canvas, TitleStr, ContentW));

  { The progress bar shows the real position only while THIS message is
    active (playing/paused); otherwise, as always, 0%. }
  ProgressTop := Box.Top + MSG_PAD_H + REPLY_LINE_H + HEADER_PAD_V;
  TrackRect := Rect(ContentX, ProgressTop + (AUDIO_THUMB_H - AUDIO_TRACK_H) div 2,
    ContentX + ContentW, ProgressTop + (AUDIO_THUMB_H - AUDIO_TRACK_H) div 2 + AUDIO_TRACK_H);
  if FDraggingSeek then begin
    PlayedW := Round(FDragFraction * ContentW);
  end else if FIsActive and (FDuration > 0) then begin
    Frac := FPositionSec / FDuration;
    if Frac < 0 then Frac := 0;
    if Frac > 1 then Frac := 1;
    PlayedW := Round(Frac * ContentW);
  end else begin
    PlayedW := 0;
  end;

  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := BlendWithBackground(AUDIO_COLOR, AUDIO_REMAIN_OPACITY, clWindow);
  Canvas.FillRect(TrackRect);
  if PlayedW > 0 then begin
    PlayedRect := Rect(TrackRect.Left, TrackRect.Top, TrackRect.Left + PlayedW, TrackRect.Bottom);
    Canvas.Brush.Color := BlendWithBackground(AUDIO_COLOR, AUDIO_PLAYED_OPACITY, clWindow);
    Canvas.FillRect(PlayedRect);
  end;

  ThumbRect := Rect(ContentX + PlayedW - AUDIO_THUMB_W div 2, ProgressTop,
    ContentX + PlayedW - AUDIO_THUMB_W div 2 + AUDIO_THUMB_W, ProgressTop + AUDIO_THUMB_H);
  Canvas.Brush.Color := BlendWithBackground(AUDIO_COLOR, AUDIO_PLAYED_OPACITY, clWindow);
  Canvas.FillRect(ThumbRect);

  { Time: elapsed on the left, remaining (negative) on the right.
    Brush.Style is reset back to bsClear explicitly — the FillRect
    calls above (track/thumb) switch it to bsSolid as a side effect of
    filling, otherwise the text would be drawn with an opaque
    background. }
  if FDraggingSeek then begin
    ElapsedStr := FormatAudioTime(Round(FDragFraction * FDuration));
    RemainStr := FormatAudioTime(Round(FDragFraction * FDuration) - FDuration);
  end else if FIsActive then begin
    ElapsedStr := FormatAudioTime(Round(FPositionSec));
    RemainStr := FormatAudioTime(Round(FPositionSec) - FDuration);
  end else begin
    ElapsedStr := FormatAudioTime(0);
    RemainStr := FormatAudioTime(-FDuration);
  end;
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Style := [];
  Canvas.Font.Color := AUDIO_COLOR;
  Canvas.TextOut(ContentX, ProgressTop + AUDIO_THUMB_H + HEADER_PAD_V, ElapsedStr);
  Canvas.TextOut(ContentX + ContentW - Canvas.TextWidth(RemainStr),
    ProgressTop + AUDIO_THUMB_H + HEADER_PAD_V, RemainStr);

  { The outline — drawn last, on top of the content, the same approach
    as other cards (SENDER_BORDER_OPACITY). }
  PaintRoundRectAA(Canvas, Box, Radius, [], clNone,
    BlendWithBackground(AUDIO_COLOR, SENDER_BORDER_OPACITY, clWindow));
end;

{ ---------------- TFileWidget ---------------- }

type
  TFileIconEntry = record
    Idx: integer;
    Ext: string;
  end;

const
  FILE_ICON_COUNT = 98;
  { Extension -> frame index in FileTypes (TFrameHistory). Not
    transcribed from screenshots by eye — generated from the real file
    list in res/file_types/ (the same directory the frames were bulk-
    imported into the ImageList from, via the Lazarus designer): the
    file_extension_<ext>.png names, sorted alphabetically, give EXACTLY
    the same order as frames 1..98 (frame 0 is page_white.png, a
    generic placeholder added before the bulk import). Built once via a
    shell command (ls | sed | awk), not by hand — free of transcription
    errors almost by construction, unlike an earlier version of this
    table read off screenshots (which nearly lost MSWMM and TORRENT —
    both sitting between alphabetically adjacent extensions, easy to
    skip past by eye). Each entry is an independent (index, extension)
    pair, not an array position, in case a future manual edit touches
    just one line. }
  FILE_ICONS: array[1..FILE_ICON_COUNT] of TFileIconEntry = (
    (Idx:1;Ext:'3GP'),    (Idx:2;Ext:'7Z'),     (Idx:3;Ext:'ACE'),    (Idx:4;Ext:'AI'),
    (Idx:5;Ext:'AIF'),    (Idx:6;Ext:'AIFF'),   (Idx:7;Ext:'AMR'),    (Idx:8;Ext:'ASF'),
    (Idx:9;Ext:'ASX'),    (Idx:10;Ext:'BAT'),   (Idx:11;Ext:'BIN'),   (Idx:12;Ext:'BMP'),
    (Idx:13;Ext:'BUP'),   (Idx:14;Ext:'CAB'),   (Idx:15;Ext:'CBR'),   (Idx:16;Ext:'CDA'),
    (Idx:17;Ext:'CDL'),   (Idx:18;Ext:'CDR'),   (Idx:19;Ext:'CHM'),   (Idx:20;Ext:'DAT'),
    (Idx:21;Ext:'DIVX'),  (Idx:22;Ext:'DLL'),   (Idx:23;Ext:'DMG'),   (Idx:24;Ext:'DOC'),
    (Idx:25;Ext:'DSS'),   (Idx:26;Ext:'DVF'),   (Idx:27;Ext:'DWG'),   (Idx:28;Ext:'EML'),
    (Idx:29;Ext:'EPS'),   (Idx:30;Ext:'EXE'),   (Idx:31;Ext:'FLA'),   (Idx:32;Ext:'FLV'),
    (Idx:33;Ext:'GIF'),   (Idx:34;Ext:'GZ'),    (Idx:35;Ext:'HQX'),   (Idx:36;Ext:'HTM'),
    (Idx:37;Ext:'HTML'),  (Idx:38;Ext:'IFO'),   (Idx:39;Ext:'INDD'),  (Idx:40;Ext:'ISO'),
    (Idx:41;Ext:'JAR'),   (Idx:42;Ext:'JPEG'),  (Idx:43;Ext:'JPG'),   (Idx:44;Ext:'LNK'),
    (Idx:45;Ext:'LOG'),   (Idx:46;Ext:'M4A'),   (Idx:47;Ext:'M4B'),   (Idx:48;Ext:'M4P'),
    (Idx:49;Ext:'M4V'),   (Idx:50;Ext:'MCD'),   (Idx:51;Ext:'MDB'),   (Idx:52;Ext:'MID'),
    (Idx:53;Ext:'MOV'),   (Idx:54;Ext:'MP2'),   (Idx:55;Ext:'MP4'),   (Idx:56;Ext:'MPEG'),
    (Idx:57;Ext:'MPG'),   (Idx:58;Ext:'MSI'),   (Idx:59;Ext:'MSWMM'), (Idx:60;Ext:'OGG'),
    (Idx:61;Ext:'PDF'),   (Idx:62;Ext:'PNG'),   (Idx:63;Ext:'PPS'),   (Idx:64;Ext:'PS'),
    (Idx:65;Ext:'PSD'),   (Idx:66;Ext:'PST'),   (Idx:67;Ext:'PTB'),   (Idx:68;Ext:'PUB'),
    (Idx:69;Ext:'QBB'),   (Idx:70;Ext:'QBW'),   (Idx:71;Ext:'QXD'),   (Idx:72;Ext:'RAM'),
    (Idx:73;Ext:'RAR'),   (Idx:74;Ext:'RM'),    (Idx:75;Ext:'RMVB'),  (Idx:76;Ext:'RTF'),
    (Idx:77;Ext:'SEA'),   (Idx:78;Ext:'SES'),   (Idx:79;Ext:'SIT'),   (Idx:80;Ext:'SITX'),
    (Idx:81;Ext:'SS'),    (Idx:82;Ext:'SWF'),   (Idx:83;Ext:'TGZ'),   (Idx:84;Ext:'THM'),
    (Idx:85;Ext:'TIF'),   (Idx:86;Ext:'TMP'),   (Idx:87;Ext:'TORRENT'),(Idx:88;Ext:'TTF'),
    (Idx:89;Ext:'TXT'),   (Idx:90;Ext:'VCD'),   (Idx:91;Ext:'VOB'),   (Idx:92;Ext:'WAV'),
    (Idx:93;Ext:'WMA'),   (Idx:94;Ext:'WMV'),   (Idx:95;Ext:'WPS'),   (Idx:96;Ext:'XLS'),
    (Idx:97;Ext:'XPI'),   (Idx:98;Ext:'ZIP')
  );

function FileIconIndex(const AFileName: utf8string): integer;
var
  Ext: string;
  I: integer;
begin
  Result := 0;
  Ext := UpperCase(string(ExtractFileExt(AFileName)));
  if (Ext <> '') and (Ext[1] = '.') then begin
    Delete(Ext, 1, 1);
  end;
  if Ext = '' then begin
    Exit;
  end;
  for I := 1 to FILE_ICON_COUNT do begin
    if FILE_ICONS[I].Ext = Ext then begin
      Result := FILE_ICONS[I].Idx;
      Exit;
    end;
  end;
end;

function FormatFileSize(ABytes: Int64): string;
begin
  if ABytes >= Int64(1024) * 1024 * 1024 then begin
    Result := FormatFloat('0.0', ABytes / (Int64(1024) * 1024 * 1024)) + ' GB';
  end else if ABytes >= 1024 * 1024 then begin
    Result := FormatFloat('0.0', ABytes / (1024 * 1024)) + ' MB';
  end else if ABytes >= 1024 then begin
    Result := FormatFloat('0.0', ABytes / 1024) + ' KB';
  end else begin
    Result := IntToStr(ABytes) + ' B';
  end;
end;

{ "Show in folder" — opens Explorer with the file already selected.
  Windows only (explorer.exe /select) — the same class of shim as
  audiodevices.pas/winmm for audio output: a platform-specific layer,
  while decoding/the model stay shared; only this thin spot would need
  to change on a future port to another OS. }
procedure ShowDocInFolder(const APath: utf8string);
begin
  if APath = '' then begin
    Exit;
  end;
  { SW_SHOWNORMAL = 1 — a well-known Win32 value, not worth importing
    the whole Windows unit for one constant. }
  ShellExecute(0, 'open', 'explorer.exe',
    PChar('/select,"' + string(APath) + '"'), nil, 1);
end;

constructor TFileWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  Cursor := crHandPoint;   { the whole widget is clickable, not just the icon }
  FBgColor := clWindow;   { fallback until the first LayoutFileWidgets }
end;

procedure TFileWidget.SetFile(ARowId: Int64; const AFileName: utf8string; AFileSize: Int64;
  ADownloaded: boolean);
begin
  FRowId := ARowId;
  FFileName := AFileName;
  FFileSize := AFileSize;
  FDownloaded := ADownloaded;
  FIconIndex := FileIconIndex(AFileName);
  Invalidate;
end;

function TFileWidget.IconRect: TRect;
var
  Box: TRect;
begin
  Box := ClientRect;
  Result := Rect(Box.Left + MSG_PAD_H, (Box.Top + Box.Bottom - AUDIO_BUTTON_SIZE) div 2,
    Box.Left + MSG_PAD_H + AUDIO_BUTTON_SIZE, (Box.Top + Box.Bottom + AUDIO_BUTTON_SIZE) div 2);
end;

procedure TFileWidget.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and Assigned(FOnClick) then begin
    FOnClick(Self);
  end;
end;

procedure TFileWidget.Paint;
var
  Box, IconR: TRect;
  Radius, ContentX, ContentW: integer;
  NameStr, SizeStr: string;
begin
  Box := ClientRect;
  Radius := Min(FILE_CORNER_RADIUS, (Box.Bottom - Box.Top) div 2);

  { The same approach as TAudioWidget — a real child control, doesn't
    let the parent's canvas show through, so a solid background outside
    the rounded corners is required — FBgColor (WidgetBackdropColor),
    not bare clWindow (see the comment in TAudioWidget.Paint). }
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(Box);

  PaintRoundRectAA(Canvas, Box, Radius, [],
    BlendWithBackground(AUDIO_COLOR, SENDER_BG_OPACITY, clWindow), clNone);

  IconR := IconRect;
  if not FDownloaded then begin
    { The file isn't on disk yet — shows the "download" icon, not the
      mime type: clicking it starts a download, not opening a
      nonexistent file. }
    if (FDownloadImages <> nil) and (AUDIO_ICON_DOWNLOAD < FDownloadImages.Count) then begin
      FDownloadImages.Draw(Canvas, IconR.Left, IconR.Top, AUDIO_ICON_DOWNLOAD, True);
    end;
  end else begin
    if (FImages <> nil) and (FIconIndex < FImages.Count) then begin
      FImages.Draw(Canvas, IconR.Left, IconR.Top, FIconIndex, True);
    end;
  end;

  ContentX := IconR.Right + MSG_PAD_H;
  ContentW := Box.Right - MSG_PAD_H - ContentX;
  if ContentW < 10 then begin
    Exit;
  end;

  { No progress bar (unlike audio) — no need to spread the lines across
    its height: the name aligns with the icon's top edge, the size with
    its bottom, with no gap between them beyond the lines' own height. }
  NameStr := string(FFileName);
  if NameStr = '' then begin
    NameStr := 'File';
  end;
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Name := 'default';
  Canvas.Font.Height := -11;
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := AUDIO_COLOR;
  Canvas.TextOut(ContentX, IconR.Top, TruncateToWidth(Canvas, NameStr, ContentW));

  SizeStr := FormatFileSize(FFileSize);
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Style := [];
  Canvas.Font.Color := AUDIO_COLOR;
  Canvas.TextOut(ContentX, IconR.Bottom - Canvas.TextHeight(SizeStr), SizeStr);

  PaintRoundRectAA(Canvas, Box, Radius, [], clNone,
    BlendWithBackground(AUDIO_COLOR, SENDER_BORDER_OPACITY, clWindow));
end;

{ ---------------- TPhotoWidget ---------------- }

constructor TPhotoWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  Cursor := crHandPoint;   { the whole widget is clickable }
  FBgColor := clWindow;    { fallback until the first LayoutPhotoWidgets }
end;

destructor TPhotoWidget.Destroy;
begin
  { ClearBitmaps cancels a background decode still in progress (see its
    own comment) — without this, DecodeDone would later call a method
    on an already-destroyed object. }
  ClearBitmaps;
  inherited Destroy;
end;

procedure TPhotoWidget.ClearBitmaps;
begin
  if FDecodeThread <> nil then begin
    { The widget was reused for a different message/size before the
      previous background decode finished — that decode is no longer
      needed; Cancel guarantees DoDone won't touch this object's
      fields with a result nobody cares about anymore (see its own
      comment). The pointer is cleared right away — the widget keeps
      living, and "no decode is running for me right now" must be true
      immediately. }
    FDecodeThread.Cancel;
    FDecodeThread := nil;
  end;
  FreeAndNil(FBlurBmp);
  FreeAndNil(FRealBmp);
end;

procedure TPhotoWidget.SetPhoto(ARowId: Int64; ANaturalW, ANaturalH: integer;
  const AMinithumb: RawByteString; ADownloaded: boolean; const ALocalPath: utf8string;
  AMaxW: integer);
var
  Ms: TMemoryStream;
  Src, Resized, Stretched: TBGRABitmap;
  OldTargetW, OldTargetH: integer;
begin
  if ARowId <> FRowId then begin
    { The pooled widget was reused for a DIFFERENT message — the old
      decoded bitmaps belong to a different photo, cleared. If ARowId
      is the same (an ordinary repeat pass of LayoutPhotoWidgets,
      called on every Paint of the scroller), the bitmaps are NOT
      touched, the same reason already documented for
      TAudioWidget.SetTrack. }
    ClearBitmaps;
  end;
  FRowId := ARowId;
  FNaturalW := ANaturalW;
  FNaturalH := ANaturalH;
  OldTargetW := FTargetW;
  OldTargetH := FTargetH;
  ComputePhotoPreviewSize(ANaturalW, ANaturalH, AMaxW, FTargetW, FTargetH);
  if (FTargetW <> OldTargetW) or (FTargetH <> OldTargetH) then begin
    { The column width changed (the window was resized) — the already-
      decoded bitmaps are now the wrong size. FLocalPath is cleared
      too — otherwise the "path appeared/changed" block below wouldn't
      re-enter decode for the same path. }
    ClearBitmaps;
    FLocalPath := '';
  end;

  { The blur placeholder from minithumbnail is decoded and blurred once
    (until ready), not on every pass: the file itself is tiny, but
    resample+blur aren't free, and this method is called on every
    Paint. A double blur (10px on the source, stretching, then another
    10px on the result) — the first pass on the tiny (~30x40) source
    removes JPEG blockiness BEFORE stretching, the second smooths the
    resample itself (rmFineResample already gives soft interpolation,
    but the second blur adds a margin in case the source wasn't quite
    that small). }
  if (FBlurBmp = nil) and (AMinithumb <> '') then begin
    Ms := TMemoryStream.Create;
    Src := nil;
    Resized := nil;
    Stretched := nil;
    try
      try
        Ms.WriteBuffer(AMinithumb[1], Length(AMinithumb));
        Ms.Position := 0;
        Src := TBGRABitmap.Create(Ms);
        Resized := TBGRABitmap(FilterBlurRadial(Src, 10, rbNormal));
        Resized.ResampleFilter := rfBestQuality;
        Stretched := Resized.Resample(FTargetW, FTargetH, rmFineResample);
        FBlurBmp := TBGRABitmap(FilterBlurRadial(Stretched, 10, rbNormal));
      except
        ClearBitmaps;
      end;
    finally
      Stretched.Free;
      Resized.Free;
      Src.Free;
      Ms.Free;
    end;
  end;

  { The real photo is decoded only when the path actually appeared or
    changed, not on every pass, and now IN A BACKGROUND THREAD
    (photodecoder.pas), not synchronously here — with aggressive
    lookahead auto-download, several rows with an already-downloaded
    but never-yet-shown photo can become visible almost simultaneously
    during a fast scroll; a full-size JPEG decode+resample for each one
    synchronously inside SetPhoto (which is called from
    LayoutPhotoWidgets, from Paint) noticeably stalled scrolling. The
    result itself is applied later, in DecodeDone (Synchronize, main
    thread) — the Invalidate below in this method doesn't show the
    image yet, only the background/blur placeholder; the real frame
    arrives separately. }
  if (ALocalPath <> '') and (ALocalPath <> FLocalPath) then begin
    if FDecodeThread <> nil then begin
      { Shouldn't happen in practice (the path for one row changes at
        most once, from '' to a real value) — but if it does, the
        previous, still-unfinished decode is no longer needed. }
      FDecodeThread.Cancel;
    end;
    FreeAndNil(FRealBmp);
    FDecodeThread := TPhotoDecodeThread.Create(ALocalPath, FTargetW, FTargetH, @DecodeDone);
  end;

  FDownloaded := ADownloaded;
  FLocalPath := ALocalPath;
  Invalidate;
end;

{ TPhotoDecodeThread's callback — already on the main thread
  (Synchronize). FDecodeThread is unconditionally cleared here: this is
  the ONLY place where the decode finishes naturally, on its own
  (ClearBitmaps — the only OTHER place touching this field — clears it
  itself when the decode is canceled BEFORE this point, see its
  comment, so by the time DoDone would call this callback — if it ever
  did — FCanceled would already be True and this method wouldn't be
  called at all, see TPhotoDecodeThread.DoDone). }
procedure TPhotoWidget.DecodeDone(Sender: TObject);
var
  Bmp: TBGRABitmap;
begin
  Bmp := TPhotoDecodeThread(Sender).TakeResult;
  FDecodeThread := nil;
  if Bmp = nil then begin
    Exit;
  end;
  FreeAndNil(FRealBmp);
  FRealBmp := Bmp;
  Invalidate;
end;

{ Fills the client area (already with the real background color
  clWindow — a real child control, doesn't let the parent's canvas
  show through) and draws the given bitmap as-is. This used to include
  rounding (PHOTO_CORNER_RADIUS) — a BGRA mask when SMOOTH_CORNERS=True,
  a GDI region when False — plus a gray outline on top; both were
  removed entirely. The method's name ("Rounded") is a historical
  leftover, left unchanged: the risk of touching other call sites
  wasn't worth renaming for one word. }
procedure TPhotoWidget.DrawBmpRounded(ABmp: TBGRABitmap);
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(ClientRect);

  if (ABmp = nil) or (ABmp.Width <= 0) or (ABmp.Height <= 0) then begin
    Exit;
  end;
  ABmp.Draw(Canvas, 0, 0, False);
end;

procedure TPhotoWidget.Paint;
var
  IconR: TRect;
begin
  if FDownloaded and (FRealBmp <> nil) then begin
    DrawBmpRounded(FRealBmp)
  end else begin
    DrawBmpRounded(FBlurBmp);
  end;

  if not FDownloaded then begin
    { The "download" icon, centered over the preview, the same frame
      TFileWidget uses for an undownloaded file. }
    if (FDownloadImages <> nil) and (AUDIO_ICON_DOWNLOAD < FDownloadImages.Count) then begin
      IconR := Rect((ClientWidth - AUDIO_BUTTON_SIZE) div 2, (ClientHeight - AUDIO_BUTTON_SIZE) div 2,
        (ClientWidth + AUDIO_BUTTON_SIZE) div 2, (ClientHeight + AUDIO_BUTTON_SIZE) div 2);
      FDownloadImages.Draw(Canvas, IconR.Left, IconR.Top, AUDIO_ICON_DOWNLOAD, True);
    end;
  end;
end;

procedure TPhotoWidget.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and Assigned(FOnClick) then begin
    FOnClick(Self);
  end;
end;

{ ---------------- TAnimationWidget ---------------- }

{ Blits an already-ready BGRA buffer (AWidth*AHeight*4 bytes, top-to-
  bottom row order — the same swscale produces in videoplayer.pas)
  directly onto Canvas, with no intermediate TBGRABitmap — the sole
  reason for a separate function rather than reusing TBGRABitmap.Draw:
  that would have to wrap the foreign memory in a temporary object
  every time, whereas SetDIBitsToDevice does the same thing in one
  system call. AV_PIX_FMT_BGRA (ffdecode.pas) matches the byte order
  (B,G,R,A) of a standard 32-bit Windows DIB (biBitCount=32, BI_RGB) —
  no conversion needed, just describing the format. A negative
  biHeight makes it a top-down DIB, no row flip required. }
procedure DrawBgraBuffer(ACanvas: TCanvas; ABuf: PByte; AWidth, AHeight: integer);
var
  Bmi: Windows.BITMAPINFO;
begin
  { Windows.BITMAPINFO is qualified explicitly — LCLType also declares
    its own TBitmapInfo (a different, binary-incompatible type), and it
    comes later than Windows in this file's uses, shadowing the name
    for unqualified use (the same pitfall already described in the
    comment on the uses clause itself) — SetDIBitsToDevice from the
    Windows module requires exactly Windows.BITMAPINFO, not the other
    same-named type. }
  FillChar(Bmi, SizeOf(Bmi), 0);
  Bmi.bmiHeader.biSize := SizeOf(Bmi.bmiHeader);
  Bmi.bmiHeader.biWidth := AWidth;
  Bmi.bmiHeader.biHeight := -AHeight;
  Bmi.bmiHeader.biPlanes := 1;
  Bmi.bmiHeader.biBitCount := 32;
  Bmi.bmiHeader.biCompression := BI_RGB;
  Windows.SetDIBitsToDevice(ACanvas.Handle, 0, 0, AWidth, AHeight, 0, 0, 0, AHeight,
    ABuf, Bmi, DIB_RGB_COLORS);
end;

constructor TAnimationWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Cursor := crHandPoint;
  FBgColor := clWindow;
  { The poll interval is how often to "check for a new frame and
    repaint", NOT the pause between frames of the source video (that's
    decided by the decoder thread itself, see
    TAnimationPlayer.ExecuteInner/HandleFrame) — ~30 times a second,
    with margin over a typical 24-30fps video. }
  FPollTimer := TTimer.Create(Self);
  FPollTimer.Interval := 33;
  FPollTimer.OnTimer := @PollTick;
  FPollTimer.Enabled := False;
end;

destructor TAnimationWidget.Destroy;
begin
  StopLoop;
  ClearBitmap;
  if FFrameBuf <> nil then begin
    FreeMem(FFrameBuf);
  end;
  inherited Destroy;
end;

procedure TAnimationWidget.ClearBitmap;
begin
  FreeAndNil(FBlurBmp);
end;

procedure TAnimationWidget.SetAnim(ARowId: Int64; ANaturalW, ANaturalH: integer;
  const AMinithumb: RawByteString; ADownloaded: boolean; const ALocalPath: utf8string;
  AMaxW: integer);
var
  Ms: TMemoryStream;
  Src, Resized, Stretched: TBGRABitmap;
  OldTargetW, OldTargetH: integer;
begin
  if ARowId <> FRowId then begin
    { The pooled widget was reused for a DIFFERENT message — the same
      approach as TPhotoWidget.SetPhoto: any old playback (if it was
      running) and the old decoded placeholder no longer belong to
      this message. }
    StopLoop;
    ClearBitmap;
    FLocalPath := '';
  end;
  FRowId := ARowId;
  FNaturalW := ANaturalW;
  FNaturalH := ANaturalH;
  OldTargetW := FTargetW;
  OldTargetH := FTargetH;
  ComputePhotoPreviewSize(ANaturalW, ANaturalH, AMaxW, FTargetW, FTargetH);
  if (FTargetW <> OldTargetW) or (FTargetH <> OldTargetH) then begin
    { The column width changed — the old FFrameBuf/decoded placeholder
      are now the wrong size. FFrameBuf is freed (not just left as is)
      — otherwise the next TryGetFrame would write a NEW-size frame
      into an OLD-size buffer, corrupting memory. }
    StopLoop;
    ClearBitmap;
    FLocalPath := '';
    if FFrameBuf <> nil then begin
      FreeMem(FFrameBuf);
      FFrameBuf := nil;
    end;
  end;

  if (FBlurBmp = nil) and (AMinithumb <> '') then begin
    Ms := TMemoryStream.Create;
    Src := nil;
    Resized := nil;
    Stretched := nil;
    try
      try
        Ms.WriteBuffer(AMinithumb[1], Length(AMinithumb));
        Ms.Position := 0;
        Src := TBGRABitmap.Create(Ms);
        Resized := TBGRABitmap(FilterBlurRadial(Src, 10, rbNormal));
        Resized.ResampleFilter := rfBestQuality;
        Stretched := Resized.Resample(FTargetW, FTargetH, rmFineResample);
        { The mask/outline are NOT composited into the bitmap itself
          (unlike TPhotoWidget) — this widget's rounding is always
          drawn in Paint through a cheap GDI region, the same for both
          the placeholder and the live frame (see the class comment) —
          FBlurBmp stays a plain rectangular bitmap. }
        FBlurBmp := TBGRABitmap(FilterBlurRadial(Stretched, 10, rbNormal));
      except
        ClearBitmap;
      end;
    finally
      Stretched.Free;
      Resized.Free;
      Src.Free;
      Ms.Free;
    end;
  end;

  FDownloaded := ADownloaded;
  FLocalPath := ALocalPath;
  Invalidate;
end;

procedure TAnimationWidget.StartLoop;
begin
  if FPlaying or (FLocalPath = '') or (FTargetW <= 0) or (FTargetH <= 0) then begin
    Exit;
  end;
  if FFrameBuf = nil then begin
    GetMem(FFrameBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);
  end;
  FFrameKnownVersion := 0;
  FPlayer := TAnimationPlayer.Create(FLocalPath, FTargetW, FTargetH);
  FPlaying := True;
  FPollTimer.Enabled := True;
end;

procedure TAnimationWidget.StopLoop;
begin
  FPollTimer.Enabled := False;
  if FPlayer <> nil then begin
    { TAnimationPlayer's own FreeOnTerminate=True (videoplayer.pas, see
      its comment for why) — StopPlayback asynchronously asks the
      thread to stop, and the pointer is forgotten right away, never
      touching the object afterward: it may be destroyed (on its own,
      from its own thread) at any moment after this. }
    FPlayer.StopPlayback;
    FPlayer := nil;
  end;
  FPlaying := False;
end;

procedure TAnimationWidget.PollTick(Sender: TObject);
begin
  if (FPlayer = nil) or (FFrameBuf = nil) then begin
    Exit;
  end;
  if FPlayer.TryGetFrame(FFrameBuf, FFrameKnownVersion) then begin
    Invalidate;
  end;
end;

procedure TAnimationWidget.Paint;
var
  IconR: TRect;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(ClientRect);

  if (Width > 0) and (Height > 0) then begin
    if FPlaying and (FFrameBuf <> nil) then begin
      DrawBgraBuffer(Canvas, FFrameBuf, Width, Height);
    end else if FBlurBmp <> nil then begin
      FBlurBmp.Draw(Canvas, 0, 0, False);
    end;
  end;

  if not FDownloaded then begin
    { The "download" icon, centered over the preview, the same frame
      TFileWidget/TPhotoWidget use for an undownloaded item. Not drawn
      while playing (FPlaying) — if already downloaded and playing,
      there's nothing to show: no controls, downloading is long over. }
    if (FDownloadImages <> nil) and (AUDIO_ICON_DOWNLOAD < FDownloadImages.Count) then begin
      IconR := Rect((ClientWidth - AUDIO_BUTTON_SIZE) div 2, (ClientHeight - AUDIO_BUTTON_SIZE) div 2,
        (ClientWidth + AUDIO_BUTTON_SIZE) div 2, (ClientHeight + AUDIO_BUTTON_SIZE) div 2);
      FDownloadImages.Draw(Canvas, IconR.Left, IconR.Top, AUDIO_ICON_DOWNLOAD, True);
    end;
  end;
end;

procedure TAnimationWidget.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and Assigned(FOnClick) then begin
    FOnClick(Self);
  end;
end;

{ ---------------- TVideoWidget ---------------- }

constructor TVideoWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Cursor := crDefault;   { changes based on hover position, see MouseMove — like TAudioWidget }
  FBgColor := clWindow;
end;

destructor TVideoWidget.Destroy;
begin
  ClearBitmap;
  if FFrameBuf <> nil then begin
    FreeMem(FFrameBuf);
  end;
  inherited Destroy;
end;

procedure TVideoWidget.ClearBitmap;
begin
  FreeAndNil(FThumbBmp);
end;

procedure TVideoWidget.SetVideo(ARowId: Int64; ANaturalW, ANaturalH: integer;
  const AThumbLocalPath: utf8string; ADownloaded: boolean; const ALocalPath: utf8string;
  AMaxW: integer; ADuration: integer);
var
  TgtW, TgtH: integer;
begin
  ComputePhotoPreviewSize(ANaturalW, ANaturalH, AMaxW, TgtW, TgtH);
  SetVideoCore(ARowId, ANaturalW, ANaturalH, AThumbLocalPath, ADownloaded, ALocalPath, TgtW, TgtH, ADuration);
end;

procedure TVideoWidget.SetVideoSized(ARowId: Int64; ANaturalW, ANaturalH: integer;
  const AThumbLocalPath: utf8string; ADownloaded: boolean; const ALocalPath: utf8string;
  ATargetW, ATargetH, ADuration: integer);
begin
  SetVideoCore(ARowId, ANaturalW, ANaturalH, AThumbLocalPath, ADownloaded, ALocalPath, ATargetW, ATargetH, ADuration);
end;

procedure TVideoWidget.SetVideoCore(ARowId: Int64; ANaturalW, ANaturalH: integer;
  const AThumbLocalPath: utf8string; ADownloaded: boolean; const ALocalPath: utf8string;
  ATargetW, ATargetH, ADuration: integer);
var
  Src: TBGRABitmap;
  OldTargetW, OldTargetH: integer;
begin
  if ARowId <> FRowId then begin
    { The pooled widget was reused for a DIFFERENT message — the same
      approach as TAnimationWidget.SetAnim: any old playback state/
      decoded placeholder no longer belong to this video. }
    ClearBitmap;
    FLocalPath := '';
    FHaveFrame := False;
    FIsActive := False;
    FPlaying := False;
    FPositionSec := 0;
    FDraggingSeek := False;
  end;
  FRowId := ARowId;
  FNaturalW := ANaturalW;
  FNaturalH := ANaturalH;
  FDuration := ADuration;
  OldTargetW := FTargetW;
  OldTargetH := FTargetH;
  FTargetW := ATargetW;
  FTargetH := ATargetH;
  if (FTargetW <> OldTargetW) or (FTargetH <> OldTargetH) then begin
    { The size changed — the old FrameBuf is now the wrong size;
      whoever (the player, through the FrameBuf pointer) was writing to
      it using the old FTargetW/FTargetH could corrupt memory on the
      next write if the buffer stayed the old size. }
    ClearBitmap;
    FLocalPath := '';
    FHaveFrame := False;
    if FFrameBuf <> nil then begin
      FreeMem(FFrameBuf);
      FFrameBuf := nil;
    end;
  end;
  if FFrameBuf = nil then begin
    GetMem(FFrameBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);
  end;

  if (FThumbBmp = nil) and (AThumbLocalPath <> '') then begin
    { A sharp frame from content.video.thumbnail (a 320x180 JPEG,
      already on disk by this point, see the class comment about
      dropping the blur) — the file is small, decode+resample is
      synchronous, a separate thread (like TPhotoDecodeThread for
      full-size photos) isn't warranted. }
    Src := nil;
    try
      try
        Src := TBGRABitmap.Create(string(AThumbLocalPath));
        Src.ResampleFilter := rfBestQuality;
        FThumbBmp := Src.Resample(FTargetW, FTargetH, rmFineResample);
      except
        ClearBitmap;
      end;
    finally
      Src.Free;
    end;
  end;

  FDownloaded := ADownloaded;
  FLocalPath := ALocalPath;
  Invalidate;
end;

procedure TVideoWidget.SetPlayback(AIsActive, APlaying: boolean; APositionSec: double);
begin
  FIsActive := AIsActive;
  FPlaying := APlaying;
  FPositionSec := APositionSec;
  Invalidate;
end;

procedure TVideoWidget.NotifyNewFrame;
begin
  FHaveFrame := True;
  Invalidate;
end;

function TVideoWidget.PlayButtonRect: TRect;
var
  Box: TRect;
begin
  Box := ClientRect;
  Result := Rect((Box.Right - AUDIO_BUTTON_SIZE) div 2, (Box.Bottom - AUDIO_BUTTON_SIZE) div 2,
    (Box.Right + AUDIO_BUTTON_SIZE) div 2, (Box.Bottom + AUDIO_BUTTON_SIZE) div 2);
end;

function TVideoWidget.ContentGeometry(out AContentX, AContentW, AProgressTop: integer): boolean;
var
  Box: TRect;
  TimeH: integer;
begin
  Box := ClientRect;
  AContentX := Box.Left + MSG_PAD_H;
  AContentW := Box.Right - MSG_PAD_H - AContentX;
  TimeH := Canvas.TextHeight('0');
  { Bottom to top: MSG_PAD_V (bottom padding), the transport-button row
    (PLAYBACK_BTN_SIZE, see ButtonsRowTop/PlaybackButtonRect — viewer
    only, FIsActive), HEADER_PAD_V (gap), the time row (TimeH),
    HEADER_PAD_V (gap), the scrub bar (AUDIO_THUMB_H). }
  AProgressTop := Box.Bottom - MSG_PAD_V - PLAYBACK_BTN_SIZE - HEADER_PAD_V -
    TimeH - HEADER_PAD_V - AUDIO_THUMB_H;
  Result := AContentW >= 10;
end;

function TVideoWidget.ButtonsRowTop: integer;
begin
  Result := ClientRect.Bottom - MSG_PAD_V - PLAYBACK_BTN_SIZE;
end;

function TVideoWidget.PlaybackButtonRect(AIndex: integer): TRect;
var
  Box: TRect;
  TotalW, StartX, RowTop: integer;
begin
  Box := ClientRect;
  TotalW := 6 * PLAYBACK_BTN_SIZE + 5 * PLAYBACK_BTN_GAP;
  StartX := Box.Left + (Box.Right - Box.Left - TotalW) div 2;
  RowTop := ButtonsRowTop;
  Result := Rect(StartX + AIndex * (PLAYBACK_BTN_SIZE + PLAYBACK_BTN_GAP), RowTop,
    StartX + AIndex * (PLAYBACK_BTN_SIZE + PLAYBACK_BTN_GAP) + PLAYBACK_BTN_SIZE,
    RowTop + PLAYBACK_BTN_SIZE);
end;

function TVideoWidget.ControlsVisible: boolean;
begin
  Result := FIsActive and (FHovering or FDraggingSeek or (not FPlaying));
end;

procedure TVideoWidget.SkipBy(ADeltaSec: double);
var
  NewPos, Frac: double;
begin
  if (FDuration <= 0) or (not Assigned(FOnSeek)) then begin
    Exit;
  end;
  NewPos := FPositionSec + ADeltaSec;
  if NewPos < 0 then begin
    NewPos := 0;
  end;
  if NewPos > FDuration then begin
    NewPos := FDuration;
  end;
  Frac := NewPos / FDuration;
  FOnSeek(Self, Frac);
end;

function TVideoWidget.TrackAreaRect: TRect;
var
  CX, CW, PT: integer;
begin
  if not ContentGeometry(CX, CW, PT) then begin
    Result := Rect(0, 0, 0, 0);
    Exit;
  end;
  { The hit area extends above and below the visual bar/thumb — the
    same margin (4px) as TAudioWidget.TrackAreaRect. }
  Result := Rect(CX, PT - 4, CX + CW, PT + AUDIO_THUMB_H + 4);
end;

function TVideoWidget.FractionFromX(AX: integer): double;
var
  CX, CW, PT: integer;
begin
  Result := 0;
  if not ContentGeometry(CX, CW, PT) or (CW <= 0) then begin
    Exit;
  end;
  Result := (AX - CX) / CW;
  if Result < 0 then begin
    Result := 0;
  end;
  if Result > 1 then begin
    Result := 1;
  end;
end;

procedure TVideoWidget.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  I: integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then begin
    Exit;
  end;
  if not FDownloaded then begin
    { The whole widget is clickable to start downloading, the same
      approach as TFileWidget/TPhotoWidget — there's no play button or
      bar yet at this point. }
    if Assigned(FOnClick) then begin
      FOnClick(Self);
    end;
    Exit;
  end;
  if not FIsActive then begin
    { In the chat, this is the only clickable zone over the frame (see
      Paint — the widget never shows the transport row here). }
    if PtInRect(PlayButtonRect, Point(X, Y)) then begin
      if Assigned(FOnPlayClick) then begin
        FOnPlayClick(Self);
      end;
    end;
    Exit;
  end;
  { In the viewer — the transport-button row, only while it's actually
    visible (see ControlsVisible/Paint) — otherwise an invisible button
    could be clicked. Skip ±10s goes through SkipBy (the already
    existing OnSeek, see its comment), the other four are their own
    events — prev/next/repeat are decided by the owner
    (mediaviewer.pas). }
  if ControlsVisible then begin
    for I := 0 to 5 do begin
      if PtInRect(PlaybackButtonRect(I), Point(X, Y)) then begin
        case I of
          0: if Assigned(FOnPrevClick) then FOnPrevClick(Self);
          1: SkipBy(-PLAYBACK_SKIP_SEC);
          2: if Assigned(FOnPlayClick) then FOnPlayClick(Self);
          3: if Assigned(FOnRepeatClick) then FOnRepeatClick(Self);
          4: SkipBy(PLAYBACK_SKIP_SEC);
        else
          if Assigned(FOnNextClick) then FOnNextClick(Self);
        end;
        Exit;
      end;
    end;
  end;
  { Seeking is only possible while the bar is actually visible (see
    ControlsVisible), the same approach as TAudioWidget, plus a
    visibility requirement that audio doesn't have (its bar is always
    on screen). }
  if ControlsVisible and PtInRect(TrackAreaRect, Point(X, Y)) then begin
    FDraggingSeek := True;
    FDragFraction := FractionFromX(X);
    Invalidate;
    Exit;
  end;
  { A click on the frame itself — not play/pause, not the bar, not the
    button row — means "open bigger" (see FOnBodyClick). Inside the
    viewer itself, this callback isn't assigned — a safe no-op. }
  if Assigned(FOnBodyClick) then begin
    FOnBodyClick(Self);
  end;
end;

procedure TVideoWidget.MouseMove(Shift: TShiftState; X, Y: integer);
var
  I: integer;
  OverControl: boolean;
begin
  inherited MouseMove(Shift, X, Y);
  if FDraggingSeek then begin
    FDragFraction := FractionFromX(X);
    Invalidate;
    Exit;
  end;
  if not FDownloaded then begin
    Cursor := crHandPoint;
    Exit;
  end;
  if not FIsActive then begin
    if PtInRect(PlayButtonRect, Point(X, Y)) then begin
      Cursor := crHandPoint;
    end else begin
      Cursor := crDefault;
    end;
    Exit;
  end;
  OverControl := False;
  if ControlsVisible then begin
    OverControl := PtInRect(TrackAreaRect, Point(X, Y));
    if not OverControl then begin
      for I := 0 to 5 do begin
        if PtInRect(PlaybackButtonRect(I), Point(X, Y)) then begin
          OverControl := True;
          Break;
        end;
      end;
    end;
  end;
  if OverControl then begin
    Cursor := crHandPoint;
  end else begin
    Cursor := crDefault;
  end;
end;

procedure TVideoWidget.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDraggingSeek and (Button = mbLeft) then begin
    FDraggingSeek := False;
    if Assigned(FOnSeek) then begin
      FOnSeek(Self, FDragFraction);
    end;
    Invalidate;
  end;
end;

procedure TVideoWidget.MouseEnter;
begin
  inherited MouseEnter;
  FHovering := True;
  Invalidate;
end;

procedure TVideoWidget.MouseLeave;
begin
  inherited MouseLeave;
  FHovering := False;
  { Dragging is NOT interrupted — FDraggingSeek/ShowSeekBar in Paint
    account for it separately from FHovering (see Paint), otherwise the
    bar would visually vanish right under the held thumb the moment the
    mouse leaves the widget for a fraction of a second during the
    drag. }
  Invalidate;
end;

procedure TVideoWidget.Paint;
var
  Box, PlayRect, TrackRect, ThumbRect, PlayedRect, OverlayRect, BtnRect: TRect;
  ContentX, ContentW, ProgressTop, PlayedW, IconIdx, TimeH, I: integer;
  Frac: double;
  ElapsedStr, RemainStr: string;
begin
  Box := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(Box);

  { Rounding (a PHOTO_CORNER_RADIUS clip region) plus a gray outline
    used to be drawn here. Both were removed entirely — the chat and
    the viewer now paint the frame the same way, filling the widget's
    whole rectangle, with nothing left to distinguish. }
  if (Box.Right > Box.Left) and (Box.Bottom > Box.Top) then begin
    if FHaveFrame and (FFrameBuf <> nil) then begin
      DrawBgraBuffer(Canvas, FFrameBuf, FTargetW, FTargetH);
    end else if FThumbBmp <> nil then begin
      FThumbBmp.Draw(Canvas, 0, 0, False);
    end;
  end;

  if not FDownloaded then begin
    if (FDownloadImages <> nil) and (AUDIO_ICON_DOWNLOAD < FDownloadImages.Count) then begin
      PlayRect := PlayButtonRect;
      FDownloadImages.Draw(Canvas, PlayRect.Left, PlayRect.Top, AUDIO_ICON_DOWNLOAD, True);
    end;
    Exit;
  end;

  if not FIsActive then begin
    { In the chat, the widget is NEVER active, has no player/transport
      row of its own (see the class comment) — just one large,
      centered PLAY icon, ALWAYS. }
    PlayRect := PlayButtonRect;
    if (FImages <> nil) and (AUDIO_ICON_PLAY < FImages.Count) then begin
      FImages.Draw(Canvas, PlayRect.Left, PlayRect.Top, AUDIO_ICON_PLAY, True);
    end;
    Exit;
  end;

  { In the viewer (having reached here means FIsActive is True). The
    whole block (bar+time+transport row) acts as one unit: shown
    ALWAYS while the video isn't playing (paused/not yet started —
    the same case that used to show a lone centered PLAY, whose role
    now belongs to the play/pause button in the row), and ONLY on
    hover (or while a drag started on hover is still in progress, see
    MouseLeave) while the video is actively playing — a clean picture,
    unobstructed. }
  if FPlaying and (not ControlsVisible) then begin
    Exit;   { a clean video, no controls, until the mouse hovers }
  end;

  if not ContentGeometry(ContentX, ContentW, ProgressTop) then begin
    Exit;
  end;

  TimeH := Canvas.TextHeight('0');

  { A dark backing under the bar/time/button row — otherwise they'd be
    hard to read against an arbitrary video. A solid fill, not
    semi-transparent — real alpha blending against a frame that changes
    dozens of times a second would cost noticeably more (the same
    reason other widgets use cheap rounding). Having reached this
    point, the whole block is shown as-is — no separate condition on
    the fill itself is needed. }
  OverlayRect := Rect(Box.Left, ProgressTop - MSG_PAD_V, Box.Right, Box.Bottom);
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := RGBToColor(20, 20, 20);
  Canvas.FillRect(OverlayRect);

  { The scrub bar — the same geometry/colors/behavior as
    TAudioWidget.Paint (AUDIO_TRACK_H/AUDIO_THUMB_H/W/
    AUDIO_PLAYED_OPACITY/AUDIO_REMAIN_OPACITY/FormatAudioTime), matching
    it exactly. Blended toward black (clBlack), not clWindow like
    audio — the backing here is dark (see OverlayRect above), not the
    message block's light background. }
  TrackRect := Rect(ContentX, ProgressTop + (AUDIO_THUMB_H - AUDIO_TRACK_H) div 2,
    ContentX + ContentW, ProgressTop + (AUDIO_THUMB_H - AUDIO_TRACK_H) div 2 + AUDIO_TRACK_H);
  if FDraggingSeek then begin
    PlayedW := Round(FDragFraction * ContentW);
  end else if FDuration > 0 then begin
    Frac := FPositionSec / FDuration;
    if Frac < 0 then begin
      Frac := 0;
    end;
    if Frac > 1 then begin
      Frac := 1;
    end;
    PlayedW := Round(Frac * ContentW);
  end else begin
    PlayedW := 0;
  end;

  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := BlendWithBackground(AUDIO_COLOR, AUDIO_REMAIN_OPACITY, clBlack);
  Canvas.FillRect(TrackRect);
  if PlayedW > 0 then begin
    PlayedRect := Rect(TrackRect.Left, TrackRect.Top, TrackRect.Left + PlayedW, TrackRect.Bottom);
    Canvas.Brush.Color := BlendWithBackground(AUDIO_COLOR, AUDIO_PLAYED_OPACITY, clBlack);
    Canvas.FillRect(PlayedRect);
  end;

  ThumbRect := Rect(ContentX + PlayedW - AUDIO_THUMB_W div 2, ProgressTop,
    ContentX + PlayedW - AUDIO_THUMB_W div 2 + AUDIO_THUMB_W, ProgressTop + AUDIO_THUMB_H);
  Canvas.Brush.Color := BlendWithBackground(AUDIO_COLOR, AUDIO_PLAYED_OPACITY, clBlack);
  Canvas.FillRect(ThumbRect);

  if FDraggingSeek then begin
    ElapsedStr := FormatAudioTime(Round(FDragFraction * FDuration));
    RemainStr := FormatAudioTime(Round(FDragFraction * FDuration) - FDuration);
  end else begin
    ElapsedStr := FormatAudioTime(Round(FPositionSec));
    RemainStr := FormatAudioTime(Round(FPositionSec) - FDuration);
  end;
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Name := 'default';
  Canvas.Font.Height := -11;
  Canvas.Font.Style := [];
  Canvas.Font.Color := clWhite;
  Canvas.TextOut(ContentX, ProgressTop + AUDIO_THUMB_H + HEADER_PAD_V, ElapsedStr);
  Canvas.TextOut(ContentX + ContentW - Canvas.TextWidth(RemainStr),
    ProgressTop + AUDIO_THUMB_H + HEADER_PAD_V, RemainStr);

  { The transport-button row: left to right, prev / -10s / play-pause /
    repeat / +10s / next. The gray/colored variant reflects
    availability (prev/next with no neighboring video, -10s/+10s
    already at the edge) or mode (repeat state), not the button's own
    hover state (there are no separate "pressed" frames in the
    playback list). }
  if FPlaybackImages <> nil then begin
    for I := 0 to 5 do begin
      case I of
        0: IconIdx := IfThen(FHasPrevVideo, PLAYBACK_ICON_PREV_ON, PLAYBACK_ICON_PREV_OFF);
        1: IconIdx := IfThen(FPositionSec > 0.01, PLAYBACK_ICON_BACK10_ON, PLAYBACK_ICON_BACK10_OFF);
        2: IconIdx := IfThen(FPlaying, PLAYBACK_ICON_PAUSE, PLAYBACK_ICON_PLAY);
        3: case FRepeatMode of
             vrmAll: IconIdx := PLAYBACK_ICON_REPEAT_ALL;
             vrmOne: IconIdx := PLAYBACK_ICON_REPEAT_ONE;
           else
             IconIdx := PLAYBACK_ICON_REPEAT_OFF;
           end;
        4: IconIdx := IfThen((FDuration > 0) and (FPositionSec < FDuration - 0.01),
             PLAYBACK_ICON_FWD10_ON, PLAYBACK_ICON_FWD10_OFF);
      else
        IconIdx := IfThen(FHasNextVideo, PLAYBACK_ICON_NEXT_ON, PLAYBACK_ICON_NEXT_OFF);
      end;
      if IconIdx < FPlaybackImages.Count then begin
        BtnRect := PlaybackButtonRect(I);
        FPlaybackImages.Draw(Canvas, BtnRect.Left, BtnRect.Top, IconIdx, True);
      end;
    end;
  end;
end;

{ ---------------- TStickerWidget ---------------- }

{ Composites an already-ready ARGB32_Premultiplied buffer
  (AWidth*AHeight*4 bytes) via GDI AlphaBlend — unlike DrawBgraBuffer/
  SetDIBitsToDevice (which just replaces pixels, no alpha), real
  transparency is needed here: stickers (rlottie/TGS especially) are
  almost always drawn on a transparent background. AlphaBlend requires
  a SOURCE HDC, not a raw buffer directly — the buffer is wrapped in a
  temporary DIB section (CreateDIBSection), selected into a compatible
  memory DC, blended, and released. AC_SRC_ALPHA expects PREMULTIPLIED
  alpha — exactly what rlottie provides (see rlottie.pas), no
  conversion needed. AlphaBlend isn't declared by FPC's Windows unit
  (which has only the TBlendFunction type/AC_SRC_* constants, not the
  function itself, confirmed by reading the rtl/win sources) — the
  binding below targets msimg32.dll, a standard part of Windows,
  requiring no new DLLs/dependencies. }
function AlphaBlend(hdcDest: HDC; nXOriginDest, nYOriginDest, nWidthDest, nHeightDest: longint;
  hdcSrc: HDC; nXOriginSrc, nYOriginSrc, nWidthSrc, nHeightSrc: longint;
  ABlendFunction: TBlendFunction): BOOL; stdcall; external 'msimg32.dll' name 'AlphaBlend';

procedure DrawPremultipliedArgbBuffer(ACanvas: TCanvas; ABuf: PByte; AWidth, AHeight: integer);
var
  Bmi: Windows.BITMAPINFO;
  MemDC: HDC;
  Dib: HBITMAP;
  OldBmp: HGDIOBJ;
  Bits: pointer;
  Blend: TBlendFunction;
begin
  FillChar(Bmi, SizeOf(Bmi), 0);
  Bmi.bmiHeader.biSize := SizeOf(Bmi.bmiHeader);
  Bmi.bmiHeader.biWidth := AWidth;
  Bmi.bmiHeader.biHeight := -AHeight;
  Bmi.bmiHeader.biPlanes := 1;
  Bmi.bmiHeader.biBitCount := 32;
  Bmi.bmiHeader.biCompression := BI_RGB;

  MemDC := Windows.CreateCompatibleDC(ACanvas.Handle);
  if MemDC = 0 then begin
    Exit;
  end;
  Dib := Windows.CreateDIBSection(MemDC, Bmi, DIB_RGB_COLORS, Bits, 0, 0);
  if (Dib = 0) or (Bits = nil) then begin
    Windows.DeleteDC(MemDC);
    Exit;
  end;
  Move(ABuf^, Bits^, cardinal(AWidth) * cardinal(AHeight) * 4);
  OldBmp := Windows.SelectObject(MemDC, Dib);

  FillChar(Blend, SizeOf(Blend), 0);
  Blend.BlendOp := AC_SRC_OVER;
  Blend.SourceConstantAlpha := 255;
  Blend.AlphaFormat := AC_SRC_ALPHA;
  AlphaBlend(ACanvas.Handle, 0, 0, AWidth, AHeight, MemDC, 0, 0, AWidth, AHeight, Blend);

  Windows.SelectObject(MemDC, OldBmp);
  Windows.DeleteObject(Dib);
  Windows.DeleteDC(MemDC);
end;

constructor TStickerWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Cursor := crDefault;
  FBgColor := clWindow;
  { The same poll interval as TAnimationWidget/TVideoWidget — see their
    comment. }
  FPollTimer := TTimer.Create(Self);
  FPollTimer.Interval := 33;
  FPollTimer.OnTimer := @PollTick;
  FPollTimer.Enabled := False;
end;

destructor TStickerWidget.Destroy;
begin
  StopLoop;
  ClearBitmaps;
  if FFrameBuf <> nil then begin
    FreeMem(FFrameBuf);
  end;
  inherited Destroy;
end;

procedure TStickerWidget.ClearBitmaps;
begin
  FreeAndNil(FStaticBmp);
end;

procedure TStickerWidget.SetSticker(ARowId: Int64; AFormat: TStickerFormat;
  ANaturalW, ANaturalH: integer; const ALocalPath: utf8string; AMaxW: integer);
var
  OldTargetW, OldTargetH: integer;
begin
  if (ARowId <> FRowId) or (AFormat <> FFormat) then begin
    { The pooled widget was reused for a DIFFERENT message (or the same
      file with a different format — theoretically doesn't happen in
      practice, but cheaper to check than assume) — the same approach
      as TAnimationWidget.SetAnim. }
    StopLoop;
    ClearBitmaps;
    FLocalPath := '';
  end;
  FRowId := ARowId;
  FFormat := AFormat;
  OldTargetW := FTargetW;
  OldTargetH := FTargetH;
  ComputeStickerSize(ANaturalW, ANaturalH, AMaxW, FTargetW, FTargetH);
  if (FTargetW <> OldTargetW) or (FTargetH <> OldTargetH) then begin
    StopLoop;
    ClearBitmaps;
    FLocalPath := '';
    if FFrameBuf <> nil then begin
      FreeMem(FFrameBuf);
      FFrameBuf := nil;
    end;
  end;
  FLocalPath := ALocalPath;
  Invalidate;
end;

procedure TStickerWidget.StartLoop;
var
  Resized: TBGRABitmap;
begin
  if FPlaying or (FLocalPath = '') or (FTargetW <= 0) or (FTargetH <= 0) then begin
    Exit;
  end;
  case FFormat of
    sfTgs: begin
      if FFrameBuf = nil then begin
        GetMem(FFrameBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);
      end;
      FFrameKnownVersion := 0;
      FHaveFrame := False;
      FLottiePlayer := TLottiePlayer.Create(FLocalPath, FTargetW, FTargetH);
      FPlaying := True;
      FPollTimer.Enabled := True;
    end;
    sfWebm: begin
      if FFrameBuf = nil then begin
        GetMem(FFrameBuf, cardinal(FTargetW) * cardinal(FTargetH) * 4);
      end;
      FFrameKnownVersion := 0;
      FHaveFrame := False;
      FAnimPlayer := TAnimationPlayer.Create(FLocalPath, FTargetW, FTargetH);
      FPlaying := True;
      FPollTimer.Enabled := True;
    end;
    sfWebp: begin
      { Static — decoded ONCE (not in a background thread: sticker
        files are orders of magnitude smaller than full-size photos, so
        synchronous decoding here isn't the expensive case that
        justified TPhotoDecodeThread for photos). }
      if FStaticBmp = nil then begin
        try
          FStaticBmp := TBGRABitmap.Create(FLocalPath);
          if (FStaticBmp.Width <> FTargetW) or (FStaticBmp.Height <> FTargetH) then begin
            Resized := FStaticBmp.Resample(FTargetW, FTargetH, rmFineResample) as TBGRABitmap;
            FStaticBmp.Free;
            FStaticBmp := Resized;
          end;
        except
          FreeAndNil(FStaticBmp);
        end;
      end;
      FPlaying := True;
      Invalidate;
    end;
  end;
end;

procedure TStickerWidget.StopLoop;
begin
  FPollTimer.Enabled := False;
  if FLottiePlayer <> nil then begin
    { FreeOnTerminate=True (lottieplayer.pas) — the same convention as
      TAnimationPlayer: StopPlayback asynchronously asks the thread to
      stop, the pointer is forgotten right away, never touching the
      object afterward. }
    FLottiePlayer.StopPlayback;
    FLottiePlayer := nil;
  end;
  if FAnimPlayer <> nil then begin
    FAnimPlayer.StopPlayback;
    FAnimPlayer := nil;
  end;
  FPlaying := False;
end;

procedure TStickerWidget.PollTick(Sender: TObject);
begin
  if FFrameBuf = nil then begin
    Exit;
  end;
  if (FLottiePlayer <> nil) and FLottiePlayer.TryGetFrame(FFrameBuf, FFrameKnownVersion) then begin
    FHaveFrame := True;
    Invalidate;
  end else if (FAnimPlayer <> nil) and FAnimPlayer.TryGetFrame(FFrameBuf, FFrameKnownVersion) then begin
    FHaveFrame := True;
    Invalidate;
  end;
end;

procedure TStickerWidget.Paint;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(ClientRect);
  if (FTargetW <= 0) or (FTargetH <= 0) or (not FPlaying) then begin
    Exit;
  end;
  { sfWebp doesn't need FHaveFrame at all (FStaticBmp is decoded
    synchronously in StartLoop, ready whole right away, not
    frame-by-frame) — the gate applies only to live buffers arriving on
    a timer. }
  if (FFormat in [sfTgs, sfWebm]) and (not FHaveFrame) then begin
    Exit;
  end;
  { FTargetW/FTargetH, NOT Width/Height — the buffer is allocated and
    filled for EXACTLY FTargetW*FTargetH*4 bytes; if the control ever
    reports a Width/Height different from what was actually requested
    in SetBounds (e.g. due to LCL/DPI size recalculation between
    SetBounds and Paint), AlphaBlend would get a destination rectangle
    of a different size than the data in the buffer, and would
    stretch/shrink the frame using AlphaBlend's own, much cruder
    algorithm than our BoxDownscaleArgb. }
  case FFormat of
    sfTgs: if FFrameBuf <> nil then begin
      DrawPremultipliedArgbBuffer(Canvas, FFrameBuf, FTargetW, FTargetH);
    end;
    sfWebm: if FFrameBuf <> nil then begin
      DrawBgraBuffer(Canvas, FFrameBuf, FTargetW, FTargetH);
    end;
    sfWebp: if FStaticBmp <> nil then begin
      FStaticBmp.Draw(Canvas, 0, 0, False);
    end;
  end;
end;

{ ---------------- TMsgScroller ---------------- }

constructor TMsgScroller.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  TabStop := True;
  Color := clWindow;
  FAudioPool := TFPList.Create;
  FAudioActive := TAudioMap.Create;
  FAudioActive.Sorted := True;
  FFilePool := TFPList.Create;
  FFileActive := TFileWidgetMap.Create;
  FFileActive.Sorted := True;
  FPhotoPool := TFPList.Create;
  FPhotoActive := TPhotoWidgetMap.Create;
  FPhotoActive.Sorted := True;
  FAnimPool := TFPList.Create;
  FAnimActive := TAnimationWidgetMap.Create;
  FAnimActive.Sorted := True;
  FVideoPool := TFPList.Create;
  FVideoActive := TVideoWidgetMap.Create;
  FVideoActive.Sorted := True;
  FStickerPool := TFPList.Create;
  FStickerActive := TStickerWidgetMap.Create;
  FStickerActive.Sorted := True;
  FForwardChatAvatars := TForwardAvatarMap.Create;
  FForwardChatAvatars.Sorted := True;
  FForwardUserAvatars := TForwardAvatarMap.Create;
  FForwardUserAvatars.Sorted := True;
  SetLength(FOffsets, 1);
  FOffsets[0] := 0;

  FPlaybackTimer := TTimer.Create(Self);
  FPlaybackTimer.Interval := 250;
  FPlaybackTimer.OnTimer := @PlaybackTick;
  FPlaybackTimer.Enabled := False;

  FCustomEmojiTimer := TTimer.Create(Self);
  FCustomEmojiTimer.Interval := 33;
  FCustomEmojiTimer.OnTimer := @CustomEmojiAnimTick;
  FCustomEmojiTimer.Enabled := True;

  { Debounce for MarkVisibleAsRead — armed (disabled then re-enabled,
    restarting the countdown) on every real scroll-position change in
    ClampScrollTop, so a fast wheel fling sends one viewMessages once
    scrolling actually stops, not one per tick. }
  FMarkReadTimer := TTimer.Create(Self);
  FMarkReadTimer.Interval := 500;
  FMarkReadTimer.OnTimer := @MarkReadTick;
  FMarkReadTimer.Enabled := False;
end;

destructor TMsgScroller.Destroy;
begin
  StopActivePlayer;
  FlushDonePlayer;
  FAudioActive.Free;
  { The widgets themselves aren't freed: they're child controls of
    Self, LCL destroys them along with the parent. }
  FAudioPool.Free;
  FFileActive.Free;
  FFilePool.Free;
  FPhotoActive.Free;
  FPhotoPool.Free;
  FAnimActive.Free;
  FAnimPool.Free;
  FVideoActive.Free;
  FVideoPool.Free;
  FStickerActive.Free;
  FStickerPool.Free;
  ClearForwardAvatars;
  FForwardChatAvatars.Free;
  FForwardUserAvatars.Free;
  inherited Destroy;
end;

procedure TMsgScroller.BindModel(AModel: TTdMessages);
begin
  FModel := AModel;
  FSelAnchorMsg := 0;
  FSelFocusMsg := 0;
  FSelecting := False;
  FScrollTop := 0;
  RebuildOffsets;
  Invalidate;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

procedure TMsgScroller.RebuildOffsets;
var
  I, H, Cnt, ColL, ColR, PreH, PostH, InnerW: integer;
  Ctx: TMsgLayoutCtx;
begin
  { Align/Resize can trigger this while still inside TFrameHistory's
    constructor, when the frame itself has no Parent yet (the
    navigator sets it only AFTER Create) — touching Canvas at that
    point raises EInvalidOperation "Control has no parent window". This
    gets recomputed once a real handle exists: BindModel and the
    following Resize guarantee that. }
  if not HandleAllocated then begin
    SetLength(FOffsets, 1);
    SetLength(FRowIds, 0);
    FOffsets[0] := 0;
    FTotalHeight := 0;
    Exit;
  end;

  Cnt := 0;
  if FModel <> nil then begin
    Cnt := FModel.Count;
  end;

  ColumnBounds(ColL, ColR);
  Ctx.Canvas := Canvas;

  Canvas.Font.Name := 'default';
  Canvas.Font.Height := -13;
  Canvas.Font.Style := [];

  SetLength(FOffsets, Cnt + 1);
  SetLength(FRowIds, Cnt);
  FOffsets[0] := 0;
  for I := 0 to Cnt - 1 do begin
    FRowIds[I] := FModel[I].Id;
    ForwardMetrics(FModel[I], ColR - ColL, PreH, PostH, InnerW);
    { A reply quote (reply_to) is drawn ABOVE the forward quote/content
      — its height is added to PreH separately, not inside
      ForwardMetrics (these are two independent, orthogonal message
      properties: a reply and a forward can technically both occur on
      the same message). }
    PreH := PreH + ReplyExtraH(FModel[I]);
    Ctx.AvailWidth := InnerW;
    H := HEADER_BAR_H + PreH + RendererFor(FModel[I].Kind).Measure(FModel[I], Ctx) + PostH
      + ReactionsH(FModel[I]);
    FOffsets[I + 1] := FOffsets[I] + H + MSG_GAP;
  end;

  FTotalHeight := FOffsets[Cnt];
end;

{ Forward-quote metrics — the single source of truth for both
  RebuildOffsets (row height) and ContentRect/ForwardCardRect/
  ForwardHeaderRect (where to draw), the same approach as ColumnBounds.
  AColW is the FULL COLUMN WIDTH (ColR-ColL, BEFORE subtracting anyone's
  padding) — the quote is structurally the same "header+content" shape
  as the whole block, nested, and reuses exactly the same
  MSG_PAD_H/MSG_PAD_V as the outer (non-nested) block, so the content's
  padding from the quote's frame visually matches an ordinary message's
  padding from the block's frame. FORWARD_HEADER_GAP is the one
  genuinely separate number, and only for one spot: the gap BETWEEN the
  block's main header and the quote's frame (see FORWARD_HEADER_GAP
  above). Not a forward: APreH/APostH/AInnerW match the ordinary block. }
function TMsgScroller.ContentPadV(ARow: TMsgRow): integer;
begin
  { The ordinary vertical gap from the block's header/from the block's
    bottom edge is MSG_PAD_V, except for audio/voice/file/photo/"GIF"/
    video: for all of these, this gap should match MSG_PAD_H=11, not
    the ordinary vertical value (MSG_PAD_V=6). This list grew one entry
    at a time as each new widget type was added — ContentPadV is the
    single place that covers all of them at once (voice reuses
    TAudioWidget, same as audio; "GIF"/video share the same padding
    class as photo, by the same reasoning — all three use
    NaturalMediaSize/ComputePhotoPreviewSize). }
  if (ARow <> nil) and
    (ARow.Kind in [mckAudio, mckVoiceNote, mckFile, mckPhoto, mckAnimation, mckVideo, mckSticker]) then begin
    Result := MSG_PAD_H;
  end else begin
    Result := MSG_PAD_V;
  end;
end;

procedure TMsgScroller.ForwardMetrics(ARow: TMsgRow; AColW: integer;
  out APreH, APostH, AInnerW: integer);
var
  PadV: integer;
begin
  PadV := ContentPadV(ARow);

  if (ARow = nil) or (ARow.ForwardKind = mfoNone) then begin
    APreH := PadV;
    APostH := PadV;
    AInnerW := AColW - 2 * MSG_PAD_H;
    if AInnerW < 20 then begin
      AInnerW := 20;
    end;
    Exit;
  end;
  { Before the content: the gap from the main header (FORWARD_HEADER_GAP)
    + the quote's mini-header (HEADER_BAR_H) + its own gap to the
    content — the same PadV as the ordinary block. After the content:
    the quote's own bottom padding (PadV, symmetric with the top,
    inside the quote itself) + the gap FROM the quote's frame to the
    outer block's edge — the same FORWARD_HEADER_GAP as at the top
    (mirroring the "block header -> quote" gap, not the plain PadV:
    the quote is a nested element with its own padding from its parent
    on both sides, not ordinary content). }
  APreH := FORWARD_HEADER_GAP + HEADER_BAR_H + PadV;
  APostH := PadV + FORWARD_HEADER_GAP;
  { Content width: the quote's frame is inset from the block's edges
    by MSG_PAD_H (like ordinary content from the block), and the
    content inside the frame is inset by the same MSG_PAD_H again. }
  AInnerW := AColW - 4 * MSG_PAD_H;
  if AInnerW < 20 then begin
    AInnerW := 20;
  end;
end;

procedure TMsgScroller.ColumnBounds(out ALeft, ARight: integer);
var
  W: integer;
begin
  { MAX_MSG_W = 0 means the column spans the frame's full width, no cap. }
  W := ClientWidth;
  if (MAX_MSG_W > 0) and (W > MAX_MSG_W) then begin
    W := MAX_MSG_W;
  end;
  ALeft := (ClientWidth - W) div 2;
  ARight := ALeft + W;
end;

function TMsgScroller.IndexAtY(AY: integer): integer;
var
  Lo, Hi, Mid, Cnt: integer;
begin
  Cnt := Length(FOffsets) - 1;
  if Cnt <= 0 then begin
    Result := -1;
    Exit;
  end;
  if AY < 0 then begin
    Result := 0;
    Exit;
  end;
  if AY >= FOffsets[Cnt] then begin
    Result := Cnt - 1;
    Exit;
  end;
  Lo := 0;
  Hi := Cnt - 1;
  while Lo < Hi do begin
    Mid := (Lo + Hi + 1) div 2;
    if FOffsets[Mid] <= AY then begin
      Lo := Mid;
    end else begin
      Hi := Mid - 1;
    end;
  end;
  Result := Lo;
end;

function TMsgScroller.FirstVisible: integer;
begin
  Result := IndexAtY(FScrollTop);
end;

function TMsgScroller.LastVisible: integer;
begin
  Result := IndexAtY(FScrollTop + ClientHeight - 1);
end;

{ ---------------- auto-download ---------------- }

function TMsgScroller.CurrentChatKind: string;
var
  ChatRow: TChatRow;
begin
  if FModel = nil then begin
    Result := '';
    Exit;
  end;
  if FModel.ChatId <> FChatKindChatId then begin
    FChatKindChatId := FModel.ChatId;
    FChatKindCache := '';
    if TdChatList <> nil then begin
      ChatRow := TdChatList.Lookup(FModel.ChatId);
      if ChatRow <> nil then begin
        case ChatRow.Kind of
          ckPrivate:
            if TdChatList.IsBotChat(ChatRow) then begin
              FChatKindCache := 'bots';
            end else begin
              FChatKindCache := 'private';
            end;
          ckSecret:
            FChatKindCache := 'secret';
          ckBasicGroup, ckSupergroup:
            FChatKindCache := 'groups';
          ckChannel:
            FChatKindCache := 'channels';
        end;
      end;
    end;
  end;
  Result := FChatKindCache;
end;

procedure TMsgScroller.MaybeAutoDownload(ARow: TMsgRow);
var
  MediaKind, ChatKind: string;
begin
  if (ARow = nil) or (FModel = nil) or (FormMain = nil) then begin
    Exit;
  end;

  { Stickers — WITHOUT the Auto download settings gate at all (see the
    comment on TTdMessages.EnsureStickerFile, tdmessages.pas): the
    files are tiny, and the whole point of a sticker is an instant
    visual response. Downloading is enough on its own — starting the
    animation is LayoutStickerWidgets's job, on every layout pass, as
    soon as the file is ready, using the same unconditional logic
    already there. }
  if ARow.Kind = mckSticker then begin
    FModel.EnsureStickerFile(ARow);
    Exit;
  end;

  case ARow.Kind of
    mckPhoto: MediaKind := 'images';
    { Voice notes use the same widget and the same "Audio" setting as
      regular audio (see LayoutAudioWidgets) — there's no separate
      category for voice notes in the Auto download settings, and none
      is needed. }
    mckAudio, mckVoiceNote: MediaKind := 'audio';
    mckFile:  MediaKind := 'files';
    mckAnimation: MediaKind := 'gif';
    mckVideo: MediaKind := 'video';
  else
    Exit;
  end;

  ChatKind := CurrentChatKind;
  if ChatKind = '' then begin
    Exit;
  end;
  if not FormMain.AutoDownloadEnabled(MediaKind, ChatKind) then begin
    Exit;
  end;

  case ARow.Kind of
    mckPhoto: begin
      { Both copies — the preview (for inline display in the chat
        itself) and the original (so opening it later is instant) —
        the same thing a first click on a photo already downloads (see
        PhotoWidgetClick), just without the click. }
      FModel.EnsurePhotoFile(ARow);
      FModel.EnsurePhotoBestFile(ARow);
    end;
    mckAudio, mckVoiceNote:
      FModel.EnsurePlayableFile(ARow);
    mckFile:
      FModel.EnsureDocFile(ARow);
    mckAnimation: begin
      { With auto-download enabled, a "GIF" isn't just downloaded but
        immediately played on a loop. AnimAutoPlay is a permanent mark
        on the row (not a one-shot command): actually starting playback
        via StartLoop is LayoutAnimationWidgets's job, on every layout
        pass, as soon as the file is ready (see its comment) — here it
        only needs requesting the download and setting the flag. }
      FModel.EnsureAnimFile(ARow);
      ARow.AnimAutoPlay := True;
    end;
    mckVideo:
      { Unlike a "GIF" — download ONLY, no auto-start: a video with
        sound starting to play on its own while scrolled past would be
        intrusive UX (auto-download was requested for video, not
        auto-playback). }
      FModel.EnsureVideoFile(ARow);
  end;
end;

procedure TMsgScroller.AutoDownloadVisible;
var
  I, Lo, Hi: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  Lo := FirstVisible;
  Hi := LastVisible;
  if (Lo < 0) or (Hi < 0) then begin
    Exit;
  end;
  for I := Lo to Hi do begin
    MaybeAutoDownload(FModel[I]);
    { No Auto download gate, same as stickers/video-thumbnail above —
      see the comment on TTdMessages.EnsureCustomEmojiForRow. Cheap to
      call unconditionally: it scans ARow.Entities and no-ops at once
      for the common case of a row with no mekCustomEmoji entity. }
    FModel.EnsureCustomEmojiForRow(FModel[I]);
  end;
end;

procedure TMsgScroller.MarkVisibleAsRead;
var
  I, Lo, Hi, N: integer;
  Ids: array of Int64;
  R: TMsgRow;
begin
  if (FModel = nil) or (FormMain = nil) or FormMain.Invisible then begin
    Exit;
  end;
  Lo := FirstVisible;
  Hi := LastVisible;
  if (Lo < 0) or (Hi < 0) then begin
    Exit;
  end;
  SetLength(Ids, Hi - Lo + 1);
  N := 0;
  for I := Lo to Hi do begin
    R := FModel[I];
    if (R <> nil) and (not R.IsOutgoing) then begin
      Ids[N] := R.Id;
      Inc(N);
    end;
  end;
  if N = 0 then begin
    Exit;
  end;
  SetLength(Ids, N);
  FModel.MarkRead(Ids);
end;

procedure TMsgScroller.MarkReadTick(Sender: TObject);
begin
  FMarkReadTimer.Enabled := False;
  MarkVisibleAsRead;
end;

procedure TMsgScroller.PrefetchAutoDownload(ADirection: integer);
var
  Idx, EndIdx: integer;
begin
  if (FModel = nil) or (ADirection = 0) then begin
    Exit;
  end;
  { EnsureCustomEmojiForRow belongs here alongside MaybeAutoDownload, not
    only in AutoDownloadVisible (ModelChanged) — a real, reported bug:
    scrolling to reveal an OLDER row that was already loaded (no new
    message arrived, no model change at all) never ran it, so a custom
    emoji entity sitting in already-cached history could go forever
    unrequested (confirmed directly: its custom_emoji_id never once
    appeared in a getCustomEmojiStickers request in tdlib_raw.log, even
    though the message was fully visible on screen — ModelChanged simply
    never fired for it after the initial load). Same idempotent,
    no-op-if-already-known/pending guard as everywhere else in this
    project — safe to call on every scroll tick. }
  if ADirection > 0 then begin
    Idx := LastVisible + 1;
    EndIdx := Min(FModel.Count - 1, LastVisible + AUTODL_PREFETCH_MESSAGES);
    while Idx <= EndIdx do begin
      MaybeAutoDownload(FModel[Idx]);
      FModel.EnsureCustomEmojiForRow(FModel[Idx]);
      Inc(Idx);
    end;
  end else begin
    Idx := FirstVisible - 1;
    EndIdx := Max(0, FirstVisible - AUTODL_PREFETCH_MESSAGES);
    while Idx >= EndIdx do begin
      MaybeAutoDownload(FModel[Idx]);
      FModel.EnsureCustomEmojiForRow(FModel[Idx]);
      Dec(Idx);
    end;
  end;
end;

function TMsgScroller.BlockRect(AIndex: integer): TRect;
var
  ColL, ColR: integer;
begin
  ColumnBounds(ColL, ColR);
  Result := Rect(ColL, FOffsets[AIndex] - FScrollTop, ColR,
    FOffsets[AIndex] - FScrollTop + (FOffsets[AIndex + 1] - FOffsets[AIndex] - MSG_GAP));
end;

function TMsgScroller.ContentRect(AIndex: integer): TRect;
var
  BlockH, ContentH, TopY, ColL, ColR, PreH, PostH, InnerW: integer;
  R: TMsgRow;
begin
  ColumnBounds(ColL, ColR);
  R := FModel[AIndex];
  ForwardMetrics(R, ColR - ColL, PreH, PostH, InnerW);
  PreH := PreH + ReplyExtraH(R);
  BlockH := FOffsets[AIndex + 1] - FOffsets[AIndex] - MSG_GAP;
  ContentH := BlockH - HEADER_BAR_H - PreH - PostH - ReactionsH(R);
  TopY := FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + PreH;
  if (R <> nil) and (R.ForwardKind <> mfoNone) then begin
    { The quote's content sits inside the ForwardCardRect frame, which
      already has its own MSG_PAD_H from the block's edges (like
      ordinary content); one more MSG_PAD_H is the content's own
      padding FROM that frame (see ForwardMetrics) — the same padding
      value as ordinary message content has from its block, not a
      separate number. }
    Result := Rect(ColL + 2 * MSG_PAD_H, TopY,
      ColR - 2 * MSG_PAD_H, TopY + ContentH);
    Exit;
  end;
  Result := Rect(ColL + MSG_PAD_H, TopY, ColR - MSG_PAD_H, TopY + ContentH);
end;

{ Wraps ARow.Reactions onto as many rows as needed to fit AWidth (the
  same "inner column width" convention as ForwardMetrics' AInnerW —
  AWidth is ALREADY net of the strip's own MSG_PAD_H inset on both
  sides, see the call sites). Each slot's PillRect is in the strip's
  OWN local space (0,0 = top-left of the first row's first pill, before
  either the MSG_PAD_H horizontal inset or the vertical top margin that
  centers a single row within HEADER_BAR_H are added back by the
  caller — see PaintReactions). A pill only wraps to a new row if it's
  not the first on its current row (X > 0) — a single reaction wider
  than AWidth still gets drawn (clipped by whatever contains it, same
  as any other overlong content in this file) rather than looping
  forever trying to fit it on an empty row.

  Font metrics (bold vs. not, for a chosen reaction) affect a pill's
  measured width, so Canvas.Font is set here for the duration of the
  measurement and restored on exit — this same function runs from
  RebuildOffsets (mid-loop, between other rows' Measure calls that
  expect their OWN font state already set up by the caller) as well as
  from PaintReactions, and must not leak its own font settings into
  either. }
function TMsgScroller.LayoutReactions(ARow: TMsgRow; AWidth: integer;
  out ATotalH: integer): TReactionSlotArray;
var
  I, X, Y, PillW, IconW, TextW, RowCount: integer;
  React: TMsgReaction;
  SavedName: string;
  SavedHeight: integer;
  SavedStyle: TFontStyles;
begin
  SetLength(Result, Length(ARow.Reactions));
  ATotalH := 0;
  if Length(ARow.Reactions) = 0 then begin
    Exit;
  end;

  SavedName := Canvas.Font.Name;
  SavedHeight := Canvas.Font.Height;
  SavedStyle := Canvas.Font.Style;
  try
    Canvas.Font.Name := 'default';
    Canvas.Font.Height := -11;

    X := 0;
    Y := 0;
    RowCount := 1;
    for I := 0 to High(ARow.Reactions) do begin
      React := ARow.Reactions[I];
      if React.IsChosen then begin
        Canvas.Font.Style := [fsBold];
      end else begin
        Canvas.Font.Style := [];
      end;
      TextW := Canvas.TextWidth(IntToStr(React.TotalCount));

      { Icon width doesn't depend on whether the bitmap has actually
        arrived yet (EmojiBitmapFor/CustomEmojiBitmapFor can still
        return nil here) — both always render at a fixed HEADER_H once
        ready, so reserving that width now keeps the pill from silently
        resizing (and every pill after it re-wrapping) the moment a
        custom emoji finishes downloading mid-scroll. }
      IconW := 0;
      case React.Kind of
        rcEmoji, rcCustomEmoji: begin
          IconW := HEADER_H;
        end;
        rcPaid: begin
          Canvas.Font.Style := [];
          IconW := Canvas.TextWidth('★');
        end;
      end;

      PillW := 2 * REACTION_PILL_PAD + TextW;
      if IconW > 0 then begin
        Inc(PillW, IconW + MSG_ICON_GAP);
      end;

      if (X > 0) and (X + PillW > AWidth) then begin
        X := 0;
        Inc(Y, REACTION_PILL_H + REACTION_ROW_GAP);
        Inc(RowCount);
      end;

      Result[I].PillRect := Rect(X, Y, X + PillW, Y + REACTION_PILL_H);
      Result[I].IconW := IconW;

      Inc(X, PillW + REACTION_GAP);
    end;

    ATotalH := HEADER_BAR_H + (RowCount - 1) * (REACTION_PILL_H + REACTION_ROW_GAP);
  finally
    Canvas.Font.Name := SavedName;
    Canvas.Font.Height := SavedHeight;
    Canvas.Font.Style := SavedStyle;
  end;
end;

function TMsgScroller.ReactionsH(ARow: TMsgRow): integer;
var
  ColL, ColR: integer;
begin
  if (ARow = nil) or (Length(ARow.Reactions) = 0) then begin
    Result := 0;
    Exit;
  end;
  ColumnBounds(ColL, ColR);
  LayoutReactions(ARow, (ColR - ColL) - 2 * MSG_PAD_H, Result);
end;

{ The strip at the very bottom of the block, flush with its bottom edge
  — RebuildOffsets already folded ReactionsH into the block's total
  height, so BlockRect's own Bottom already accounts for it; this is
  just that same bottom slice. An empty Rect (Top=Bottom) when the row
  has no reactions — callers check ReactionsH/Length(Reactions) first,
  same as everywhere else in this file (see PaintReactions). }
function TMsgScroller.ReactionsRect(AIndex: integer): TRect;
var
  BR: TRect;
  H: integer;
begin
  BR := BlockRect(AIndex);
  H := ReactionsH(FModel[AIndex]);
  Result := Rect(BR.Left, BR.Bottom - H, BR.Right, BR.Bottom);
end;

{ Draws the reaction strip. The OUTER strip is the same visual language
  as the message header (SENDER_HEADER_OPACITY tint, HEADER_BAR_H tall
  for one row, taller when LayoutReactions wraps to more): square top
  (butting against the content above, no gap of its own — ReactionsH is
  simply added to the block's total height, with no extra padding
  before it), rounded bottom (flush with the block's own rounded bottom
  edge, mirroring how the main header squares off ITS bottom against
  the content below it).

  Each INDIVIDUAL chip additionally gets its own pill/capsule outline,
  closer to the native client — rounded by REACTION_PILL_CORNER_RADIUS
  (constants.pas), REACTION_PILL_H tall (not the taller HEADER_BAR_H —
  inset within the outer strip, not flush with it), tinted with the
  sender's color at REACTION_PILL_OPACITY, or REACTION_PILL_CHOSEN_
  OPACITY for a reaction this account has added. PillRadius is clamped
  to half the pill's own WIDTH too, the same defensive pattern used
  everywhere else in this file that rounds a short strip (see e.g.
  ForwardHeaderRect's HeaderRadius) — a pill narrow enough that
  width < height would otherwise distort into an unintended shape
  rather than a clean capsule.

  The count is bold for a chosen reaction, but always plain black
  (clWindowText) either way — the sender-color highlight lives ONLY in
  the pill's own opacity now, not the text on top of it (direct
  correction: the count used to also switch to the sender's color,
  which read as illegible/wrong against the already-stronger pill
  tint). }
procedure TMsgScroller.PaintReactions(AIndex: integer; ARow: TMsgRow);
var
  Rect0, PillRect: TRect;
  Radius, PillRadius, I, ColL, ColR, AWidth, TotalH, TopMargin: integer;
  Slots: TReactionSlotArray;
  Bmp: TBGRABitmap;
  CountStr: string;
  Clr: TColor;
  React: TMsgReaction;
  Opacity: double;
begin
  Rect0 := ReactionsRect(AIndex);
  if Rect0.Bottom <= Rect0.Top then begin
    Exit;
  end;
  Clr := SenderColor(ARow);
  Radius := Min(MSG_CORNER_RADIUS, (Rect0.Bottom - Rect0.Top) div 2);
  PaintRoundRectAA(Canvas, Rect0, Radius, [rrTopLeftSquare, rrTopRightSquare],
    BlendWithBackground(Clr, SENDER_HEADER_OPACITY, clWindow), clNone, 1, True);

  ColumnBounds(ColL, ColR);
  AWidth := (ColR - ColL) - 2 * MSG_PAD_H;
  Slots := LayoutReactions(ARow, AWidth, TotalH);
  { Centers a single row within HEADER_BAR_H exactly as before wrapping
    existed (3px top/bottom at the current constants); LayoutReactions'
    own coordinates already stack any further wrapped rows below the
    first at this same margin, see its ATotalH formula. }
  TopMargin := (HEADER_BAR_H - REACTION_PILL_H) div 2;

  Canvas.Font.Name := 'default';
  Canvas.Font.Height := -11;

  for I := 0 to High(ARow.Reactions) do begin
    React := ARow.Reactions[I];
    PillRect := Rect(
      Rect0.Left + MSG_PAD_H + Slots[I].PillRect.Left,
      Rect0.Top + TopMargin + Slots[I].PillRect.Top,
      Rect0.Left + MSG_PAD_H + Slots[I].PillRect.Right,
      Rect0.Top + TopMargin + Slots[I].PillRect.Bottom);

    if React.IsChosen then begin
      Opacity := REACTION_PILL_CHOSEN_OPACITY;
    end else begin
      Opacity := REACTION_PILL_OPACITY;
    end;
    PillRadius := Min(REACTION_PILL_CORNER_RADIUS, (PillRect.Right - PillRect.Left) div 2);
    PaintRoundRectAA(Canvas, PillRect, PillRadius, [],
      BlendWithBackground(Clr, Opacity, clWindow), clNone, 1, True);
    Canvas.Brush.Style := bsClear;

    Bmp := nil;
    case React.Kind of
      rcEmoji: begin
        Bmp := EmojiBitmapFor(React.Emoji, HEADER_H);
      end;
      rcCustomEmoji: begin
        if React.CustomEmojiId <> 0 then begin
          Bmp := CustomEmojiBitmapFor(React.CustomEmojiId, HEADER_H);
        end;
      end;
    end;

    if Bmp <> nil then begin
      Bmp.Draw(Canvas, PillRect.Left + REACTION_PILL_PAD,
        PillRect.Top + (REACTION_PILL_H - Bmp.Height) div 2, False);
    end else if React.Kind = rcPaid then begin
      { No downloaded glyph for a Stars reaction — a plain text marker
        instead, cheap enough not to need its own asset. }
      Canvas.Font.Style := [];
      Canvas.Font.Color := TColor($00A9F4);   { RGB(244, 169, 0) — gold }
      Canvas.TextOut(PillRect.Left + REACTION_PILL_PAD,
        PillRect.Top + (REACTION_PILL_H - Canvas.TextHeight('★')) div 2, '★');
    end;

    CountStr := IntToStr(React.TotalCount);
    if React.IsChosen then begin
      Canvas.Font.Style := [fsBold];
    end else begin
      Canvas.Font.Style := [];
    end;
    Canvas.Font.Color := clWindowText;
    Canvas.TextOut(PillRect.Left + REACTION_PILL_PAD + Slots[I].IconW + MSG_ICON_GAP * Ord(Slots[I].IconW > 0),
      PillRect.Top + (REACTION_PILL_H - Canvas.TextHeight(CountStr)) div 2, CountStr);
  end;
end;

{ The quote's whole frame (fill/outline) — from the end of the main
  header plus FORWARD_HEADER_GAP (the one gap specific to the quote),
  down to the quote's inner bottom padding after ContentRect (see
  ForwardMetrics: APostH = 2*MSG_PAD_V, the first MSG_PAD_V is exactly
  this bottom padding). Horizontally, the same MSG_PAD_H as ordinary
  (non-nested) content has from the block — see the comment on
  ForwardMetrics. Not a forward: returns an empty Rect, the caller must
  check ForwardKind before calling. }
function TMsgScroller.ForwardCardRect(AIndex: integer): TRect;
var
  ColL, ColR: integer;
  CR: TRect;
begin
  ColumnBounds(ColL, ColR);
  CR := ContentRect(AIndex);
  { ReplyExtraH: if the message ALSO has a reply quote (reply_to), it's
    drawn first, and the forward card is shifted below it. The bottom
    padding is ContentPadV(ARow), NOT bare MSG_PAD_V: for audio it's
    11px (matching the other three sides), not the ordinary 6px — this
    used to be hardcoded to MSG_PAD_V, making the audio widget's
    bottom padding inside a forward card narrower than the other
    three sides. }
  Result := Rect(ColL + MSG_PAD_H,
    FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + ReplyExtraH(FModel[AIndex]) + FORWARD_HEADER_GAP,
    ColR - MSG_PAD_H, CR.Bottom + ContentPadV(FModel[AIndex]));
end;

{ The "avatar+name+time" row inside the quote — the top strip of
  ForwardCardRect, HEADER_BAR_H tall (the same value as the block's
  main header — the quote is structurally the same "header+content"
  shape, see ForwardMetrics). }
function TMsgScroller.ForwardHeaderRect(AIndex: integer): TRect;
var
  Card: TRect;
begin
  Card := ForwardCardRect(AIndex);
  Result := Rect(Card.Left, Card.Top, Card.Right, Card.Top + HEADER_BAR_H);
end;

{ FORWARD_HEADER_GAP is the gap FROM THE MAIN HEADER to the reply quote
  box — the same constant (not just an equal value) used by the
  forward card, so the quote sits exactly as far from the main
  message's top edge as a forwarded message does. Reusing this
  constant rather than defining a separate REPLY_TOP_GAP with the same
  number keeps them from drifting apart at a later edit. "REPLY_BOX_H"
  below is the box itself; the gap AFTER it (to the forward card, if
  any, or to the content) is the ordinary MSG_PAD_V, same as everything
  else in ForwardMetrics — see the ReplyExtraH calls in
  RebuildOffsets/ContentRect/ForwardCardRect: it's always added ON TOP
  of the already-computed PreH from ForwardMetrics (which itself starts
  with MSG_PAD_V for ordinary content or FORWARD_HEADER_GAP for a
  forward card) — so "the gap after the box" falls out automatically
  from the existing PreH, rather than being a separate term here. }
function TMsgScroller.ReplyExtraH(ARow: TMsgRow): integer;
begin
  if (ARow = nil) or (ARow.ReplyMessageId = 0) then begin
    Result := 0;
  end else begin
    Result := FORWARD_HEADER_GAP + REPLY_BOX_H;
  end;
end;

{ The reply quote box — right below the block's main header, at the
  same gap (FORWARD_HEADER_GAP) as a forward card sits from it. If the
  message ALSO has a forward, the forward card and content are shifted
  below it — see ReplyExtraH in ForwardCardRect/ContentRect/
  RebuildOffsets. }
function TMsgScroller.ReplyBoxRect(AIndex: integer): TRect;
var
  ColL, ColR, TopY: integer;
begin
  ColumnBounds(ColL, ColR);
  TopY := FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + FORWARD_HEADER_GAP;
  Result := Rect(ColL + MSG_PAD_H, TopY, ColR - MSG_PAD_H, TopY + REPLY_BOX_H);
end;

{ Clamps and applies the position without the "near the top — load
  more" notification. Internal bookkeeping (ModelChanged, Resize) sets
  FScrollTop programmatically and must NOT be interpreted as "the user
  scrolled and wants more" — loading a short history further is
  MaybeLoadMore's job in TFrameHistory.ModelChanged, called separately,
  exactly once. }
procedure TMsgScroller.ClampScrollTop(AValue: integer);
var
  MaxTop, OldTop: integer;
begin
  MaxTop := FTotalHeight - ClientHeight;
  if MaxTop < 0 then begin
    MaxTop := 0;
  end;
  if AValue < 0 then begin
    AValue := 0;
  end;
  if AValue > MaxTop then begin
    AValue := MaxTop;
  end;
  if AValue = FScrollTop then begin
    Exit;
  end;
  OldTop := FScrollTop;
  FScrollTop := AValue;
  Invalidate;
  { Lookahead auto-download for AUTODL_PREFETCH_MESSAGES messages ahead
    in the scroll direction — the single place through which EVERY real
    position change passes (wheel, keys, scrollbar drag, programmatic
    changes like ScrollToBottom), see the comment on SetScrollTop. }
  if AValue > OldTop then begin
    PrefetchAutoDownload(1);
  end else if AValue < OldTop then begin
    PrefetchAutoDownload(-1);
  end;
  { Debounced mark-as-read — see MarkVisibleAsRead/FMarkReadTimer's own
    comments. Disable-then-enable restarts the countdown, so the tick
    only actually fires once scrolling has stopped for a moment, not on
    every one of these calls. }
  FMarkReadTimer.Enabled := False;
  FMarkReadTimer.Enabled := True;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

{ The public setter — for actual user scrolling only (wheel, keys, the
  native scrollbar). OnNearTop used to fire from right here, INSIDE the
  nested chain ModelChanged -> ScrollToBottom -> SetScrollTop ->
  OnNearTop -> LoadOlder, before ever returning to ModelChanged itself
  — that chain worked, but was reentrant and fragile. Now programmatic
  position changes go through ClampScrollTop and never reach OnNearTop
  at all. }
procedure TMsgScroller.SetScrollTop(AValue: integer);
begin
  ClampScrollTop(AValue);
  { Deliberately NOT inside ClampScrollTop's "value changed" check: if
    the user has already hit the very top (FScrollTop=0=MaxTop) and
    keeps scrolling the wheel up, the clamped AValue matches the
    already-current FScrollTop — and if OnNearTop only fired on change,
    loading older history would stop firing entirely right when it's
    needed most. ScrollerNearTop is idempotent (guarded by
    LoadingOlder/OldestLoaded), so a repeat call is safe. }
  if (FScrollTop <= NEAR_TOP_PX) and Assigned(FOnNearTop) then begin
    FOnNearTop(Self);
  end;
end;

procedure TMsgScroller.ScrollToBottom;
begin
  ClampScrollTop(FTotalHeight - ClientHeight);
end;

procedure TMsgScroller.ModelChanged;
var
  WasAtBottom: boolean;
  OldMax, OldCount: integer;
  AnchorId: Int64;
  AnchorIdx, AnchorOldOffset, AnchorNewOffset: integer;
  PendingIdx: integer;
begin
  OldCount := Length(FRowIds);
  OldMax := FTotalHeight - ClientHeight;
  { "Was at the bottom" only counts when a scrollable area actually
    existed and we were at its end. OldMax<=0 (the whole list fit on
    screen) used to count as "at the bottom" for ANY such case — which
    made a short, still-loading chat (MaybeLoadMore fetches more
    history on its own while there isn't enough content to fill the
    screen) jump to the bottom on every load, defeating the user's
    attempt to scroll up BEFORE the list grew taller than the screen.
    For OldCount=0 (the very first time a chat is opened), the bottom
    is still forced explicitly — there's nothing to anchor to. }
  WasAtBottom := (OldCount > 0) and (OldMax > 0) and (FScrollTop >= OldMax - 4);

  { The message in the top visible row is remembered — after loading
    more history (LoadOlder adds content ABOVE), it's returned to the
    same spot in the window, otherwise the list would visibly jump.

    IMPORTANT: the id comes from FRowIds, our OWN snapshot of the same
    vintage as FOffsets/AnchorIdx — NOT from FModel[AnchorIdx]. By the
    time ModelChanged is called, the model (TTdMessages) has already
    been rebuilt (Rebuild ran before FOnChanged), while FOffsets/FRowIds
    are still the old ones. LoadOlder inserts new messages AT THE START
    of the list, shifting every other index; FModel[the same index]
    after such an insert is an ENTIRELY DIFFERENT message. This used to
    show up as rows jumping around when loading more during an
    upward scroll — the old index was silently read from data that had
    already shifted. }
  AnchorId := 0;
  AnchorOldOffset := 0;
  AnchorIdx := IndexAtY(FScrollTop);
  if (AnchorIdx >= 0) and (AnchorIdx < Length(FRowIds)) then begin
    AnchorId := FRowIds[AnchorIdx];
    AnchorOldOffset := FScrollTop - FOffsets[AnchorIdx];
  end;

  RebuildOffsets;

  if (OldCount = 0) or WasAtBottom then begin
    ScrollToBottom;
  end else if AnchorId <> 0 then begin
    AnchorIdx := FModel.IndexOfId(AnchorId);
    if AnchorIdx >= 0 then begin
      AnchorNewOffset := FOffsets[AnchorIdx];
      ClampScrollTop(AnchorNewOffset + AnchorOldOffset);
    end else begin
      ClampScrollTop(FScrollTop);
    end;
  end else begin
    ClampScrollTop(FScrollTop);
  end;

  { Waiting for a file to download before starting playback (a play
    click on a not-yet-downloaded track, see AudioPlayClick) — the path
    may have arrived in this very update. }
  if FPendingPlayMsgId <> 0 then begin
    PendingIdx := FModel.IndexOfId(FPendingPlayMsgId);
    if (PendingIdx >= 0) and (PlayableLocalPath(FModel[PendingIdx]) <> '') then begin
      StartPlayback(FModel[PendingIdx]);
      FPendingPlayMsgId := 0;
    end;
  end;

  { Same for "Save as..."/"Show in folder" on a not-yet-downloaded
    file, see FileWidgetSaveAsClick/FileWidgetShowInFolderClick. }
  if FPendingSaveMsgId <> 0 then begin
    PendingIdx := FModel.IndexOfId(FPendingSaveMsgId);
    if (PendingIdx >= 0) and (FModel[PendingIdx].DocLocalPath <> '') then begin
      case FPendingFileAction of
        pfaSaveDialog:   SaveDocFile(FModel[PendingIdx]);
        pfaShowInFolder: ShowDocInFolder(FModel[PendingIdx].DocLocalPath);
      end;
      FPendingSaveMsgId := 0;
      FPendingFileAction := pfaNone;
    end;
  end;

  { Same for photos, see
    PhotoWidgetSaveAsClick/PhotoWidgetShowInFolderClick.
    PhotoBestLocalPath (the original), not PhotoLocalPath (the preview
    copy) — both menu actions wait for the original specifically, see
    the comment on TMsgRow.PhotoBestFileId. }
  if FPendingPhotoMsgId <> 0 then begin
    PendingIdx := FModel.IndexOfId(FPendingPhotoMsgId);
    if (PendingIdx >= 0) and (FModel[PendingIdx].PhotoBestLocalPath <> '') then begin
      case FPendingPhotoAction of
        pfaSaveDialog:   SavePhotoFile(FModel[PendingIdx]);
        pfaShowInFolder: ShowDocInFolder(FModel[PendingIdx].PhotoBestLocalPath);
      end;
      FPendingPhotoMsgId := 0;
      FPendingPhotoAction := pfaNone;
    end;
  end;

  { Opening a chat and new messages pass through HERE, not
    ClampScrollTop — that one only prefetches its message window on a
    real scroll position change, and the chat's very first page (plus
    any message arriving straight into the already-visible area
    without scrolling) would otherwise never trigger auto-download at
    all. }
  AutoDownloadVisible;
  { Same reasoning as AutoDownloadVisible above — called directly, not
    through FMarkReadTimer: ModelChanged already fires at a throttled
    cadence (MESSAGES_COALESCE_MS upstream), no extra debounce needed
    here. }
  MarkVisibleAsRead;

  Invalidate;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

procedure TMsgScroller.Resize;
begin
  inherited Resize;
  { Also outside TFrameHistory.ModelChanged's try/except wrapper:
    Resize is triggered by LCL directly (window resize, the splitter),
    not by ModelChanged. RebuildOffsets does the same real-message
    measuring as there, so it carries the same risks. }
  try
    RebuildOffsets;
    ClampScrollTop(FScrollTop);
  except
  end;
  Invalidate;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

function TMsgScroller.ResolveSelection(out ALowIdx, AHighIdx, ALowChar, AHighChar: integer): boolean;
var
  AnchorIdx, FocusIdx: integer;
begin
  Result := False;
  ALowIdx := -1;
  AHighIdx := -1;
  ALowChar := 0;
  AHighChar := 0;
  if (FModel = nil) or (FSelAnchorMsg = 0) or (FSelFocusMsg = 0) then begin
    Exit;
  end;
  AnchorIdx := FModel.IndexOfId(FSelAnchorMsg);
  FocusIdx := FModel.IndexOfId(FSelFocusMsg);
  if (AnchorIdx < 0) or (FocusIdx < 0) then begin
    Exit;
  end;
  if (AnchorIdx = FocusIdx) and (FSelAnchorChar = FSelFocusChar) then begin
    Exit;   { empty selection — a plain click, no drag }
  end;
  if AnchorIdx <= FocusIdx then begin
    ALowIdx := AnchorIdx;
    ALowChar := FSelAnchorChar;
    AHighIdx := FocusIdx;
    AHighChar := FSelFocusChar;
  end else begin
    ALowIdx := FocusIdx;
    ALowChar := FSelFocusChar;
    AHighIdx := AnchorIdx;
    AHighChar := FSelAnchorChar;
  end;
  Result := True;
end;

procedure TMsgScroller.RangeForRow(AIndex, ALowIdx, AHighIdx, ALowChar, AHighChar,
  ATextLen: integer; out ASelStart, ASelEnd: integer);
begin
  if ALowIdx = AHighIdx then begin
    ASelStart := Min(ALowChar, AHighChar);
    ASelEnd := Max(ALowChar, AHighChar);
  end else if AIndex = ALowIdx then begin
    ASelStart := ALowChar;
    ASelEnd := ATextLen;
  end else if AIndex = AHighIdx then begin
    ASelStart := 0;
    ASelEnd := AHighChar;
  end else begin
    ASelStart := 0;
    ASelEnd := ATextLen;
  end;
end;

procedure TMsgScroller.ClearForwardAvatars;
var
  I: integer;
begin
  for I := 0 to FForwardChatAvatars.Count - 1 do begin
    FForwardChatAvatars.Data[I].Free;
  end;
  FForwardChatAvatars.Clear;
  for I := 0 to FForwardUserAvatars.Count - 1 do begin
    FForwardUserAvatars.Data[I].Free;
  end;
  FForwardUserAvatars.Clear;
end;

{ A forward's source avatar. AOwned=False (the ordinary case) means the
  result lives in FForwardChatAvatars/FForwardUserAvatars, and the
  caller must NOT free it. AOwned=True is a "photo not downloaded yet"
  snapshot (see below), which the caller must free itself. nil means
  there's nothing to build one from at all (mfoHiddenUser, no numeric
  id — see the call in PaintForwardCard, which has its own cache-free
  fallback). The data source is TChatRow (mfoChat/mfoChannel, via
  ForwardChatId through TdChatList) or nothing but a name (mfoUser —
  the project has no downloaded photos of arbitrary users yet,
  tdusers.pas only stores name/color). }
function TMsgScroller.ForwardAvatarBmp(ARow: TMsgRow; out AOwned: boolean): TBGRABitmap;
var
  Idx: integer;
  Id: Int64;
  Map: TForwardAvatarMap;
  C: TChatRow;
  L: TTdChats;
  SrcName: utf8string;
begin
  Result := nil;
  AOwned := False;
  if ARow = nil then begin
    Exit;
  end;

  case ARow.ForwardKind of
    mfoUser: begin
      Map := FForwardUserAvatars;
      Id := ARow.ForwardUserId;
    end;
    mfoChat, mfoChannel: begin
      Map := FForwardChatAvatars;
      Id := ARow.ForwardChatId;
    end;
  else
    Exit;   { mfoNone/mfoHiddenUser — no stable id, see the comment above }
  end;
  if Id = 0 then begin
    Exit;
  end;

  Idx := Map.IndexOf(Id);
  if Idx >= 0 then begin
    Result := Map.Data[Idx];
    Exit;
  end;

  SrcName := ForwardSourceName(ARow);
  if ARow.ForwardKind in [mfoChat, mfoChannel] then begin
    C := nil;
    L := TdChatList;
    if L <> nil then begin
      C := L.Lookup(Id);
    end;
    if C <> nil then begin
      { The chat list only downloads the real photo for rows actually
        visible in the TDrawGrid (framechats.pas:757,
        TTdChats.EnsureAvatar) — a forward's source usually isn't one
        of them (it's someone ELSE's channel/group, not necessarily in
        our chat list). Without an explicit request here, PhotoPath
        would stay empty forever, and only Minithumb would be drawn —
        deliberately small and blurry (Telegram itself generates it
        that way, a "placeholder while loading", not a real
        thumbnail). }
      L.EnsureAvatar(C);
      Result := RenderAvatarBmp(C.PhotoPath, C.Minithumb, SrcName, Id, HEADER_H, True);
      if C.PhotoPath = '' then begin
        { The real photo isn't downloaded yet — NOT cached: the next
          repaint (scroll, a new message, anything) will try again, and
          as soon as EnsureAvatar finishes downloading it, the real
          image will replace the Minithumb. The result therefore
          doesn't belong to the cache — the caller must free it itself
          (otherwise a leak: RenderAvatarBmp creates a new TBGRABitmap
          on every such call). Not ideal (decoding the Minithumb on
          every Paint until the file is ready), but cheap and
          temporary — there are rarely many quotes on screen at once. }
        AOwned := True;
        Exit;
      end;
    end else begin
      Result := RenderAvatarBmp('', '', SrcName, Id, HEADER_H, True);
    end;
  end else begin
    { mfoUser — the project has no mechanism at all for downloading
      photos of arbitrary users, so there's no upgrade coming — it's
      safe to cache the initials permanently. }
    Result := RenderAvatarBmp('', '', SrcName, Id, HEADER_H, True);
  end;
  if Result <> nil then begin
    Map.Add(Id, Result);
  end;
end;

{ A forward quote — a frame (filled the same way as the outer block's
  backing, SENDER_BG_OPACITY) with its own "avatar+name+time" row
  inside it, with its OWN backing (SENDER_HEADER_OPACITY, rounded only
  at the top corners — the same "draw it all rounded and square off
  the bottom with a FillRect" approach as the block's main header, see
  Paint) — both colored with the source's color, not the sender's. The
  frame's outline is drawn separately, in Paint, AFTER the quote's
  content — the same order as the outer block (the outline on top of
  everything). The name is a link (cursor changes to a hand in
  MouseMove) only for mfoChannel: only there does TDLib provide the
  source post's message_id at all, without which getMessageLink has
  nothing to resolve (see TMsgForwardKind in tdmessages.pas — privacy
  forbids building a link for the other cases). }
procedure TMsgScroller.PaintForwardCard(AIndex: integer; ARow: TMsgRow);
var
  CardRect, HeaderRect: TRect;
  Clr: TColor;
  Radius, HeaderRadius, AvX, AvY, NameX: integer;
  AvBmp: TBGRABitmap;
  FreeAvBmp: boolean;
  TimeStr, S: string;
  LocalDT: TDateTime;
begin
  CardRect := ForwardCardRect(AIndex);
  HeaderRect := ForwardHeaderRect(AIndex);
  Clr := ForwardSourceColor(ARow);
  Radius := Min(FORWARD_CORNER_RADIUS, (CardRect.Bottom - CardRect.Top) div 2);

  { NEW_STYLE (see the new_style constant, constants.pas): when set, the
    WHOLE forward card's background isn't drawn at all, leaving only
    its header row's backing below (+ its own outline, at the end of
    this function). The old branch is kept for a live comparison. }
  if not new_style then begin
    PaintRoundRectAA(Canvas, CardRect, Radius, [],
      BlendWithBackground(Clr, SENDER_BG_OPACITY, clWindow), clNone);
  end;

  { Only the top corners are rounded — via its own AOptions set instead
    of the older "draw all 4 and square off the bottom with a
    FillRect" trick (GDI RoundRect can't do per-corner, BGRA does it
    natively). }
  HeaderRadius := Min(FORWARD_CORNER_RADIUS, HEADER_BAR_H div 2);
  PaintRoundRectAA(Canvas, HeaderRect, HeaderRadius, [rrBottomLeftSquare, rrBottomRightSquare],
    BlendWithBackground(Clr, SENDER_HEADER_OPACITY, clWindow), clNone);

  AvBmp := ForwardAvatarBmp(ARow, FreeAvBmp);
  if AvBmp = nil then begin
    { mfoHiddenUser (or an id that hasn't resolved yet) — rendered
      on the spot, no cache: this is just initials, no file/preview
      decode happens here (see ForwardAvatarBmp), so it's cheap even on
      every repaint. }
    AvBmp := RenderAvatarBmp('', '', ForwardSourceName(ARow), 0, HEADER_H, True);
    FreeAvBmp := True;
  end;
  { The same horizontal padding as the outer header (HeaderX := BR.Left
    + MSG_PAD_H, see Paint) — and the same vertical centering
    (HEADER_PAD_V). }
  AvX := HeaderRect.Left + MSG_PAD_H;
  AvY := HeaderRect.Top + HEADER_PAD_V;
  if AvBmp <> nil then begin
    AvBmp.Draw(Canvas, AvX, AvY, False);
    if FreeAvBmp then begin
      AvBmp.Free;
    end;
  end;

  { Name+time — ONE line in the source's color, the same approach as
    the outer header (which also does a single TextOut for "Name
    (HH:MM)", entirely in the sender's color — time isn't a separate
    gray suffix). }
  NameX := AvX + HEADER_H + MSG_ICON_GAP;
  LocalDT := UniversalTimeToLocal(UnixToDateTime(ARow.ForwardDate));
  if SameDate(LocalDT, Date) then begin
    TimeStr := FormatDateTime('hh:nn', LocalDT);
  end else begin
    TimeStr := FormatDateTime('hh:nn dd.mm.yy', LocalDT);
  end;
  S := string(ForwardSourceName(ARow)) + ' (' + TimeStr + ')';

  Canvas.Font.Name := 'default';
  Canvas.Font.Height := -11;
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := Clr;
  Canvas.Brush.Style := bsClear;
  Canvas.TextOut(NameX, HeaderRect.Top + HEADER_PAD_V, S);

  if new_style then begin
    { NEW_STYLE: an outline instead of the whole card — only on its
      header row, the same shape (only the top corners rounded) as its
      backing above; drawn last, over the avatar/text. }
    PaintRoundRectAA(Canvas, HeaderRect, HeaderRadius, [rrBottomLeftSquare, rrBottomRightSquare],
      clNone, BlendWithBackground(Clr, SENDER_BORDER_OPACITY, clWindow));
  end;
end;

{ Reply quote (reply_to) — a compact box: a quote icon + the quoted
  sender's name (bold, colored) + the first line of their text (gray)
  — backing/outline/rounding the same way as a forward card (see the
  REPLY_* constants), but without an avatar — the source here isn't an
  external object, just an earlier message of the same conversation,
  hence an icon instead of a photo. The data comes from
  FModel.ReplyPreview: if not resolved yet (the message is still
  loading via getRepliedMessage), a temporary gray placeholder is
  drawn — it repaints itself once the data arrives (see
  TTdMessages.GetRepliedDone -> Touch -> a full ModelChanged, not just
  Invalidate: the box's height doesn't change, but the text appears). }
procedure TMsgScroller.PaintReplyBox(AIndex: integer; ARow: TMsgRow);
var
  Box: TRect;
  SenderUserId, SenderChatId: Int64;
  PreviewText: utf8string;
  Have: boolean;
  Clr: TColor;
  NameStr, SnippetStr: string;
  TextX, MaxW, NlPos, Radius, IconX, IconY: integer;
  IconList: TImageList;
  HdrRect: TRect;
  HdrRadius: integer;
begin
  Box := ReplyBoxRect(AIndex);
  Have := (FModel <> nil) and FModel.ReplyPreview(ARow.ReplyChatId, ARow.ReplyMessageId,
    SenderUserId, SenderChatId, PreviewText);

  if Have then begin
    Clr := ResolveAccentColor(SenderUserId, SenderChatId);
    NameStr := string(ResolveDisplayName(SenderUserId, SenderChatId));
    SnippetStr := string(PreviewText);
    NlPos := Pos(#10, SnippetStr);
    if NlPos > 0 then begin
      { First line only — a multi-line text is squeezed into one, the
        same way the original client does. }
      SnippetStr := Copy(SnippetStr, 1, NlPos - 1);
    end;
  end else begin
    Clr := clGrayText;
    NameStr := '';
    SnippetStr := 'Loading…';
  end;

  { The backing — the same approach as a forward card (SENDER_BG_
    OPACITY, rounded corners with the same "capsule" guard, see
    PaintForwardCard) — but its own radius, REPLY_CORNER_RADIUS, not
    FORWARD_CORNER_RADIUS directly: each card type has its own knob,
    rather than sharing one value. }
  Radius := Min(REPLY_CORNER_RADIUS, (Box.Bottom - Box.Top) div 2);
  { NEW_STYLE (see the new_style constant, constants.pas): when set,
    only the "icon+name" row (the first line, HdrRect) gets a
    background, the same approach as the block header/forward card
    (only the top corners rounded); the second line (the quoted
    message's text, SnippetStr) has no background, sitting directly on
    the window background. The old branch (background+outline on the
    whole Box) is kept for a live comparison. }
  if new_style then begin
    HdrRect := Rect(Box.Left, Box.Top, Box.Right, Box.Top + HEADER_PAD_V + REPLY_LINE_H);
    HdrRadius := Min(Radius, (HdrRect.Bottom - HdrRect.Top) div 2);
    PaintRoundRectAA(Canvas, HdrRect, HdrRadius, [rrBottomLeftSquare, rrBottomRightSquare],
      BlendWithBackground(Clr, SENDER_HEADER_OPACITY, clWindow), clNone);
  end else begin
    PaintRoundRectAA(Canvas, Box, Radius, [],
      BlendWithBackground(Clr, SENDER_BG_OPACITY, clWindow), clNone);
  end;

  { The quote icon comes from the same ImageList1 as the message-status
    icons/a forward's source avatar (FormMain.Chats.ImageList1, see the
    comment in Paint about the shared list with one continuous
    numbering). }
  IconX := Box.Left + MSG_PAD_H;
  IconY := Box.Top + HEADER_PAD_V;
  IconList := nil;
  if (FormMain <> nil) and (FormMain.Chats <> nil) then begin
    IconList := FormMain.Chats.ImageList1;
  end;
  if (IconList <> nil) and (ICON_QUOTE >= 0) and (ICON_QUOTE < IconList.Count) then begin
    IconList.Draw(Canvas, IconX, IconY, ICON_QUOTE, True);
  end;

  TextX := Box.Left + MSG_PAD_H + MSG_ICON_W + MSG_ICON_GAP;
  MaxW := Box.Right - MSG_ICON_GAP - TextX;
  if MaxW >= 10 then begin
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Name := 'default';
    Canvas.Font.Height := -11;

    Canvas.Font.Style := [fsBold];
    Canvas.Font.Color := Clr;
    Canvas.TextOut(TextX, Box.Top + HEADER_PAD_V, TruncateToWidth(Canvas, NameStr, MaxW));

    Canvas.Font.Style := [];
    Canvas.Font.Color := clGrayText;
    Canvas.TextOut(TextX, Box.Top + HEADER_PAD_V + REPLY_LINE_H, TruncateToWidth(Canvas, SnippetStr, MaxW));
  end;

  { The outline — drawn last, on top of the content, the same approach
    as a forward card (SENDER_BORDER_OPACITY, the same Radius).
    NEW_STYLE: the outline applies only to HdrRect (the same shape as
    its backing above), not the whole box. }
  if new_style then begin
    PaintRoundRectAA(Canvas, HdrRect, HdrRadius, [rrBottomLeftSquare, rrBottomRightSquare],
      clNone, BlendWithBackground(Clr, SENDER_BORDER_OPACITY, clWindow));
  end else begin
    PaintRoundRectAA(Canvas, Box, Radius, [], clNone,
      BlendWithBackground(Clr, SENDER_BORDER_OPACITY, clWindow));
  end;
end;

procedure TMsgScroller.Paint;
var
  I, Lo, Hi: integer;
  R: TMsgRow;
  BR, CR, HeaderRect, FwdBR: TRect;
  S: string;
  SelStart, SelEnd, LowIdx, HighIdx, LowChar, HighChar: integer;
  HasSel: boolean;
  ChatRow: TChatRow;
  LastReadOutbox: Int64;
  IconList: TImageList;
  HeaderX, HeaderY, IconIdx, HeaderRadius, FwdRadius: integer;
  LocalDT: TDateTime;
  TimeStr, NameStr, SuffixStr: string;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clWindow;
  Canvas.FillRect(ClientRect);

  if (FModel = nil) or (FModel.Count = 0) then begin
    Exit;
  end;

  Lo := FirstVisible;
  Hi := LastVisible;
  if (Lo < 0) or (Hi < 0) then begin
    Exit;
  end;

  HasSel := ResolveSelection(LowIdx, HighIdx, LowChar, HighChar);

  { The status icon is resolved once per chat, not per row:
    LastReadOutbox is the same for every message in the current chat,
    no need to fetch it for each row inside the loop below. }
  ChatRow := nil;
  if TdChatList <> nil then begin
    ChatRow := TdChatList.Lookup(FModel.ChatId);
  end;
  if ChatRow <> nil then begin
    LastReadOutbox := ChatRow.LastReadOutbox;
  end else begin
    LastReadOutbox := 0;
  end;
  IconList := nil;
  if (FormMain <> nil) and (FormMain.Chats <> nil) then begin
    IconList := FormMain.Chats.ImageList1;
  end;

  { The one execution path in the whole chat-switch flow that had no
    try/except before: Paint is called directly by the drawing system
    (WM_PAINT), not through ModelChanged, so the guards added in
    TFrameHistory.ModelChanged/OpenChat never reached it. An unhandled
    exception inside WM_PAINT is a classic source of Win32 application
    hangs (the window stops responding to further repaints/input);
    each row runs in its own try/except so one problematic message
    can't kill the whole repaint. }
  for I := Lo to Hi do begin
    try
      R := FModel[I];
      BR := BlockRect(I);
      CR := ContentRect(I);

      { The block's backing — the sender's color, muted, over the
        background, SENDER_BG_OPACITY. Filled BEFORE the header/
        content, so text and the divider line lie on top, not under.
        Fill only, no outline — PaintRoundRectAA (BGRA antialiasing in
        place of GDI Canvas.RoundRect, see its comment) doesn't touch
        Canvas.Brush/Pen state itself.
        NEW_STYLE (see the new_style constant, constants.pas): a
        lighter-weight look under test — the block's BODY background
        isn't drawn at all, leaving only the header row's backing
        below. The old branch is kept for a live comparison. }
      if not new_style then begin
        PaintRoundRectAA(Canvas, BR, MSG_CORNER_RADIUS, [],
          BlendWithBackground(SenderColor(R), SENDER_BG_OPACITY, clWindow), clNone);
      end;

      { The header row's own backing (icon+name) is more prominent than
        the block's background (SENDER_HEADER_OPACITY > SENDER_BG_
        OPACITY), drawn over the already-painted block background. The
        icon/text padding from this strip's top and bottom edges is
        its own, HEADER_PAD_V, not MSG_GAP (hence HeaderY, not BR.Top
        directly). Only the TOP corners are rounded, matching the
        block outside; rounding the bottom corners too would turn a
        short strip into a capsule shape, detached from the block
        beneath it — the radius for this strip is its own,
        HeaderRadius, not MSG_CORNER_RADIUS directly: the strip is only
        HEADER_BAR_H pixels tall, and if the block's radius exceeds
        half of that, rounding turns into a stretched "capsule" (both
        ends becoming semicircles meeting in the middle) — the same
        class of problem already seen with photo previews (see
        TPhotoWidget.DrawBmpRounded) — this doesn't go away just from
        switching to BGRA instead of GDI, the guard is still needed. }
      HeaderRect := Rect(BR.Left, BR.Top, BR.Right, BR.Top + HEADER_BAR_H);
      HeaderRadius := Min(MSG_CORNER_RADIUS, HEADER_BAR_H div 2);
      PaintRoundRectAA(Canvas, HeaderRect, HeaderRadius, [rrBottomLeftSquare, rrBottomRightSquare],
        BlendWithBackground(SenderColor(R), SENDER_HEADER_OPACITY, clWindow), clNone);
      HeaderY := BR.Top + HEADER_PAD_V;

      Canvas.Brush.Style := bsClear;
      Canvas.Font.Name := 'default';
      Canvas.Font.Height := -11;
      HeaderX := BR.Left + MSG_PAD_H;

      { Outgoing messages get a delivery status, incoming ones just a
        direction marker (ICON_MSG_INCOMING, not a status: there's no
        such thing as "delivered/read" from our side for someone
        else's message). The slot is reserved either way, so the name
        doesn't shift horizontally row to row. }
      if R.IsOutgoing then begin
        IconIdx := ReceiptIconIndex(MessageReceipt(R, LastReadOutbox));
      end else begin
        IconIdx := ICON_MSG_INCOMING;
      end;
      if IconList <> nil then begin
        if (IconIdx >= 0) and (IconIdx < IconList.Count) then begin
          IconList.Draw(Canvas, HeaderX, HeaderY + (HEADER_H - IconList.Height) div 2, IconIdx, True);
        end;
      end;
      Inc(HeaderX, MSG_ICON_W + MSG_ICON_GAP);

      LocalDT := UniversalTimeToLocal(UnixToDateTime(R.Date));
      if SameDate(LocalDT, Date) then begin
        TimeStr := FormatDateTime('hh:nn', LocalDT);
      end else begin
        TimeStr := FormatDateTime('hh:nn dd.mm.yy', LocalDT);
      end;
      NameStr := string(SenderDisplayName(R));
      if NameStr = '' then begin
        S := '(' + TimeStr + ')';
      end else begin
        S := NameStr + ' (' + TimeStr + ')';
      end;

      Canvas.Font.Style := [fsBold];
      Canvas.Font.Color := SenderColor(R);
      Canvas.TextOut(HeaderX, HeaderY, S);

      SuffixStr := '';
      if R.IsOutgoing then begin
        case R.Delivery of
          mdsPending: SuffixStr := '  sending...';
          mdsFailed:  SuffixStr := '  failed';
        end;
      end;
      if SuffixStr <> '' then begin
        Canvas.Font.Style := [];
        Canvas.Font.Color := clGrayText;
        Canvas.TextOut(HeaderX + Canvas.TextWidth(S), HeaderY, SuffixStr);
      end;

      if R.ReplyMessageId <> 0 then begin
        PaintReplyBox(I, R);
      end;

      if R.ForwardKind <> mfoNone then begin
        PaintForwardCard(I, R);
      end;

      Canvas.Font.Height := -13;
      if HasSel and (I >= LowIdx) and (I <= HighIdx) then begin
        RangeForRow(I, LowIdx, HighIdx, LowChar, HighChar, Length(R.PlainText), SelStart, SelEnd);
      end else begin
        SelStart := -1;
        SelEnd := -1;
      end;

      { Real, reported bug: this was previously wired ONLY into
        AutoDownloadVisible (fires on ModelChanged — a new message
        arriving or an edit) and, since the fix just above,
        PrefetchAutoDownload (fires just outside the visible band on
        scroll) — neither covers a row that's ALREADY on screen and
        simply gets repainted (e.g. after a big scroll jump/LoadOlder
        batch that skips the narrow prefetch band entirely). Confirmed
        directly: a custom_emoji_id in an already-loaded, fully visible
        message never once appeared in a getCustomEmojiStickers request
        in tdlib_raw.log. Media widgets (photo/audio/video/sticker)
        already have this exact safety net — their own Layout*Widgets
        call Ensure*File unconditionally on every layout pass, not only
        on scroll/model-change — this brings custom-emoji text entities
        up to the same guarantee, the same way TFrameChats.GridDrawCell
        already does for the chat list (calls it on every row draw).
        Cheap: no-ops at once for a row with no mekCustomEmoji entity,
        and idempotent for one already known/pending. }
      FModel.EnsureCustomEmojiForRow(R);

      RendererFor(R.Kind).Paint(R, Canvas, CR, SelStart, SelEnd, SenderColor(R));

      if (R.ForwardKind <> mfoNone) and not new_style then begin
        { The quote's outline — the same order as the outer block
          below: after the content, on top of it.
          NEW_STYLE: the whole forward card has no outline — only its
          header has one, see PaintForwardCard. }
        FwdBR := ForwardCardRect(I);
        FwdRadius := Min(FORWARD_CORNER_RADIUS, (FwdBR.Bottom - FwdBR.Top) div 2);
        PaintRoundRectAA(Canvas, FwdBR, FwdRadius, [], clNone,
          BlendWithBackground(ForwardSourceColor(R), SENDER_BORDER_OPACITY, clWindow));
      end;

      if Length(R.Reactions) > 0 then begin
        PaintReactions(I, R);
      end;

      { The block's outline — drawn last, on top of the content: only
        an outline, the text itself sits MSG_PAD_H from the edge and
        isn't touched by it.
        NEW_STYLE: the block body has no outline at all; instead, the
        header row gets one (the same shape as its backing above: only
        the top corners rounded). }
      if new_style then begin
        PaintRoundRectAA(Canvas, HeaderRect, HeaderRadius, [rrBottomLeftSquare, rrBottomRightSquare],
          clNone, BlendWithBackground(SenderColor(R), SENDER_BORDER_OPACITY, clWindow));
      end else begin
        PaintRoundRectAA(Canvas, BR, MSG_CORNER_RADIUS, [], clNone,
          BlendWithBackground(SenderColor(R), SENDER_BORDER_OPACITY, clWindow));
      end;
    except
      { Silently skips this row: the status bar is updated from
        ModelChanged, not from here — Paint can fire dozens of times a
        second, spamming it would only make things worse. }
    end;
  end;

  try
    LayoutAudioWidgets(Lo, Hi);
  except
  end;
  try
    LayoutFileWidgets(Lo, Hi);
  except
  end;
  try
    LayoutPhotoWidgets(Lo, Hi);
  except
  end;
  try
    LayoutAnimationWidgets(Lo, Hi);
  except
  end;
  try
    LayoutVideoWidgets(Lo, Hi);
  except
  end;
  try
    LayoutStickerWidgets(Lo, Hi);
  except
  end;
end;

procedure TMsgScroller.LayoutAudioWidgets(ALo, AHi: integer);
var
  I, N, MIdx, AIdx: integer;
  R: TMsgRow;
  W: TAudioWidget;
  CR: TRect;
  WantIds: array of Int64;

  function IsWanted(AId: Int64): boolean;
  var
    K: integer;
  begin
    Result := False;
    for K := 0 to N - 1 do begin
      if WantIds[K] = AId then begin
        Result := True;
        Exit;
      end;
    end;
  end;

begin
  N := 0;
  if FModel <> nil then begin
    SetLength(WantIds, AHi - ALo + 2);
    for I := ALo to AHi do begin
      R := FModel[I];
      { Voice notes use the same widget as regular audio ("identical
        functionality and appearance"), not a separate class. }
      if R.Kind in [mckAudio, mckVoiceNote] then begin
        WantIds[N] := R.Id;
        Inc(N);
      end;
    end;
  end;

  for AIdx := FAudioActive.Count - 1 downto 0 do begin
    if not IsWanted(FAudioActive.Keys[AIdx]) then begin
      FAudioActive.Data[AIdx].Visible := False;
      FAudioActive.Delete(AIdx);
    end;
  end;

  for I := 0 to N - 1 do begin
    MIdx := FModel.IndexOfId(WantIds[I]);
    if MIdx < 0 then begin
      Continue;
    end;
    CR := ContentRect(MIdx);
    AIdx := FAudioActive.IndexOf(WantIds[I]);
    if AIdx >= 0 then begin
      W := FAudioActive.Data[AIdx];
    end else begin
      W := ObtainAudioWidget;
      FAudioActive.Add(WantIds[I], W);
    end;
    { The pooled widget may have represented a DIFFERENT message
      before this — track data is refreshed on every pass, not just
      the first time. }
    W.Images := FAudioImages;
    R := FModel[MIdx];
    W.BackgroundColor := WidgetBackdropColor(R);
    { Voice notes have no title/performer/file_name (TDLib doesn't
      provide them, see TMsgRow.VoiceDuration) — a static label is
      used instead, through the same TAudioWidget.SetTrack, with no
      change needed in the widget itself: TitleStr there already falls
      back to AFileName when Title/Performer are empty. }
    if R.Kind = mckVoiceNote then begin
      W.SetTrack(R.Id, '', '', 'Voice message', R.VoiceDuration);
    end else begin
      W.SetTrack(R.Id, R.AudioTitle, R.AudioPerformer, R.AudioFileName, R.AudioDuration);
    end;
    { While a thumb drag is in progress, playback state is left
      untouched on this pass (LayoutAudioWidgets is called on EVERY
      Paint, including every tick of FPlaybackTimer): otherwise the
      real (not-yet-caught-up) position would overwrite the local drag
      preview right under the cursor. }
    if not W.Dragging then begin
      if (FActivePlayer <> nil) and (FActivePlayerMsgId = R.Id) then begin
        W.SetPlayback(True, FActivePlayer.State = apsPlaying, FActivePlayer.PositionSec);
      end else begin
        W.SetPlayback(False, False, 0);
      end;
    end;
    W.SetBounds(CR.Left, CR.Top, CR.Right - CR.Left, CR.Bottom - CR.Top);
    W.Visible := True;
  end;
end;

function TMsgScroller.ObtainAudioWidget: TAudioWidget;
var
  I: integer;
begin
  for I := 0 to FAudioPool.Count - 1 do begin
    Result := TAudioWidget(FAudioPool[I]);
    if not Result.Visible then begin
      Result.OnPlayClick := @AudioPlayClick;
      Result.OnSeek := @AudioSeek;
      Exit;
    end;
  end;
  Result := TAudioWidget.Create(Self);
  Result.Parent := Self;
  Result.OnPlayClick := @AudioPlayClick;
  Result.OnSeek := @AudioSeek;
  FAudioPool.Add(Result);
end;

{ A copy of LayoutAudioWidgets — the same recycled-pool approach, for
  files instead of audio (Kind=mckFile). }
procedure TMsgScroller.LayoutFileWidgets(ALo, AHi: integer);
var
  I, N, MIdx, AIdx: integer;
  R: TMsgRow;
  W: TFileWidget;
  CR: TRect;
  WantIds: array of Int64;

  function IsWanted(AId: Int64): boolean;
  var
    K: integer;
  begin
    Result := False;
    for K := 0 to N - 1 do begin
      if WantIds[K] = AId then begin
        Result := True;
        Exit;
      end;
    end;
  end;

begin
  N := 0;
  if FModel <> nil then begin
    SetLength(WantIds, AHi - ALo + 2);
    for I := ALo to AHi do begin
      R := FModel[I];
      if R.Kind = mckFile then begin
        WantIds[N] := R.Id;
        Inc(N);
      end;
    end;
  end;

  for AIdx := FFileActive.Count - 1 downto 0 do begin
    if not IsWanted(FFileActive.Keys[AIdx]) then begin
      FFileActive.Data[AIdx].Visible := False;
      FFileActive.Delete(AIdx);
    end;
  end;

  for I := 0 to N - 1 do begin
    MIdx := FModel.IndexOfId(WantIds[I]);
    if MIdx < 0 then begin
      Continue;
    end;
    CR := ContentRect(MIdx);
    AIdx := FFileActive.IndexOf(WantIds[I]);
    if AIdx >= 0 then begin
      W := FFileActive.Data[AIdx];
    end else begin
      W := ObtainFileWidget;
      FFileActive.Add(WantIds[I], W);
    end;
    W.Images := FFileImages;
    W.DownloadImages := FAudioImages;
    W.PopupMenu := FFilePopupMenu;
    R := FModel[MIdx];
    W.BackgroundColor := WidgetBackdropColor(R);
    W.SetFile(R.Id, R.DocFileName, R.DocFileSize, R.DocLocalPath <> '');
    W.SetBounds(CR.Left, CR.Top, CR.Right - CR.Left, CR.Bottom - CR.Top);
    W.Visible := True;
  end;
end;

function TMsgScroller.ObtainFileWidget: TFileWidget;
var
  I: integer;
begin
  for I := 0 to FFilePool.Count - 1 do begin
    Result := TFileWidget(FFilePool[I]);
    if not Result.Visible then begin
      Result.OnFileClick := @FileWidgetClick;
      Exit;
    end;
  end;
  Result := TFileWidget.Create(Self);
  Result.Parent := Self;
  Result.OnFileClick := @FileWidgetClick;
  FFilePool.Add(Result);
end;

procedure TMsgScroller.FileWidgetClick(Sender: TObject);
var
  W: TFileWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TFileWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];

  if Row.DocLocalPath <> '' then begin
    { The file is already downloaded — opened with the system's
      default application, not a save dialog (that's now reached only
      through the context menu's "Save as...", see
      FileWidgetSaveAsClick). }
    OpenDocument(string(Row.DocLocalPath));
    Exit;
  end;
  { Not downloaded yet — just download, no dialog: the icon switches to
    the mime type on its own once the path arrives (see
    ModelChanged/LayoutFileWidgets). }
  FModel.EnsureDocFile(Row);
end;

procedure TMsgScroller.FileWidgetSaveAsClick(Sender: TObject);
var
  W: TFileWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TFileWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];

  if Row.DocLocalPath <> '' then begin
    SaveDocFile(Row);
    Exit;
  end;
  { Not downloaded yet — request it and remember that the save dialog
    needs to open once the path arrives (see ModelChanged), the same
    approach as FPendingPlayMsgId for audio. }
  FPendingSaveMsgId := Row.Id;
  FPendingFileAction := pfaSaveDialog;
  FModel.EnsureDocFile(Row);
end;

procedure TMsgScroller.FileWidgetShowInFolderClick(Sender: TObject);
var
  W: TFileWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TFileWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];

  if Row.DocLocalPath <> '' then begin
    ShowDocInFolder(Row.DocLocalPath);
    Exit;
  end;
  FPendingSaveMsgId := Row.Id;
  FPendingFileAction := pfaShowInFolder;
  FModel.EnsureDocFile(Row);
end;

procedure TMsgScroller.SaveDocFile(ARow: TMsgRow);
var
  Dlg: TSaveDialog;
  Src, Dst: TFileStream;
begin
  if (ARow = nil) or (ARow.DocLocalPath = '') then begin
    Exit;
  end;
  Dlg := TSaveDialog.Create(nil);
  try
    Dlg.FileName := string(ARow.DocFileName);
    Dlg.Filter := 'All files|*.*';
    Dlg.Options := Dlg.Options + [ofOverwritePrompt];
    if not Dlg.Execute then begin
      Exit;
    end;
    { The file is already downloaded to TDLib's own cache — this is
      just a copy to the location the user chose, not a re-download. }
    Src := TFileStream.Create(string(ARow.DocLocalPath), fmOpenRead or fmShareDenyWrite);
    try
      Dst := TFileStream.Create(Dlg.FileName, fmCreate);
      try
        Dst.CopyFrom(Src, Src.Size);
      finally
        Dst.Free;
      end;
    finally
      Src.Free;
    end;
  finally
    Dlg.Free;
  end;
end;

{ A copy of LayoutFileWidgets — the same recycled-pool approach, for
  photos instead of files (Kind=mckPhoto). The difference: the
  widget's width/height isn't the full column (CR) but the preview's
  natural size (TargetWidth/TargetHeight, computed inside SetPhoto) —
  a narrow portrait photo shouldn't stretch to the block's full width. }
procedure TMsgScroller.LayoutPhotoWidgets(ALo, AHi: integer);
var
  I, N, MIdx, AIdx: integer;
  R: TMsgRow;
  W: TPhotoWidget;
  CR: TRect;
  WantIds: array of Int64;

  function IsWanted(AId: Int64): boolean;
  var
    K: integer;
  begin
    Result := False;
    for K := 0 to N - 1 do begin
      if WantIds[K] = AId then begin
        Result := True;
        Exit;
      end;
    end;
  end;

begin
  N := 0;
  if FModel <> nil then begin
    SetLength(WantIds, AHi - ALo + 2);
    for I := ALo to AHi do begin
      R := FModel[I];
      if R.Kind = mckPhoto then begin
        WantIds[N] := R.Id;
        Inc(N);
      end;
    end;
  end;

  for AIdx := FPhotoActive.Count - 1 downto 0 do begin
    if not IsWanted(FPhotoActive.Keys[AIdx]) then begin
      FPhotoActive.Data[AIdx].Visible := False;
      FPhotoActive.Delete(AIdx);
    end;
  end;

  for I := 0 to N - 1 do begin
    MIdx := FModel.IndexOfId(WantIds[I]);
    if MIdx < 0 then begin
      Continue;
    end;
    CR := ContentRect(MIdx);
    AIdx := FPhotoActive.IndexOf(WantIds[I]);
    if AIdx >= 0 then begin
      W := FPhotoActive.Data[AIdx];
    end else begin
      W := ObtainPhotoWidget;
      FPhotoActive.Add(WantIds[I], W);
    end;
    W.DownloadImages := FAudioImages;
    W.PopupMenu := FFilePopupMenu;
    R := FModel[MIdx];
    { WidgetBackdropColor, not bare BlendWithBackground(SenderColor(R),
      ...): that version always took the OUTER block's color, even when
      a photo sits inside a forward (which sits on the quote card's
      backing, its own independent color — ForwardSourceColor). The
      same class of fix as audio/file — see WidgetBackdropColor. }
    W.BackgroundColor := WidgetBackdropColor(R);
    W.SetPhoto(R.Id, R.PhotoWidth, R.PhotoHeight, R.PhotoMinithumb,
      R.PhotoLocalPath <> '', R.PhotoLocalPath, CR.Right - CR.Left);
    W.SetBounds(CR.Left, CR.Top, W.TargetWidth, W.TargetHeight);
    W.Visible := True;
  end;
end;

function TMsgScroller.ObtainPhotoWidget: TPhotoWidget;
var
  I: integer;
begin
  for I := 0 to FPhotoPool.Count - 1 do begin
    Result := TPhotoWidget(FPhotoPool[I]);
    if not Result.Visible then begin
      Result.OnPhotoClick := @PhotoWidgetClick;
      Exit;
    end;
  end;
  Result := TPhotoWidget.Create(Self);
  Result.Parent := Self;
  Result.OnPhotoClick := @PhotoWidgetClick;
  FPhotoPool.Add(Result);
end;

procedure TMsgScroller.PhotoWidgetClick(Sender: TObject);
var
  W: TPhotoWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TPhotoWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];

  { Strictly two clicks — no automatic opening once the original
    finishes downloading: the first click ONLY downloads (both the
    preview — blur -> real thumbnail in the chat itself — and the
    original, for opening afterward), a second click, once the
    original is ready, opens it. The Ensure*File calls are no-ops if
    already downloaded/already requested, so calling both
    unconditionally is safe. }
  if Row.PhotoLocalPath = '' then begin
    FModel.EnsurePhotoFile(Row);
  end;
  if Row.PhotoBestLocalPath = '' then begin
    FModel.EnsurePhotoBestFile(Row);
    Exit;
  end;
  { Opens the BUILT-IN viewer (mediaviewer.pas), the same approach as
    video (VideoBodyClick), rather than OpenDocument (the system
    viewer). }
  if (FormMain <> nil) and (FormMain.MediaViewer <> nil) then begin
    FormMain.MediaViewer.ShowMessage(FModel, Row.Id, FAudioImages, FPlaybackImages,
      utf8string(FormMain.AudioDeviceName));
  end;
end;

{ A copy of LayoutPhotoWidgets — the same recycled-pool approach, for
  "GIFs" (Kind=mckAnimation) instead of photos. Difference: after
  ordinary positioning, it checks R.AnimAutoPlay (see
  MaybeAutoDownload): if auto-download is enabled for this chat's kind
  and the file is already downloaded but the widget isn't playing yet,
  it starts the loop itself, without a click. This check runs on
  EVERY pass (cheap — two booleans and a string comparison), not just
  the moment the file finishes downloading — a self-healing behavior:
  if playback stops for any reason (the widget being recreated on a
  column-width change, etc.), the very next pass restarts it, as long
  as R.AnimAutoPlay is set (which it never clears — it's a permanent
  property of the row, "this setting wanted this to loop", not a
  one-shot flag). }
procedure TMsgScroller.LayoutAnimationWidgets(ALo, AHi: integer);
var
  I, N, MIdx, AIdx: integer;
  R: TMsgRow;
  W: TAnimationWidget;
  CR: TRect;
  WantIds: array of Int64;

  function IsWanted(AId: Int64): boolean;
  var
    K: integer;
  begin
    Result := False;
    for K := 0 to N - 1 do begin
      if WantIds[K] = AId then begin
        Result := True;
        Exit;
      end;
    end;
  end;

begin
  N := 0;
  if FModel <> nil then begin
    SetLength(WantIds, AHi - ALo + 2);
    for I := ALo to AHi do begin
      R := FModel[I];
      if R.Kind = mckAnimation then begin
        WantIds[N] := R.Id;
        Inc(N);
      end;
    end;
  end;

  for AIdx := FAnimActive.Count - 1 downto 0 do begin
    if not IsWanted(FAnimActive.Keys[AIdx]) then begin
      { The widget leaves the visible area — playback is stopped (a
        "GIF" isn't left looping endlessly in the background after
        being scrolled past), using the same StopLoop as when reused
        for a different message (see SetAnim). }
      FAnimActive.Data[AIdx].StopLoop;
      FAnimActive.Data[AIdx].Visible := False;
      FAnimActive.Delete(AIdx);
    end;
  end;

  for I := 0 to N - 1 do begin
    MIdx := FModel.IndexOfId(WantIds[I]);
    if MIdx < 0 then begin
      Continue;
    end;
    CR := ContentRect(MIdx);
    AIdx := FAnimActive.IndexOf(WantIds[I]);
    if AIdx >= 0 then begin
      W := FAnimActive.Data[AIdx];
    end else begin
      W := ObtainAnimationWidget;
      FAnimActive.Add(WantIds[I], W);
    end;
    W.DownloadImages := FAudioImages;
    R := FModel[MIdx];
    W.BackgroundColor := WidgetBackdropColor(R);
    W.SetAnim(R.Id, R.AnimWidth, R.AnimHeight, R.AnimMinithumb,
      R.AnimLocalPath <> '', R.AnimLocalPath, CR.Right - CR.Left);
    W.SetBounds(CR.Left, CR.Top, W.TargetWidth, W.TargetHeight);
    W.Visible := True;
    if R.AnimAutoPlay and (R.AnimLocalPath <> '') and (not W.Playing) then begin
      W.StartLoop;
    end;
  end;
end;

function TMsgScroller.ObtainAnimationWidget: TAnimationWidget;
var
  I: integer;
begin
  for I := 0 to FAnimPool.Count - 1 do begin
    Result := TAnimationWidget(FAnimPool[I]);
    if not Result.Visible then begin
      Result.OnAnimClick := @AnimationWidgetClick;
      Exit;
    end;
  end;
  Result := TAnimationWidget.Create(Self);
  Result.Parent := Self;
  Result.OnAnimClick := @AnimationWidgetClick;
  FAnimPool.Add(Result);
end;

{ Exactly two clicks, the same approach as a file (not like a photo,
  which also fetches an "original" for saving — here there's exactly
  one file): the first click on an undownloaded "GIF" only requests
  the download, with NO auto-play; a second click, once downloaded,
  starts looped playback. A click on an already-playing widget
  deliberately does nothing: a "GIF" has no start/stop controls at all. }
procedure TMsgScroller.AnimationWidgetClick(Sender: TObject);
var
  W: TAnimationWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TAnimationWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];

  if Row.AnimLocalPath = '' then begin
    FModel.EnsureAnimFile(Row);
    Exit;
  end;
  if not W.Playing then begin
    W.StartLoop;
  end;
end;

{ A copy of LayoutAudioWidgets — the same recycled-pool approach and
  the same "don't touch playback state on reuse, real state flows
  through SetVideo/SetPlayback" logic, for video instead of audio.
  Different from LayoutAnimationWidgets: there's NO StopLoop on
  eviction here — an active video player (with sound) keeps playing
  even once its row scrolls past the visible range, the same principle
  as audio (the real Telegram doesn't cut sound just because a message
  is temporarily off screen) — not the same principle as a "GIF" (which
  is silent, so stopping it on eviction costs nothing and saves
  CPU/decoding time on something invisible). }
procedure TMsgScroller.LayoutVideoWidgets(ALo, AHi: integer);
var
  I, N, MIdx, AIdx, NatW, NatH: integer;
  R: TMsgRow;
  W: TVideoWidget;
  CR: TRect;
  WantIds: array of Int64;

  function IsWanted(AId: Int64): boolean;
  var
    K: integer;
  begin
    Result := False;
    for K := 0 to N - 1 do begin
      if WantIds[K] = AId then begin
        Result := True;
        Exit;
      end;
    end;
  end;

begin
  N := 0;
  if FModel <> nil then begin
    SetLength(WantIds, AHi - ALo + 2);
    for I := ALo to AHi do begin
      R := FModel[I];
      if R.Kind = mckVideo then begin
        WantIds[N] := R.Id;
        Inc(N);
      end;
    end;
  end;

  for AIdx := FVideoActive.Count - 1 downto 0 do begin
    if not IsWanted(FVideoActive.Keys[AIdx]) then begin
      FVideoActive.Data[AIdx].Visible := False;
      FVideoActive.Delete(AIdx);
    end;
  end;

  for I := 0 to N - 1 do begin
    MIdx := FModel.IndexOfId(WantIds[I]);
    if MIdx < 0 then begin
      Continue;
    end;
    CR := ContentRect(MIdx);
    AIdx := FVideoActive.IndexOf(WantIds[I]);
    if AIdx >= 0 then begin
      W := FVideoActive.Data[AIdx];
    end else begin
      W := ObtainVideoWidget;
      FVideoActive.Add(WantIds[I], W);
    end;
    W.DownloadImages := FAudioImages;
    W.Images := FAudioImages;
    R := FModel[MIdx];
    W.BackgroundColor := WidgetBackdropColor(R);
    { The preview frame is downloaded UNCONDITIONALLY, independent of
      the Auto download settings (see the comment on
      TMsgRow.VideoThumbFileId) — as soon as the row is visible, not
      only when the user explicitly clicks. }
    FModel.EnsureVideoThumbFile(R);
    { The chat preview's size follows the thumbnail's OWN resolution
      (known from the metadata right away, no need to wait for the
      download), not the real video's resolution (often 720p/1080p,
      see the comment on TMsgRow.VideoThumbWidth): a static picture
      from the thumbnail is shown, and there's nothing sharper than it
      anyway — sizing the box to the video's resolution would just
      smear the same picture via Resample. VideoWidth/VideoHeight
      remain a fallback for the case where the content has no
      thumbnail at all (theoretically possible, never observed live). }
    if (R.VideoThumbWidth > 0) and (R.VideoThumbHeight > 0) then begin
      NatW := R.VideoThumbWidth;
      NatH := R.VideoThumbHeight;
    end else begin
      NatW := R.VideoWidth;
      NatH := R.VideoHeight;
    end;
    W.SetVideo(R.Id, NatW, NatH, R.VideoThumbLocalPath,
      R.VideoLocalPath <> '', R.VideoLocalPath, CR.Right - CR.Left, R.VideoDuration);
    { There's no inline playback (see the comment on FVideoPool) — the
      chat widget is always "inactive" (a play icon, no scrub bar on
      hover); real playback happens only in the viewer, see
      VideoBodyClick. }
    W.SetPlayback(False, False, 0);
    W.SetBounds(CR.Left, CR.Top, W.TargetWidth, W.TargetHeight);
    W.Visible := True;
  end;
end;

function TMsgScroller.ObtainVideoWidget: TVideoWidget;
var
  I: integer;
begin
  for I := 0 to FVideoPool.Count - 1 do begin
    Result := TVideoWidget(FVideoPool[I]);
    if not Result.Visible then begin
      Result.OnClick := @VideoPlayClick;
      Result.OnPlayClick := @VideoPlayClick;
      Result.OnBodyClick := @VideoBodyClick;
      Exit;
    end;
  end;
  Result := TVideoWidget.Create(Self);
  Result.Parent := Self;
  Result.OnClick := @VideoPlayClick;
  Result.OnPlayClick := @VideoPlayClick;
  Result.OnBodyClick := @VideoBodyClick;
  FVideoPool.Add(Result);
end;

{ A copy of LayoutAnimationWidgets — the same recycled-pool approach
  and the same StopLoop-on-eviction (stickers, like "GIFs", are
  silent — stopping the animation once a row leaves the screen costs
  nothing and saves CPU). Difference: NO click involved at all —
  downloading and starting the animation are both unconditional (see
  MaybeAutoDownload), waiting for no user interaction, unlike a "GIF"
  (which needs exactly two clicks). }
procedure TMsgScroller.LayoutStickerWidgets(ALo, AHi: integer);
var
  I, N, MIdx, AIdx: integer;
  R: TMsgRow;
  W: TStickerWidget;
  CR: TRect;
  WantIds: array of Int64;

  function IsWanted(AId: Int64): boolean;
  var
    K: integer;
  begin
    Result := False;
    for K := 0 to N - 1 do begin
      if WantIds[K] = AId then begin
        Result := True;
        Exit;
      end;
    end;
  end;

begin
  N := 0;
  if FModel <> nil then begin
    SetLength(WantIds, AHi - ALo + 2);
    for I := ALo to AHi do begin
      R := FModel[I];
      if R.Kind = mckSticker then begin
        WantIds[N] := R.Id;
        Inc(N);
      end;
    end;
  end;

  for AIdx := FStickerActive.Count - 1 downto 0 do begin
    if not IsWanted(FStickerActive.Keys[AIdx]) then begin
      FStickerActive.Data[AIdx].StopLoop;
      FStickerActive.Data[AIdx].Visible := False;
      FStickerActive.Delete(AIdx);
    end;
  end;

  for I := 0 to N - 1 do begin
    MIdx := FModel.IndexOfId(WantIds[I]);
    if MIdx < 0 then begin
      Continue;
    end;
    CR := ContentRect(MIdx);
    AIdx := FStickerActive.IndexOf(WantIds[I]);
    if AIdx >= 0 then begin
      W := FStickerActive.Data[AIdx];
    end else begin
      W := ObtainStickerWidget;
      FStickerActive.Add(WantIds[I], W);
    end;
    R := FModel[MIdx];
    W.BackgroundColor := WidgetBackdropColor(R);
    W.SetSticker(R.Id, R.StickerFormat, R.StickerWidth, R.StickerHeight,
      R.StickerLocalPath, CR.Right - CR.Left);
    W.SetBounds(CR.Left, CR.Top, W.TargetWidth, W.TargetHeight);
    W.Visible := True;
    if (R.StickerLocalPath <> '') and (not W.Playing) then begin
      W.StartLoop;
    end;
  end;
end;

function TMsgScroller.ObtainStickerWidget: TStickerWidget;
var
  I: integer;
begin
  for I := 0 to FStickerPool.Count - 1 do begin
    Result := TStickerWidget(FStickerPool[I]);
    if not Result.Visible then begin
      Exit;
    end;
  end;
  Result := TStickerWidget.Create(Self);
  Result.Parent := Self;
  FStickerPool.Add(Result);
end;

procedure TMsgScroller.PhotoWidgetSaveAsClick(Sender: TObject);
var
  W: TPhotoWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TPhotoWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];

  { "Save as" saves the ORIGINAL (PhotoBestLocalPath), not the small
    preview copy (PhotoLocalPath, which is for fast inline display,
    see the comment on TMsgRow.PhotoBestFileId). }
  if Row.PhotoBestLocalPath <> '' then begin
    SavePhotoFile(Row);
    Exit;
  end;
  FPendingPhotoMsgId := Row.Id;
  FPendingPhotoAction := pfaSaveDialog;
  FModel.EnsurePhotoBestFile(Row);
end;

procedure TMsgScroller.PhotoWidgetShowInFolderClick(Sender: TObject);
var
  W: TPhotoWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TPhotoWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];

  { "Show in folder" uses the same original as "Save as" (see there). }
  if Row.PhotoBestLocalPath <> '' then begin
    ShowDocInFolder(Row.PhotoBestLocalPath);
    Exit;
  end;
  FPendingPhotoMsgId := Row.Id;
  FPendingPhotoAction := pfaShowInFolder;
  FModel.EnsurePhotoBestFile(Row);
end;

procedure TMsgScroller.SavePhotoFile(ARow: TMsgRow);
var
  Dlg: TSaveDialog;
  Src, Dst: TFileStream;
begin
  if (ARow = nil) or (ARow.PhotoBestLocalPath = '') then begin
    Exit;
  end;
  Dlg := TSaveDialog.Create(nil);
  try
    Dlg.FileName := 'photo_' + IntToStr(ARow.Id) + '.jpg';
    Dlg.Filter := 'JPEG|*.jpg;*.jpeg|All files|*.*';
    Dlg.Options := Dlg.Options + [ofOverwritePrompt];
    if not Dlg.Execute then begin
      Exit;
    end;
    { The original (PhotoBestLocalPath), not the preview copy. }
    Src := TFileStream.Create(string(ARow.PhotoBestLocalPath), fmOpenRead or fmShareDenyWrite);
    try
      Dst := TFileStream.Create(Dlg.FileName, fmCreate);
      try
        Dst.CopyFrom(Src, Src.Size);
      finally
        Dst.Free;
      end;
    finally
      Src.Free;
    end;
  finally
    Dlg.Free;
  end;
end;

{ ---------------- audio playback ---------------- }

procedure TMsgScroller.FlushDonePlayer;
begin
  if FDonePlayer <> nil then begin
    FDonePlayer.WaitFor;
    FDonePlayer.Free;
    FDonePlayer := nil;
  end;
end;

procedure TMsgScroller.StopActivePlayer;
begin
  FlushDonePlayer;
  if FActivePlayer <> nil then begin
    FActivePlayer.StopPlayback;
    FDonePlayer := FActivePlayer;
    FActivePlayer := nil;
    FActivePlayerMsgId := 0;
  end;
  FPlaybackTimer.Enabled := False;
end;

procedure TMsgScroller.StartPlayback(ARow: TMsgRow; AStartPositionSec: double);
begin
  if ARow = nil then begin
    Exit;
  end;
  StopActivePlayer;
  FActivePlayer := TAudioPlayer.Create(PlayableLocalPath(ARow), utf8string(FormMain.AudioDeviceName), AStartPositionSec);
  FActivePlayer.OnStateChanged := @PlayerStateChanged;
  FActivePlayerMsgId := ARow.Id;
  FPlaybackTimer.Enabled := True;
  Invalidate;
end;

procedure TMsgScroller.AudioPlayClick(Sender: TObject);
var
  W: TAudioWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TAudioWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];

  if (FActivePlayer <> nil) and (FActivePlayerMsgId = W.RowId) then begin
    { Same track — just pause/resume, the player isn't recreated. }
    if FActivePlayer.State = apsPlaying then begin
      FActivePlayer.Pause;
    end else if FActivePlayer.State = apsPaused then begin
      FActivePlayer.Resume;
    end;
    Invalidate;
    Exit;
  end;

  { A different track (or nothing was playing) — the previous one is
    stopped. }
  FPendingPlayMsgId := 0;

  if PlayableLocalPath(Row) = '' then begin
    { The file isn't downloaded yet — request it and remember that
      this specific track should start playing once the path arrives
      (see ModelChanged). The previous player, if any, is stopped
      right now regardless — no point waiting for it until the new
      file finishes downloading. }
    StopActivePlayer;
    FPendingPlayMsgId := W.RowId;
    FModel.EnsurePlayableFile(Row);
    Exit;
  end;

  StartPlayback(Row);
end;

procedure TMsgScroller.AudioSeek(Sender: TObject; AFraction: double);
var
  W: TAudioWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  { Seeking only makes sense for the ACTIVE (playing/paused) track —
    the widget only allows dragging the thumb when FIsActive (see
    TAudioWidget.MouseDown), so this shouldn't be reached otherwise,
    but it's checked again just in case. }
  if FModel = nil then begin
    Exit;
  end;
  W := TAudioWidget(Sender);
  if (FActivePlayer = nil) or (FActivePlayerMsgId <> W.RowId) then begin
    Exit;
  end;
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];
  if (PlayableLocalPath(Row) = '') or (PlayableDuration(Row) <= 0) then begin
    Exit;
  end;
  StartPlayback(Row, AFraction * PlayableDuration(Row));
end;

procedure TMsgScroller.PlayerStateChanged(Sender: TObject);
begin
  if (Sender = FActivePlayer) and
     ((FActivePlayer.State = apsStopped) or (FActivePlayer.State = apsError)) then begin
    FDonePlayer := FActivePlayer;
    FActivePlayer := nil;
    FActivePlayerMsgId := 0;
    FPlaybackTimer.Enabled := False;
  end;
  Invalidate;
end;

procedure TMsgScroller.PlaybackTick(Sender: TObject);
begin
  FlushDonePlayer;
  if FActivePlayer <> nil then begin
    Invalidate;
  end;
end;

procedure TMsgScroller.CustomEmojiAnimTick(Sender: TObject);
begin
  if AnyLiveAnimating then begin
    Invalidate;
  end;
end;

{ Video (messageVideo) is NO LONGER played inline at all: both a click
  on the play button and a click on the frame itself lead to the
  viewer (VideoBodyClick, mediaviewer.pas), which holds its own,
  independent TMediaPlayer. All of the earlier "one active player for
  the whole scroller" infrastructure (FActiveVideoPlayer/
  StartVideoPlayback/VideoSeek/VideoPlayerStateChanged/
  VideoPlaybackTick/FVideoPlaybackTimer) was removed entirely — without
  the click that used to trigger it, it would have been dead code,
  unreachable from any path. }
procedure TMsgScroller.VideoPlayClick(Sender: TObject);
var
  W: TVideoWidget;
  Row: TMsgRow;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TVideoWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  Row := FModel[Idx];
  if Row.VideoLocalPath = '' then begin
    { Not downloaded — just download, the same "strictly two clicks"
      principle as a photo (PhotoWidgetClick): there's nothing to open
      without the file, and a repeat click, once it's ready, opens the
      viewer on its own. }
    FModel.EnsureVideoFile(Row);
    Exit;
  end;
  VideoBodyClick(Sender);
end;

procedure TMsgScroller.VideoBodyClick(Sender: TObject);
var
  W: TVideoWidget;
  Idx: integer;
begin
  if FModel = nil then begin
    Exit;
  end;
  W := TVideoWidget(Sender);
  Idx := FModel.IndexOfId(W.RowId);
  if Idx < 0 then begin
    Exit;
  end;
  if (FormMain <> nil) and (FormMain.MediaViewer <> nil) then begin
    FormMain.MediaViewer.ShowMessage(FModel, W.RowId, FAudioImages, FPlaybackImages,
      utf8string(FormMain.AudioDeviceName));
  end;
end;

function TMsgScroller.HitTestAt(X, Y: integer; out AIndex: integer): TMsgHit;
var
  R: TMsgRow;
  CR: TRect;
begin
  Result.Kind := mhkNone;
  Result.URL := '';
  Result.CharOffset := -1;
  AIndex := -1;
  if (FModel = nil) or (FModel.Count = 0) then begin
    Exit;
  end;
  AIndex := IndexAtY(FScrollTop + Y);
  if AIndex < 0 then begin
    Exit;
  end;
  R := FModel[AIndex];
  CR := ContentRect(AIndex);
  Result := RendererFor(R.Kind).HitTest(R, CR, X, Y);
end;

procedure TMsgScroller.DoLinkClick(const AUrl: utf8string);
var
  U: string;
begin
  if AUrl = '' then begin
    Exit;
  end;
  U := string(AUrl);
  if Pos('://', U) = 0 then begin
    U := 'https://' + U;
  end;
  OpenURL(U);
end;

procedure TMsgScroller.OpenForwardSource(ARow: TMsgRow);
var
  F: TFrameHistory;
begin
  if (ARow = nil) or (ARow.ForwardChatId = 0) or (ARow.ForwardMessageId = 0) then begin
    Exit;
  end;
  if (FormMain = nil) or (FormMain.Nav = nil) then begin
    Exit;
  end;
  { TFrameHistory is the navigator's singleton (TFrameNavigator.
    ShowFrame decides itself whether to create or reuse it), so if the
    source is the CURRENTLY open chat, this is literally a call to a
    method on Self's own owner, just through the new
    TFrameHistory.OpenChat entry point. }
  F := TFrameHistory(FormMain.Nav.ShowFrame(TFrameHistory));
  if F <> nil then begin
    F.OpenChat(ARow.ForwardChatId, ARow.ForwardMessageId);
  end;
end;

procedure TMsgScroller.ScrollToMessage(AMessageId: Int64);
var
  Idx, RowH: integer;
begin
  if (FModel = nil) or (Length(FOffsets) < 2) then begin
    Exit;
  end;
  Idx := FModel.IndexOfId(AMessageId);
  if Idx < 0 then begin
    { Shouldn't happen after the synchronous Rebuild in
      TTdMessages.JumpDone, but just in case — simply doesn't scroll,
      doesn't crash. }
    Exit;
  end;
  RowH := FOffsets[Idx + 1] - FOffsets[Idx];
  { The message is centered in the visible area rather than pinned to
    the top — this makes both what came before and what came after
    more visible. }
  ClampScrollTop(FOffsets[Idx] - (ClientHeight - RowH) div 2);
  Invalidate;
end;

procedure TMsgScroller.CopySelection;
var
  I, LowIdx, HighIdx, LowChar, HighChar, SelStart, SelEnd: integer;
  R: TMsgRow;
  Lines: TStringList;
begin
  if not ResolveSelection(LowIdx, HighIdx, LowChar, HighChar) then begin
    Exit;
  end;
  Lines := TStringList.Create;
  try
    for I := LowIdx to HighIdx do begin
      R := FModel[I];
      RangeForRow(I, LowIdx, HighIdx, LowChar, HighChar, Length(R.PlainText), SelStart, SelEnd);
      if SelEnd > SelStart then begin
        Lines.Add(string(Copy(R.PlainText, SelStart + 1, SelEnd - SelStart)));
      end;
    end;
    Clipboard.AsText := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure TMsgScroller.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  Hit: TMsgHit;
  Idx: integer;
  R: TMsgRow;
begin
  inherited MouseDown(Button, Shift, X, Y);
  SetFocus;
  if Button <> mbLeft then begin
    Exit;
  end;

  Hit := HitTestAt(X, Y, Idx);
  if Idx < 0 then begin
    FSelAnchorMsg := 0;
    FSelFocusMsg := 0;
    Invalidate;
    Exit;
  end;

  R := FModel[Idx];
  { A click on the reply quote box jumps to the quoted message in the
    SAME chat (ReplyPreview/JumpTo only support this case, see the
    comment on TTdMessages.ReplyPreview) — the same behavior as tapping
    a quote in the original client. }
  if (R.ReplyMessageId <> 0) and (FModel <> nil) and (R.ReplyChatId = FModel.ChatId)
    and PtInRect(ReplyBoxRect(Idx), Point(X, Y)) then begin
    FModel.JumpTo(R.ReplyMessageId);
    Exit;
  end;

  { The source name in a forward quote is a link only for mfoChannel
    (only there does TDLib know the source post's message_id, see
    TMsgForwardKind). The whole "avatar+name+time" row is clickable,
    not just the name text — for a row this small, an exact hit test
    against the text width isn't worth the extra code. }
  if (R.ForwardKind = mfoChannel) and PtInRect(ForwardHeaderRect(Idx), Point(X, Y)) then begin
    OpenForwardSource(R);
    Exit;
  end;

  if Hit.Kind = mhkLink then begin
    DoLinkClick(Hit.URL);
    Exit;
  end;

  FSelAnchorMsg := R.Id;
  FSelFocusMsg := R.Id;
  if Hit.CharOffset >= 0 then begin
    FSelAnchorChar := Hit.CharOffset;
  end else begin
    FSelAnchorChar := 0;
  end;
  FSelFocusChar := FSelAnchorChar;
  FSelecting := True;
  { Without capturing the mouse: if the cursor leaves the control
    during a drag and the button is released outside it, MouseUp never
    reaches here (LCL doesn't route it without MouseCapture),
    FSelecting stays stuck at True forever, and ordinary mouse movement
    with NO button held afterward starts looking like an ongoing
    selection — "buggy selection behavior". }
  MouseCapture := True;
  Invalidate;
end;

procedure TMsgScroller.MouseMove(Shift: TShiftState; X, Y: integer);
var
  Hit: TMsgHit;
  Idx: integer;
  R: TMsgRow;
  Want: TCursor;
begin
  inherited MouseMove(Shift, X, Y);

  if FSelecting then begin
    Idx := IndexAtY(FScrollTop + Y);
    if Idx >= 0 then begin
      R := FModel[Idx];
      Hit := RendererFor(R.Kind).HitTest(R, ContentRect(Idx), X, Y);
      FSelFocusMsg := R.Id;
      if Hit.CharOffset >= 0 then begin
        FSelFocusChar := Hit.CharOffset;
      end else if Y < ContentRect(Idx).Top then begin
        FSelFocusChar := 0;
      end else begin
        FSelFocusChar := Length(R.PlainText);
      end;
      Invalidate;
    end;
    Exit;
  end;

  Hit := HitTestAt(X, Y, Idx);
  if (Idx >= 0) and (FModel[Idx].ForwardKind = mfoChannel)
    and PtInRect(ForwardHeaderRect(Idx), Point(X, Y)) then begin
    Want := crHandPoint;
  end else if (Idx >= 0) and (FModel[Idx].ReplyMessageId <> 0)
    and (FModel[Idx].ReplyChatId = FModel.ChatId)
    and PtInRect(ReplyBoxRect(Idx), Point(X, Y)) then begin
    Want := crHandPoint;
  end else if Hit.Kind = mhkLink then begin
    Want := crHandPoint;
  end else if Hit.Kind = mhkText then begin
    Want := crIBeam;
  end else begin
    Want := crDefault;
  end;
  if Cursor <> Want then begin
    Cursor := Want;
  end;
end;

procedure TMsgScroller.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FSelecting := False;
  if MouseCapture then begin
    MouseCapture := False;
  end;
end;

function TMsgScroller.DoMouseWheel(Shift: TShiftState; WheelDelta: integer;
  MousePos: TPoint): boolean;
begin
  Result := True;
  SetScrollTop(FScrollTop - (WheelDelta div 120) * WHEEL_LINE_PX);
end;

procedure TMsgScroller.KeyDown(var Key: word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  case Key of
    VK_C:
      if ssCtrl in Shift then begin
        CopySelection;
        Key := 0;
      end;
    VK_UP:    SetScrollTop(FScrollTop - LINE_SCROLL_PX);
    VK_DOWN:  SetScrollTop(FScrollTop + LINE_SCROLL_PX);
    VK_PRIOR: SetScrollTop(FScrollTop - ClientHeight);
    VK_NEXT:  SetScrollTop(FScrollTop + ClientHeight);
    VK_HOME:  SetScrollTop(0);
    VK_END:   SetScrollTop(FTotalHeight);
  end;
end;

{ ---------------- TFrameHistory ---------------- }

constructor TFrameHistory.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);

  pnlStatus := TPanel.Create(Self);
  pnlStatus.Parent := Self;
  pnlStatus.Align := alTop;
  pnlStatus.Height := 22;
  pnlStatus.BevelOuter := bvNone;
  lblStatus := TLabel.Create(Self);
  lblStatus.Parent := pnlStatus;
  lblStatus.Left := 8;
  lblStatus.Top := 4;
  lblStatus.AutoSize := False;
  lblStatus.Width := 600;
  lblStatus.Font.Color := clGrayText;
  lblStatus.Caption := '';

  FScrollbar := TScrollBar.Create(Self);
  FScrollbar.Parent := Self;
  FScrollbar.Kind := sbVertical;
  FScrollbar.Align := alRight;
  { Not a constant: the chat list (framechats, TDrawGrid) draws its own
    scrollbar natively, sized to the system metric — the same
    GetSystemMetrics(SM_CXVSCROLL) Windows uses to scale it for DPI. A
    fixed number here would simply drift out of sync with it at any
    display scale other than 100%. }
  FScrollbar.Width := GetSystemMetrics(SM_CXVSCROLL);
  FScrollbar.OnScroll := @ScrollbarScroll;

  FScroller := TMsgScroller.Create(Self);
  FScroller.Parent := Self;
  FScroller.Align := alClient;
  FScroller.OnScrollRangeChanged := @ScrollerRangeChanged;
  FScroller.OnNearTop := @ScrollerNearTop;
  { ImageList1/FileTypes are frame components (LFM), already created
    by inherited streaming by this point, before this constructor's
    body runs. }
  FScroller.AudioImages := ImageList1;
  { ImageList2 is a 32x32 list replacing the older 16x16 "playback"
    list — the old one stays in the .lfm as-is (the component wasn't
    removed), just no longer read by name. }
  FScroller.PlaybackImages := ImageList2;
  FScroller.FileImages := FileTypes;
  FScroller.FilePopupMenu := FilePopupMenu;

  { The flag is set last, the same rule as every form/frame in the
    project: LFM streaming (not formally happening here, but
    Align-docking can trigger Resize earlier) must not run into
    not-yet-assembled fields. }
  FReady := True;

  { BindModel is NOT called here, in the constructor: the frame has no
    Parent yet at this point (TFrameNavigator.ShowFrame sets it only
    AFTER Create) — until then, controls have no real window, and any
    Canvas access raises EInvalidOperation "has no parent window". The
    first binding happens in DoActivate, which the navigator reaches
    only after Parent/Visible are set. }
  TdApp.SubscribeActive(Self);
end;

destructor TFrameHistory.Destroy;
begin
  FReady := False;
  TdApp.UnsubscribeActive(Self);
  UnbindModel;
  inherited Destroy;
end;

procedure TFrameHistory.MenuItemFileShowInFolderClick(Sender: TObject);
var
  PM: TPopupMenu;
begin
  PM := TPopupMenu(TMenuItem(Sender).GetParentMenu);
  if (PM = nil) or (PM.PopupComponent = nil) then begin
    Exit;
  end;
  if PM.PopupComponent is TFileWidget then begin
    FScroller.FileWidgetShowInFolderClick(PM.PopupComponent);
  end else if PM.PopupComponent is TPhotoWidget then begin
    FScroller.PhotoWidgetShowInFolderClick(PM.PopupComponent);
  end;
end;

procedure TFrameHistory.MenuItemFileSaveAsClick(Sender: TObject);
var
  PM: TPopupMenu;
begin
  PM := TPopupMenu(TMenuItem(Sender).GetParentMenu);
  if (PM = nil) or (PM.PopupComponent = nil) then begin
    Exit;
  end;
  if PM.PopupComponent is TFileWidget then begin
    FScroller.FileWidgetSaveAsClick(PM.PopupComponent);
  end else if PM.PopupComponent is TPhotoWidget then begin
    FScroller.PhotoWidgetSaveAsClick(PM.PopupComponent);
  end;
end;

procedure TFrameHistory.BindModel;
begin
  FModel := TdMsgList;
  FScroller.BindModel(FModel);

  { The name cache and accent-color cache aren't affected by the nil
    early Exit below — they're bound regardless of whether a chat is
    already open. }
  FUsers := TdUserList;
  if FUsers <> nil then begin
    FUsers.OnChanged := @UsersChanged;
  end;
  FAccentColors := TdAccentColorList;
  if FAccentColors <> nil then begin
    FAccentColors.OnChanged := @UsersChanged;
  end;

  if FModel = nil then begin
    Exit;
  end;
  FModel.OnChanged := @ModelChanged;
  FModel.OnLoadingChanged := @LoadingChanged;
  FModel.OnActionError := @ActionError;
  FModel.OnJumpReady := @JumpReady;
  ModelChanged(nil);
  LoadingChanged(nil);
end;

procedure TFrameHistory.UnbindModel;
begin
  if FModel <> nil then begin
    if TMethod(FModel.OnChanged).Data = Pointer(Self) then begin
      FModel.OnChanged := nil;
    end;
    if TMethod(FModel.OnLoadingChanged).Data = Pointer(Self) then begin
      FModel.OnLoadingChanged := nil;
    end;
    if TMethod(FModel.OnActionError).Data = Pointer(Self) then begin
      FModel.OnActionError := nil;
    end;
    if TMethod(FModel.OnJumpReady).Data = Pointer(Self) then begin
      FModel.OnJumpReady := nil;
    end;
    FModel := nil;
  end;
  if FUsers <> nil then begin
    if TMethod(FUsers.OnChanged).Data = Pointer(Self) then begin
      FUsers.OnChanged := nil;
    end;
    FUsers := nil;
  end;
  if FAccentColors <> nil then begin
    if TMethod(FAccentColors.OnChanged).Data = Pointer(Self) then begin
      FAccentColors.OnChanged := nil;
    end;
    FAccentColors := nil;
  end;
  FScroller.BindModel(nil);
end;

procedure TFrameHistory.OpenChat(AChatId: Int64; AJumpToMessageId: Int64);
begin
  if FModel = nil then begin
    Exit;
  end;
  { OpenChat synchronously fires FOnChanged (=ModelChanged) right from
    here — that chain already has its own try/except, but this catches
    it too: if an exception still breaks through from somewhere else
    along the way (e.g. from TTdMessages.OpenChat/Clear itself), it
    settles in the status bar instead of escaping unhandled into LCL —
    under a debugger this looks like a completely frozen application
    if the exception dialog doesn't surface above the active window. }
  try
    FModel.OpenChat(AChatId, AJumpToMessageId);
  except
    on E: Exception do begin
      if lblStatus <> nil then begin
        lblStatus.Caption := 'OpenChat error: ' + E.Message;
      end;
    end;
  end;
end;

procedure TFrameHistory.TdActiveChanged(ANew: TTdAccount);
begin
  if not FReady then begin
    Exit;
  end;
  UnbindModel;
  BindModel;
end;

procedure TFrameHistory.TdAccountsChanged;
begin
  { The account roster doesn't matter to the chat history frame }
end;

procedure TFrameHistory.ModelChanged(Sender: TObject);
begin
  if (not FReady) or (FModel = nil) then begin
    Exit;
  end;
  { A diagnostic wrapper: FScroller.ModelChanged is the most complex
    piece (offset recomputation, holding the scroll anchor, measuring
    real messages through msglayout) and the one spot in the whole
    chat-switch chain with no try/except of its own. If a hang while
    switching chats is caused by an unhandled exception somewhere in
    here (e.g. an unexpected content shape for a specific message on
    its first real measurement), it settles in the status bar instead
    of leaking into Application.HandleException. }
  try
    FScroller.ModelChanged;
    MaybeLoadMore;
    LoadingChanged(nil);
  except
    on E: Exception do begin
      if lblStatus <> nil then begin
        lblStatus.Caption := 'UI error: ' + E.Message;
      end;
    end;
  end;
end;

procedure TFrameHistory.LoadingChanged(Sender: TObject);
begin
  if (not FReady) or (lblStatus = nil) or (FModel = nil) then begin
    Exit;
  end;
  if FModel.LoadingOlder then begin
    lblStatus.Caption := 'Loading history...';
  end else if FModel.OldestLoaded then begin
    lblStatus.Caption := Format('%d messages (all loaded)', [FModel.Count]);
  end else begin
    lblStatus.Caption := Format('%d messages (more)', [FModel.Count]);
  end;
end;

procedure TFrameHistory.ActionError(Sender: TObject; ACode: integer;
  const AMessage, AAction: utf8string);
begin
  { A getChatHistory/sendMessage/viewMessages failure — without this,
    an RPC failure would go completely unnoticed: an empty list and
    silence. }
  if lblStatus = nil then begin
    Exit;
  end;
  if AAction = 'jump' then begin
    { getChatHistory around a message (following a forward quote)
      failed — usually because the message has since been deleted in
      the source chat, not a bug: chat_id/message_id are passed as-is
      from forward_info.origin, with no manual conversion (see
      TMsgForwardKind in tdmessages.pas). }
    lblStatus.Caption := 'Could not jump to the message — it may have been deleted';
    Exit;
  end;
  lblStatus.Caption := Format('Error %d: %s', [ACode, string(AMessage)]);
end;

procedure TFrameHistory.JumpReady(Sender: TObject; AMessageId: Int64);
begin
  if FReady and (FScroller <> nil) then begin
    FScroller.ScrollToMessage(AMessageId);
  end;
end;

procedure TFrameHistory.UsersChanged(Sender: TObject);
begin
  { Someone's name finished resolving (or was updated) — block heights
    don't change because of this, a full FScroller.ModelChanged (offset
    recompute) isn't needed, just a repaint. }
  if FReady and (FScroller <> nil) then begin
    FScroller.Invalidate;
  end;
end;

procedure TFrameHistory.MaybeLoadMore;
begin
  if (FModel = nil) or FModel.LoadingOlder or FModel.OldestLoaded then begin
    Exit;
  end;
  { The loaded history doesn't even fill one screen — more is loaded,
    otherwise the user would see a short, truncated list with nothing
    to scroll and no "near the top" trigger to fire. }
  if FScroller.TotalHeight < FScroller.ClientHeight then begin
    FModel.LoadOlder;
  end;
end;

procedure TFrameHistory.ScrollerNearTop(Sender: TObject);
begin
  if (FModel = nil) or FModel.LoadingOlder or FModel.OldestLoaded then begin
    Exit;
  end;
  FModel.LoadOlder;
end;

procedure TFrameHistory.ScrollerRangeChanged(Sender: TObject);
var
  Max: integer;
begin
  { Classic Win32 SCROLLINFO semantics: Max is the top of the whole
    scroll range (like TotalHeight), PageSize is subtracted from it by
    the control itself when computing the thumb's extreme position —
    same as native scrolling in any other application. }
  Max := FScroller.TotalHeight;
  if Max < FScroller.ClientHeight then begin
    Max := FScroller.ClientHeight;
  end;
  FScrollbar.SetParams(FScroller.ScrollTop, 0, Max, FScroller.ClientHeight);
end;

procedure TFrameHistory.ScrollbarScroll(Sender: TObject; ScrollCode: TScrollCode;
  var ScrollPos: integer);
begin
  FScroller.ScrollTop := ScrollPos;
end;

procedure TFrameHistory.Resize;
begin
  inherited Resize;
  if not FReady then begin
    Exit;
  end;
  MaybeLoadMore;
end;

procedure TFrameHistory.DoActivate;
begin
  inherited DoActivate;
  { The first real display — the navigator has already set Parent and
    Visible, so Canvas operations inside BindModel are safe here. }
  if FModel = nil then begin
    BindModel;
  end;
end;

end.
