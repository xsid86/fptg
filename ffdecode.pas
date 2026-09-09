unit ffdecode;

{$mode objfpc}{$H+}

{ Binding to libavformat/libavcodec/libswresample for the current
  FFmpeg build (avformat-63.dll, avcodec-63.dll, avutil-61.dll,
  swresample-7.dll).

  Struct declarations are truncated at the last field this unit
  actually reads. This is safe because none of these structures are
  allocated or copied on the Pascal side — only FFmpeg creates them
  (via av*_alloc*), and Pascal only dereferences an already-built
  pointer, so fields past the last one declared here never affect the
  offsets of the fields that matter.

  AVCodecContext is left fully opaque (a void pointer) — none of its
  fields are read directly anywhere in this unit, it is only passed
  between library functions. All decoded-audio format information
  (sample rate/channels/sample format) comes from the resulting
  AVFrame after avcodec_receive_frame, not from the context. }

interface

uses
  Classes, SysUtils, ctypes;

const
  {$IFDEF WINDOWS}
  AVUTIL_LIB      = 'avutil-61.dll';
  AVCODEC_LIB     = 'avcodec-63.dll';
  AVFORMAT_LIB    = 'avformat-63.dll';
  SWRESAMPLE_LIB  = 'swresample-7.dll';
  SWSCALE_LIB     = 'swscale-10.dll';
  {$ENDIF}

  AVMEDIA_TYPE_VIDEO = 0;
  AVMEDIA_TYPE_AUDIO = 1;

  AV_SAMPLE_FMT_S16 = 1;

  { --- libavutil/pixfmt.h : enum AVPixelFormat ---
    AV_PIX_FMT_NONE=-1, AV_PIX_FMT_YUV420P is the first element after
    it (0), AV_PIX_FMT_BGRA is the 29th (index 28). Telegram "GIF"
    video (H.264/MP4) decodes to YUV420P almost always; BGRA is
    swscale's destination format, matching TBGRABitmap/GDI DIB byte
    order. AV_PIX_FMT_YUVA420P (34th element, index 33) is YUV420P plus
    a 4th, full-resolution alpha plane — used only when manually
    assembling a WebM-alpha custom emoji's color+alpha planes into one
    virtual frame for swscale (videoplayer.pas, TAnimationPlayer);
    never a real decoded frame's own .format, since no FFmpeg decoder
    used here produces 4-plane output on its own — see that unit's
    comment for why. All three indices recomputed programmatically
    against the real header (github.com/FFmpeg/FFmpeg libavutil/pixfmt.h,
    accounting for the explicit "= -1" on AV_PIX_FMT_NONE), not counted
    by hand — the same discipline already applied to YUV420P/BGRA above,
    now re-verified rather than assumed for this addition. }
  AV_PIX_FMT_YUV420P  = 0;
  AV_PIX_FMT_BGRA     = 28;
  AV_PIX_FMT_YUVA420P = 33;

  { --- libavcodec/packet.h : enum AVPacketSideDataType ---
    Index recomputed programmatically against the real header (no
    explicit numeric assignments disrupt the sequential count up to
    this point) — the one WebM/Matroska cares about: a video packet
    that carries a "BlockAdditional" (WebM alpha extension, BlockAddID=1)
    attaches this side data to the packet. Its payload layout is NOT
    just the raw codec bitstream — read via av_packet_get_side_data,
    confirmed by the actual demuxer source (libavformat/matroskadec.c,
    matroska_parse_frame): the FIRST 8 BYTES are the BlockAddID as a
    big-endian uint64, and the ACTUAL alpha bitstream (fed to a second,
    independent decoder of the same codec) starts only after that
    8-byte prefix — skipping it is not optional, feeding the whole blob
    to the decoder as-is would misparse it as a corrupt bitstream. }
  AV_PKT_DATA_MATROSKA_BLOCKADDITIONAL = 15;

  { --- libavcodec/packet.h : AV_INPUT_BUFFER_PADDING_SIZE ---
    Documented FFmpeg requirement, not a project convention invented
    here: "The input buffer, avpkt->data must be
    AV_INPUT_BUFFER_PADDING_SIZE bytes larger than the actual read
    bytes because some optimized bitstream readers read 32 or 64 bits
    at once and could read out of bounds. The end of the input buffer
    ... should be set to 0 to avoid problems." Any buffer handed to
    avcodec_send_packet must carry this margin, zeroed — see
    videoplayer.pas's AlphaCopyBuf (the WebM-alpha side-data bitstream,
    which points into someone else's memory otherwise and was never
    given this margin — a real, found-by-elimination suspect for
    heap corruption surfacing elsewhere in the process). }
  AV_INPUT_BUFFER_PADDING_SIZE = 64;

  { --- libswscale/swscale.h --- }
  SWS_BILINEAR = 1 shl 1;

  AV_CHANNEL_ORDER_NATIVE = 1;
  AV_CH_LAYOUT_STEREO_MASK: UInt64 = 3;   { AV_CH_FRONT_LEFT(1) | AV_CH_FRONT_RIGHT(2) }
  AV_CH_LAYOUT_MONO_MASK:   UInt64 = 1;   { AV_CH_FRONT_CENTER }

  { FFERRTAG('E','O','F',' '), see libavutil/error.h — the tag is fixed
    and platform/errno-independent, so it is safe to compute as a
    constant. }
  AVERROR_EOF_VAL = -(Ord('E') or (Ord('O') shl 8) or (Ord('F') shl 16) or (Ord(' ') shl 24));

  { av_seek_frame: stream_index=-1 means the timestamp is in
    AV_TIME_BASE (microseconds), not the stream's own timebase; ffmpeg
    converts it. AVSEEK_FLAG_BACKWARD seeks to the nearest keyframe at
    or before the target. }
  AVSEEK_FLAG_BACKWARD = 1;

