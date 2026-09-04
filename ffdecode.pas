unit ffdecode;

{$mode objfpc}{$H+}

{ Минимальный, написанный заново биндинг к libavformat/libavcodec/
  libswresample ТЕКУЩЕГО FFmpeg (проверено на 9.0.1 — avformat-63.dll,
  avcodec-63.dll, avutil-61.dll, swresample-7.dll), не механический
  патч устаревшего ffmpeg-fpc (тот жёстко завязан на FFmpeg 3.4.1 /
  avcodec 57 — см. CLAUDE.md, запись про тупик с версией).

  Каждое поле каждой структуры ниже сверено построчно с настоящими
  заголовками из официальной сборки gyan.dev (ссылка на неё — прямо
  с ffmpeg.org/download.html, не сторонний сайт), а не угадано по
  памяти — тот же принцип, что уже принят в проекте (см. CLAUDE.md,
  пагинация getChatHistory). Структуры ОБЪЯВЛЕНЫ НЕ ЦЕЛИКОМ: только
  ведущие поля, вплоть до последнего реально читаемого этим юнитом —
  безопасно ровно потому, что ни одна из них не аллоцируется и не
  копируется на стороне Pascal (только FFmpeg их создаёт через
  av*_alloc*, Pascal только разыменовывает уже готовый указатель) —
  поля ПОСЛЕ последнего нужного никогда не читаются, их отсутствие в
  объявлении не создаёт риска неверного смещения для тех, что нужны.
  AVCodecContext оставлен ПОЛНОСТЬЮ непрозрачным (void-указатель) —
  ни одно его поле не читается напрямую нигде в этом юните, только
  передаётся между функциями библиотеки; вся информация о формате
  декодированного звука (частота/каналы/формат сэмплов) берётся из
  уже готового AVFrame после avcodec_receive_frame, а не из контекста
  — так весь риск несовпадения раскладки самой большой и chаще всего
  меняющейся структуры FFmpeg снят полностью. }

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
    Значения ПЕРЕСЧИТАНЫ программно (awk по самому enum'у в заголовке
    из того же архива gyan.dev, что и остальной биндинг — см. шапку
    файла), не угаданы по памяти: AV_PIX_FMT_NONE=-1,
    AV_PIX_FMT_YUV420P — первый элемент после него (0), AV_PIX_FMT_BGRA
    — 29-й по счёту (индекс 28). Видео Telegram-"гифок" (H.264/MP4) на
    выходе декодера почти всегда YUV420P; BGRA — формат назначения
    swscale, тот же порядок байт, что и TBGRABitmap/GDI DIB. }
  AV_PIX_FMT_YUV420P = 0;
  AV_PIX_FMT_BGRA     = 28;

  { --- libswscale/swscale.h --- }
  SWS_BILINEAR = 1 shl 1;

  AV_CHANNEL_ORDER_NATIVE = 1;
  AV_CH_LAYOUT_STEREO_MASK: UInt64 = 3;   { AV_CH_FRONT_LEFT(1) | AV_CH_FRONT_RIGHT(2) }
  AV_CH_LAYOUT_MONO_MASK:   UInt64 = 1;   { AV_CH_FRONT_CENTER }

  { FFERRTAG('E','O','F',' '), см. libavutil/error.h — тег фиксированный,
    не зависит от платформы/errno, поэтому безопасно вычислен константой. }
  AVERROR_EOF_VAL = -(Ord('E') or (Ord('O') shl 8) or (Ord('F') shl 16) or (Ord(' ') shl 24));

  { av_seek_frame: stream_index=-1 — таймстамп в AV_TIME_BASE
    (микросекундах), не в timebase конкретного потока; ffmpeg сам
    сконвертирует. AVSEEK_FLAG_BACKWARD — искать ближайший опорный
    кадр НЕ ПОЗЖЕ цели (проверено по libavformat/avformat.h). }
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
    u: UInt64;             { union: mask:uint64 либо map:pointer — тот же размер на x64 }
    opaque: pointer;
  end;

  { --- libavutil/frame.h : AVFrame ---
    Объявлено вплоть до ch_layout (включительно) — последнее поле,
    которое реально читается (sample_rate идёт раньше). }
  PAVFrame = ^TAVFrame;
  TAVFrame = record
    data: array[0..7] of PByte;
    linesize: array[0..7] of cint;
    extended_data: PPByte;
    width, height: cint;
    nb_samples: cint;
    format: cint;                    { enum AVSampleFormat для аудио }
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
    Вплоть до stream_index (включительно). }
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
    Только первые 3 поля — этого достаточно, чтобы найти аудио-поток
    (codec_type) и передать указатель дальше в avcodec_parameters_to_context
    непрозрачно (сам этот вызов копирует остальные поля средствами C,
    Pascal их не читает). }
  PAVCodecParameters = ^TAVCodecParameters;
  TAVCodecParameters = record
    codec_type: cint;      { enum AVMediaType }
    codec_id: cint;        { enum AVCodecID }
    codec_tag: UInt32;
  end;

  { --- libavformat/avformat.h : AVStream ---
    Вплоть до time_base (включительно) — нужен видео-плееру (videoplayer.
    pas) для перевода Frame.pts (в единицах time_base этого потока) в
    реальные секунды и паузы между кадрами при зацикленном
    воспроизведении "гифок". Поля между codecpar и time_base
    (priv_data) — тоже объявлены, просто чтобы смещение time_base не
    съехало, сами не читаются. Сверено построчно с настоящим
    заголовком (см. шапку файла), не угадано. }
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
    Вплоть до duration (включительно). }
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
{ Устанавливает опцию AVOption по имени, для ЛЮБОГО объекта с AVClass
  первым полем (AVCodecContext — один из них) — не требует знания
  раскладки самой структуры (первое поле AVClass у него уже общее для
  этого механизма), поэтому безопасно вызывать через непрозрачный
  pointer, как AVCodecContext и объявлен в этом юните. Используется
  для pkt_timebase (см. её же комментарий у вызова в mediaplayer.pas/
  videoplayer.pas) — единственный практичный способ выставить это поле
  БЕЗ того, чтобы разворачивать AVCodecContext (самую большую и чаще
  всего меняющуюся структуру FFmpeg) из полностью непрозрачного
  pointer в частично объявленную запись. }
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
function avcodec_send_packet(ACtx: pointer; APkt: PAVPacket): cint; cdecl; external AVCODEC_LIB;
function avcodec_receive_frame(ACtx: pointer; AFrame: PAVFrame): cint; cdecl; external AVCODEC_LIB;
{ Сбрасывает внутреннее состояние декодера (кадры в очереди на
  переупорядочивание и т.п.) — обязателен после av_seek_frame, иначе
  декодер продолжит попытки достроить кадры из данных ДО прыжка;
  videoplayer.pas зовёт его на каждом витке зацикленного
  воспроизведения "гифки" (см. её же комментарий). }
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
  Непрозрачный SwsContext (pointer) — как и AVCodecContext у аудио,
  ни одно его поле нигде не читается напрямую, только передаётся между
  функциями библиотеки. }

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