type
  { --- libavutil/rational.h --- }
  PAVRational = ^TAVRational;
  TAVRational = record
    num, den: cint;
  end;

  { --- libavutil/channel_layout.h --- }
  PAVChannelLayout = ^TAVChannelLayout;
  TAVChannelLayout = record
    order: cint;          { enum AVChannelOrder }
    nb_channels: cint;
    u: UInt64;             { union: mask:uint64 or map:pointer — same size on x64 }
    opaque: pointer;
  end;

  { --- libavutil/frame.h : AVFrame ---
    Declared up to and including ch_layout — the last field actually
    read (sample_rate comes earlier). }
  PAVFrame = ^TAVFrame;
  TAVFrame = record
    data: array[0..7] of PByte;
    linesize: array[0..7] of cint;
    extended_data: PPByte;
    width, height: cint;
    nb_samples: cint;
    format: cint;                    { enum AVSampleFormat for audio }
    pict_type: cint;
    sample_aspect_ratio: TAVRational;
    pts: Int64;
    pkt_dts: Int64;
    time_base: TAVRational;
    quality: cint;
    frm_opaque: pointer;
    repeat_pict: cint;
    sample_rate: cint;
    buf: array[0..7] of pointer;
    extended_buf: PPointer;
    nb_extended_buf: cint;
    side_data: PPointer;
    nb_side_data: cint;
    flags: cint;
    color_range: cint;
    color_primaries: cint;
    color_trc: cint;
    colorspace: cint;
    chroma_location: cint;
    best_effort_timestamp: Int64;
    metadata: pointer;
    decode_error_flags: cint;
    hw_frames_ctx: pointer;
    opaque_ref: pointer;
    crop_top, crop_bottom, crop_left, crop_right: SizeUInt;
    private_ref: pointer;
    ch_layout: TAVChannelLayout;
  end;

  { --- libavcodec/packet.h : AVPacket ---
    Declared up to and including stream_index. }
  PAVPacket = ^TAVPacket;
  TAVPacket = record
    buf: pointer;
    pts: Int64;
    dts: Int64;
    data: PByte;
    size: cint;
    stream_index: cint;
  end;

  { --- libavcodec/codec_par.h : AVCodecParameters ---
    Only the first 3 fields — enough to find the audio stream
    (codec_type) and pass the pointer on to
    avcodec_parameters_to_context opaquely (that call copies the
    remaining fields in C; Pascal never reads them). }
  PAVCodecParameters = ^TAVCodecParameters;
  TAVCodecParameters = record
    codec_type: cint;      { enum AVMediaType }
    codec_id: cint;        { enum AVCodecID }
    codec_tag: UInt32;
  end;

  { --- libavformat/avformat.h : AVStream ---
    Declared up to and including time_base — needed by the video
    player (videoplayer.pas) to convert Frame.pts (in this stream's
    time_base units) into real seconds and inter-frame delays for
    looped GIF playback. The field between codecpar and time_base
    (priv_data) is declared only to keep time_base's offset correct;
    it is not read. }
  PAVStream = ^TAVStream;
  TAVStream = record
    av_class: pointer;
    index: cint;
    id: cint;
    codecpar: PAVCodecParameters;
    priv_data: pointer;
    time_base: TAVRational;
  end;
  PPAVStream = ^PAVStream;

  { --- libavformat/avformat.h : AVFormatContext ---
    Declared up to and including duration. }
  PAVFormatContext = ^TAVFormatContext;
  PPAVFormatContext = ^PAVFormatContext;
  TAVFormatContext = record
    av_class: pointer;
    iformat: pointer;
    oformat: pointer;
    priv_data: pointer;
    pb: pointer;
    ctx_flags: cint;
    nb_streams: cuint;
    streams: PPAVStream;
    nb_stream_groups: cuint;
    stream_groups: PPointer;
    nb_chapters: cuint;
    chapters: PPointer;
    url: PAnsiChar;
    start_time: Int64;
    duration: Int64;
  end;

{ ---------------- libavutil ---------------- }

function av_frame_alloc: PAVFrame; cdecl; external AVUTIL_LIB;
procedure av_frame_free(var AFrame: PAVFrame); cdecl; external AVUTIL_LIB;
procedure av_frame_unref(AFrame: PAVFrame); cdecl; external AVUTIL_LIB;
function av_strerror(AErrNum: cint; ABuf: PAnsiChar; ABufSize: SizeUInt): cint; cdecl; external AVUTIL_LIB;
procedure av_log_set_level(ALevel: cint); cdecl; external AVUTIL_LIB;
{ Sets an AVOption by name on any object whose first field is AVClass
  (AVCodecContext is one) — does not require knowing that structure's
  own layout, so it is safe to call through an opaque pointer, as
  AVCodecContext is declared in this unit. Used for pkt_timebase (see
  the call sites in mediaplayer.pas/videoplayer.pas) — the only
  practical way to set that field without unpacking AVCodecContext
  from a fully opaque pointer into a partially declared record. }
function av_opt_set_q(AObj: pointer; AName: PAnsiChar; AVal: TAVRational;
  ASearchFlags: cint): cint; cdecl; external AVUTIL_LIB;

{ ---------------- libavformat ---------------- }

function avformat_open_input(var ACtx: PAVFormatContext; AUrl: PAnsiChar;
  AFmt: pointer; AOptions: PPointer): cint; cdecl; external AVFORMAT_LIB;
function avformat_find_stream_info(ACtx: PAVFormatContext; AOptions: PPointer): cint; cdecl; external AVFORMAT_LIB;
procedure avformat_close_input(var ACtx: PAVFormatContext); cdecl; external AVFORMAT_LIB;
function av_read_frame(ACtx: PAVFormatContext; APkt: PAVPacket): cint; cdecl; external AVFORMAT_LIB;
function av_seek_frame(ACtx: PAVFormatContext; AStreamIndex: cint;
  ATimestamp: Int64; AFlags: cint): cint; cdecl; external AVFORMAT_LIB;

{ ---------------- libavcodec ---------------- }

function avcodec_find_decoder(AId: cint): pointer; cdecl; external AVCODEC_LIB;
function avcodec_alloc_context3(ACodec: pointer): pointer; cdecl; external AVCODEC_LIB;
procedure avcodec_free_context(var ACtx: pointer); cdecl; external AVCODEC_LIB;
function avcodec_parameters_to_context(ACtx: pointer; APar: PAVCodecParameters): cint; cdecl; external AVCODEC_LIB;
function avcodec_open2(ACtx: pointer; ACodec: pointer; AOptions: PPointer): cint; cdecl; external AVCODEC_LIB;
function av_packet_alloc: PAVPacket; cdecl; external AVCODEC_LIB;
procedure av_packet_free(var APkt: PAVPacket); cdecl; external AVCODEC_LIB;
procedure av_packet_unref(APkt: PAVPacket); cdecl; external AVCODEC_LIB;
{ Returns a pointer directly into APkt's own side-data buffer (owned by
  APkt, valid only until APkt is unref'd/freed) and its size via ASize,
  or nil if APkt carries no side data of this type — see the
  AV_PKT_DATA_MATROSKA_BLOCKADDITIONAL comment above for the specific
  8-byte-prefix payload layout this project actually reads. }
function av_packet_get_side_data(APkt: PAVPacket; AType: cint;
  ASize: PSizeUInt): PByte; cdecl; external AVCODEC_LIB;
function avcodec_send_packet(ACtx: pointer; APkt: PAVPacket): cint; cdecl; external AVCODEC_LIB;
function avcodec_receive_frame(ACtx: pointer; AFrame: PAVFrame): cint; cdecl; external AVCODEC_LIB;
{ Resets the decoder's internal state (frames queued for reordering,
  etc.) — required after av_seek_frame, otherwise the decoder keeps
  trying to reconstruct frames from data before the seek;
  videoplayer.pas calls this on every loop of looped GIF playback. }
procedure avcodec_flush_buffers(ACtx: pointer); cdecl; external AVCODEC_LIB;

{ ---------------- libswresample ---------------- }

function swr_alloc_set_opts2(var APs: pointer;
  AOutChLayout: PAVChannelLayout; AOutSampleFmt: cint; AOutSampleRate: cint;
  AInChLayout: PAVChannelLayout; AInSampleFmt: cint; AInSampleRate: cint;
  ALogOffset: cint; ALogCtx: pointer): cint; cdecl; external SWRESAMPLE_LIB;
function swr_init(ASwr: pointer): cint; cdecl; external SWRESAMPLE_LIB;
procedure swr_free(var ASwr: pointer); cdecl; external SWRESAMPLE_LIB;
function swr_convert(ASwr: pointer; AOut: PPByte; AOutCount: cint;
  AIn: PPByte; AInCount: cint): cint; cdecl; external SWRESAMPLE_LIB;
function swr_get_delay(ASwr: pointer; ABase: Int64): Int64; cdecl; external SWRESAMPLE_LIB;

{ ---------------- libswscale ----------------
  SwsContext is opaque (pointer) — like AVCodecContext for audio, none
  of its fields are ever read directly, it's only passed between the
  library's functions. }

function sws_getContext(ASrcW, ASrcH, ASrcFormat: cint; ADstW, ADstH, ADstFormat: cint;
  AFlags: cint; ASrcFilter, ADstFilter: pointer; AParam: pointer): pointer; cdecl; external SWSCALE_LIB;
function sws_scale(AC: pointer; const ASrcSlice: PPByte; const ASrcStride: PCInt;
  ASrcSliceY, ASrcSliceH: cint; const ADst: PPByte; const ADstStride: PCInt): cint; cdecl; external SWSCALE_LIB;
procedure sws_freeContext(AC: pointer); cdecl; external SWSCALE_LIB;

function FFErrorText(AErrNum: cint): utf8string;

implementation

function FFErrorText(AErrNum: cint): utf8string;
var
  Buf: array[0..255] of AnsiChar;
begin
  FillChar(Buf, SizeOf(Buf), 0);
  av_strerror(AErrNum, @Buf[0], SizeOf(Buf));
  Result := utf8string(PAnsiChar(@Buf[0]));
end;

end.
