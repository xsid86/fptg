unit tdmessages;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, base64, fgl, ExtCtrls, fpjson, jsonparser,
  constants, tdauth, tdsession, tdreq, tdchats;

type
  TMsgContentKind = (mckText, mckAudio, mckPhoto, mckAnimation, mckSticker,
    mckVoiceNote, mckFile, mckVideo, mckOther);

  { Три формата стикеров Telegram — проверено по официальным TDLib docs
    (classtd_1_1td__api_1_1sticker_format*.html), не угадано:
    stickerFormatWebp (статичная картинка), stickerFormatTgs
    (Lottie-вектор, gzip-сжатый JSON — см. lottieplayer.pas),
    stickerFormatWebm (видео, кодек VP9 в контейнере webm — тот же
    ffmpeg-декодер, что и у "гифки", videoplayer.pas, контейнер ему
    безразличен). }
  TStickerFormat = (sfWebp, sfTgs, sfWebm);

  { Состояние доставки исходящего сообщения. Отдельное имя от
    tdchats.TMsgSendState: framehistory будет использовать оба юнита
    разом, и совпадающее имя типа только путало бы. }
  TMsgDeliveryState = (mdsDelivered, mdsPending, mdsFailed);

  TMsgEntityKind = (mekNone, mekBold, mekItalic, mekUrl, mekTextUrl,
    mekCode, mekPre, mekStrikethrough, mekUnderline);

  { Стилевой/ссылочный диапазон внутри TMsgRow.PlainText.
    ByteStart/ByteLen — БАЙТОВЫЕ смещения в PlainText (utf8string),
    не символьные и не UTF-16: так же, как весь остальной проект
    индексирует utf8string (см. avatarcache.AvatarInitials). TDLib же
    считает offset/length сущности в UTF-16 code units — перевод
    делает Utf16RangeToByteRange при разборе сообщения, один раз. }
  TMsgEntity = record
    ByteStart: integer;
    ByteLen:   integer;
    Kind:      TMsgEntityKind;
    URL:       utf8string;   { только mekTextUrl; для mekUrl ссылка — сам текст }
  end;
  TMsgEntityArray = array of TMsgEntity;

  { Откуда переслано сообщение — variant-тип TDLib messageOrigin.
    mfoChannel — единственный случай, где известен message_id
    исходного поста (chat_id+message_id прямо в origin), поэтому
    только для него можно перейти к самому сообщению (см. OpenChat/
    JumpTo ниже). У mfoUser/mfoChat Telegram намеренно не отдаёт id
    исходного сообщения (приватность), у mfoHiddenUser нет вообще
    ничего, кроме имени. Подтверждено по tdlib_raw.log (все 4 варианта
    origin встречались) и docs.core.telegram.org, не по памяти. }
  TMsgForwardKind = (mfoNone, mfoUser, mfoChat, mfoChannel, mfoHiddenUser);

  { TMsgRow

    Чистые данные, без LCL — как и TChatRow. ContentRaw хранит JSON
    поля "content" целиком: это источник истины для будущих
    рендереров (фото/видео/стикеры), которым нужны поля, что модель
    сегодня не разбирает. PlainText/Entities — уже готовый к раскладке
    текст (сообщения или подписи), извлечённый из content один раз
    при разборе, чтобы не парсить JSON на каждую перерисовку. }
  TMsgRow = class
  public
    Id, ChatId:      Int64;
    SenderUserId:    Int64;   { 0, если отправитель — чат }
    SenderChatId:    Int64;   { 0, если отправитель — пользователь }
    Date, EditDate:  Int64;
    IsOutgoing:      boolean;
    Kind:            TMsgContentKind;
    ContentRaw:      utf8string;
    PlainText:       utf8string;
    Entities:        TMsgEntityArray;
    Delivery:        TMsgDeliveryState;
    { Репост — см. TMsgForwardKind. ForwardDate — время исходной
      публикации (не путать с Date — временем этого репоста). }
    ForwardKind:       TMsgForwardKind;
    ForwardUserId:     Int64;   { mfoUser }
    ForwardChatId:     Int64;   { mfoChat: sender_chat_id; mfoChannel: chat_id источника }
    ForwardMessageId:  Int64;   { mfoChannel: id сообщения в чате-источнике }
    ForwardSenderName: utf8string;   { mfoHiddenUser; mfoChat/mfoChannel: author_signature, может быть '' }
    ForwardDate:       Int64;
    { Реплай (messageReplyToMessage) — 0/0, если сообщение не реплай
      или реплай на сторис (messageReplyToStory, отдельный, более
      редкий вариант — не разбираем в этом заходе). TDLib НЕ кладёт
      сюда содержимое цитируемого сообщения (проверено по
      tdlib_raw.log: только chat_id/message_id и служебные поля) —
      имя/текст превью резолвит TTdMessages.ReplyPreview отдельно. }
    ReplyChatId:       Int64;
    ReplyMessageId:    Int64;
    { messageAudio.audio — только для Kind=mckAudio. AudioDuration в
      секундах (0, если не Kind=mckAudio или поле не пришло). Title/
      Performer — метаданные из самого файла (ID3 и т.п.), TDLib
      отдаёт их без скачивания/декода аудио; либо оба пустые — тогда
      в заголовке виджета показывается AudioFileName. }
    AudioDuration:     integer;
    AudioTitle:        utf8string;
    AudioPerformer:    utf8string;
    AudioFileName:     utf8string;
    { Сам скачиваемый файл (content.audio.audio, TDLib-объект file —
      не путать с content.audio, у аудио-сообщения оба уровня зовутся
      "audio", проверено по tdlib_raw.log). AudioFileId=0 — поле не
      пришло (не Kind=mckAudio). AudioLocalPath — пусто, пока файл не
      скачан; заполняется EnsureAudioFile/ApplyAudioFile, тем же
      приёмом, что TChatRow.PhotoPath в tdchats.pas. }
    AudioFileId:            integer;
    AudioLocalPath:         utf8string;
    AudioDownloadRequested: boolean;
    { messageVoiceNote.voice_note — только для Kind=mckVoiceNote. Тот же
      двухуровневый приём, что и у audio (content.voice_note.voice — сам
      скачиваемый файл, проверено по tdlib_raw.log), но без title/
      performer/file_name — TDLib их для голосовых не присылает, у
      виджета вместо них статичная подпись "Voice message" (см.
      TMsgScroller.LayoutAudioWidgets). }
    VoiceDuration:          integer;
    VoiceFileId:            integer;
    VoiceLocalPath:         utf8string;
    VoiceDownloadRequested: boolean;
    { messageDocument.document — только для Kind=mckFile. Тот же приём
      двойного "document" в JSON (content.document.file_name — метаданные,
      content.document.document — сам скачиваемый TDLib-объект file),
      что и у content.audio.audio, проверено по tdlib_raw.log. }
    DocFileName:     utf8string;
    DocFileSize:     Int64;
    DocFileId:            integer;
    DocLocalPath:         utf8string;
    DocDownloadRequested: boolean;
    { messagePhoto.photo — только для Kind=mckPhoto. PhotoWidth/Height —
      натуральные размеры выбранного (среднего, type='m') слоя photo.sizes,
      для расчёта превью. PhotoMinithumb — сырые (уже base64-декодированные)
      байты крошечного JPEG, приходит сразу в контенте без скачивания —
      для блюр-плейсхолдера, пока настоящий файл не скачан. }
    PhotoWidth, PhotoHeight: integer;
    PhotoMinithumb:          RawByteString;
    PhotoFileId:             integer;
    PhotoLocalPath:          utf8string;
    PhotoDownloadRequested:  boolean;
    { Самый большой доступный слой photo.sizes (по width*height, не по
      порядку в массиве — не полагаемся на то, что TDLib всегда отдаёт
      их от меньшего к большему) — для "Save as"/"Show in folder":
      сохранять надо оригинал, не мелкую превью-копию (PhotoFileId
      выше — сознательно средний размер, ради скорости инлайн-показа,
      не подходит для сохранения). Отдельная от PhotoFileId загрузка —
      разные file_id, разный кэш-файл TDLib. }
    PhotoBestFileId:            integer;
    PhotoBestLocalPath:         utf8string;
    PhotoBestDownloadRequested: boolean;
    { messageAnimation.animation — только для Kind=mckAnimation.
      AnimWidth/Height/Duration — натуральные размеры (пиксели) и
      длительность (секунды) исходного видео, тот же приём, что
      PhotoWidth/Height у фото (для расчёта превью тем же
      ComputePhotoPreviewSize). AnimMinithumb — та же роль, что
      PhotoMinithumb (крошечный JPEG прямо в контенте, для
      плейсхолдера, без скачивания). Сам скачиваемый файл —
      content.animation.animation (TDLib-объект file — тот же приём
      двойного имени "animation" в JSON, что у content.audio.audio,
      проверено по tdlib_raw.log) — ОДИН слой, не два, как у фото:
      Telegram отдаёт "гифку" одним MP4-файлом, без набора
      превью-размеров, поэтому один file_id/путь, без деления на
      "превью"/"оригинал". }
    AnimWidth, AnimHeight: integer;
    AnimDuration:          integer;
    AnimMinithumb:         RawByteString;
    AnimFileId:            integer;
    AnimLocalPath:         utf8string;
    AnimDownloadRequested: boolean;
    { True — постоянное свойство СТРОКИ (не разовый флаг, не снимается
      после первого срабатывания): настройки автозагрузки для этого
      типа диалога хотят, чтобы эта "гифка" не просто скачивалась, а
      сразу зацикленно проигрывалась (framehistory.pas,
      TMsgScroller.MaybeAutoDownload/LayoutAnimationWidgets — проверка
      идёт на КАЖДЫЙ заход раскладки, самовосстанавливающееся
      поведение, см. её же комментарий). Ручной клик пользователя это
      поле не трогает — только сама настройка автозагрузки. }
    AnimAutoPlay:          boolean;
    { messageVideo.video — только для Kind=mckVideo. Тот же приём
      двойного имени "video" в JSON (content.video.video — сам
      скачиваемый TDLib-объект file, content.video — метаданные),
      что и у content.animation.animation, проверено по tdlib_raw.log
      (55 совпадений, не по памяти). В отличие от "гифки" — видео
      реальное, со звуком, играется НЕ в цикле (framehistory.pas,
      TMediaPlayer — mediaplayer.pas), поэтому здесь нет поля-аналога
      AnimAutoPlay: автозагрузка для видео — только скачивание (см.
      MaybeAutoDownload), автостарт воспроизведения со звуком без
      клика пользователя не запрашивался и был бы навязчивым UX. }
    VideoWidth, VideoHeight: integer;
    VideoDuration:           integer;
    VideoMinithumb:          RawByteString;
    VideoFileId:             integer;
    VideoLocalPath:          utf8string;
    VideoDownloadRequested:  boolean;
    { messageSticker.sticker — только для Kind=mckSticker. Тот же приём
      двойного имени "sticker" в JSON (content.sticker.sticker — сам
      скачиваемый TDLib-объект file, content.sticker — метаданные),
      что и у content.video.video, проверено по tdlib_raw.log, не по
      памяти — включая порядок полей (сверено дополнительно с
      официальными docs.core.telegram.org/tdlib, classtd_1_1td__api_
      1_1sticker.html: sticker_ (file) идёт ПОСЛЕ thumbnail_, в отличие
      от video/audio/animation, где скачиваемый file — единственное
      поле с таким именем). Ширина/высота — "как задумано отправителем"
      (обычно 512x512 у TGS, произвольные у webp/webm) — реальный
      размер на экране определяет ComputeStickerSize (msglayout.pas),
      не эти цифры напрямую. Нет поля-аналога Minithumbnail: у стикера
      нет инлайн base64-превью (в отличие от фото/видео/"гифки") —
      только ОТДЕЛЬНЫЙ скачиваемый thumbnail.file (128x128 WebP), не
      используется в этом заходе (по выбору пользователя — сразу полная
      анимация, без промежуточного статичного плейсхолдера из
      thumbnail); до скачивания StickerLocalPath виджет просто пустой,
      как и остальные типы медиа до первого клика/автозагрузки. }
    StickerFormat:           TStickerFormat;
    StickerWidth, StickerHeight: integer;
    StickerFileId:           integer;
    StickerLocalPath:        utf8string;
    StickerDownloadRequested: boolean;
    { Кэш разметки msglayout. Тип держим непрозрачным (TObject), а не
      TMsgLayout, — иначе tdmessages пришлось бы знать про msglayout,
      получился бы цикл юнитов. Освобождается в деструкторе через
      обычный Free, виртуальный деструктор довершит остальное. }
    LayoutCache:     TObject;
    destructor Destroy; override;
  end;

  TMsgMap = specialize TFPGMap<Int64, TMsgRow>;

  { Превью цитируемого (reply_to) сообщения — только для реплаев на
    сообщение из уже загруженной истории (см. ReplyPreview/RequestReply)
    ИЛИ догруженное отдельно через getRepliedMessage, когда оно ещё не
    в FAll (более старое, чем текущая пагинация). Не путать с TMsgRow —
    сюда попадает только то, что нужно для отрисовки самой цитаты. }
  TMsgReplyPreview = class
  public
    SenderUserId, SenderChatId: Int64;
    PreviewText: utf8string;
  end;

  TReplyMap = specialize TFPGMap<Int64, TMsgReplyPreview>;

  { file_id аудиофайла -> сообщение — тот же приём, что TTdChats.FByFile
    для аватарок (tdchats.pas). }
  TAudioFileMap = specialize TFPGMap<integer, TMsgRow>;
  { file_id голосового сообщения -> сообщение — та же роль, что
    TAudioFileMap у аудио, отдельная карта (не общая): свой file_id,
    свой кэш-файл TDLib, тот же принцип, что у TDocFileMap ниже. }
  TVoiceFileMap = specialize TFPGMap<integer, TMsgRow>;
  { file_id документа -> сообщение — та же роль, что TAudioFileMap у
    аудио, отдельная карта (не общая с TAudioFileMap): у сообщения
    ровно один Kind, но раздельные карты проще для чтения, чем общая
    с веткой "какое поле обновлять" внутри. }
  TDocFileMap = specialize TFPGMap<integer, TMsgRow>;
  { То же для фото — своя карта, не общая с аудио/документом (см.
    комментарий у TDocFileMap). }
  TPhotoFileMap = specialize TFPGMap<integer, TMsgRow>;
  { То же для "гифок" (messageAnimation) — своя карта, не общая с
    остальными (см. комментарий у TDocFileMap). }
  TAnimFileMap = specialize TFPGMap<integer, TMsgRow>;
  { То же для видео-сообщений (messageVideo) — своя карта, не общая с
    остальными (см. комментарий у TDocFileMap). }
  TVideoFileMap = specialize TFPGMap<integer, TMsgRow>;
  { То же для стикеров (messageSticker) — своя карта, не общая с
    остальными (см. комментарий у TDocFileMap). }
  TStickerFileMap = specialize TFPGMap<integer, TMsgRow>;

  TTdMessagesEvent = procedure(Sender: TObject) of object;
  TTdMessagesErrorEvent = procedure(Sender: TObject; ACode: integer;
    const AMessage, AAction: utf8string) of object;
  { Пачка вокруг AMessageId применена (или сообщение уже было
    загружено) и FRows точно её видит — см. JumpTo/JumpDone. }
  TTdMessagesJumpEvent = procedure(Sender: TObject; AMessageId: Int64) of object;

  { TTdMessages

    История одного открытого чата. В отличие от TTdChats, модель — не
    постоянный наблюдатель за всем сразу: пока чат не открыт OpenChat,
    апдейты по чужим сообщениям ей неинтересны. getChatHistory, в
    отличие от loadChats, отдаёт сообщения прямо в ответе RPC (и в
    порядке от новых к старым) — see HistoryDone. }

  TTdMessages = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FReq:     TTdRequests;
    FAll:     TMsgMap;    { все известные сообщения открытого чата, по id }
    FRows:    TFPList;    { тот же набор, в хронологическом порядке }
    FTimer:   TTimer;
    FDirty:   boolean;
    FChatId:  Int64;
    FLoadingOlder: boolean;
    FOldestLoaded: boolean;
    FLoadLimit: integer;
    { Сколько раз подряд getChatHistory ответил, не продвинув историю
      дальше в прошлое. TDLib честно предупреждает в документации:
      сообщений может прийти меньше limit, даже если история не
      кончилась — часть иногда ещё летит из фонового префетча с
      сервера. Даём несколько попыток тем же якорем, прежде чем
      считать историю исчерпанной; см. HistoryDone/RetryTick. }
    FNoProgressRetries: integer;
    FRetryTimer: TTimer;
    FOnChanged: TTdMessagesEvent;
    FOnLoadingChanged: TTdMessagesEvent;
    FOnActionError: TTdMessagesErrorEvent;
    FOnJumpReady: TTdMessagesJumpEvent;

    { Превью цитируемых (reply_to) сообщений, которых ещё нет в FAll —
      см. ReplyPreview/RequestReply/GetRepliedDone. Отдельная от FAll
      структура намеренно: getRepliedMessage — разовый точечный запрос
      "что там за сообщение", не часть последовательной пагинации, и
      закидывать его результат в FAll сломало бы предположение
      "FAll — непрерывный, без дыр, диапазон истории", на которое
      опирается LoadOlder/якорь (см. комментарии там). }
    FReplyCache: TReplyMap;
    FReplyPending: array of Int64;

    { Скачивание аудиофайлов — см. EnsureAudioFile/ApplyAudioFile. }
    FByFile: TAudioFileMap;
    { Скачивание голосовых сообщений — см. EnsureVoiceFile/ApplyVoiceFile. }
    FVoiceByFile: TVoiceFileMap;
    { Скачивание файлов-документов — см. EnsureDocFile/ApplyDocFile. }
    FDocByFile: TDocFileMap;
    { Скачивание фото — см. EnsurePhotoFile/ApplyPhotoFile. }
    FPhotoByFile: TPhotoFileMap;
    { Скачивание оригинала (самого большого слоя) — см. EnsurePhotoBestFile/
      ApplyPhotoBestFile. Отдельная карта: разные file_id, разный кэш-файл
      TDLib, чем у превью-загрузки выше (см. комментарий у TMsgRow.PhotoBestFileId). }
    FPhotoBestByFile: TPhotoFileMap;
    { Скачивание "гифок" — см. EnsureAnimFile/ApplyAnimFile. }
    FAnimByFile: TAnimFileMap;
    { Скачивание видео-сообщений — см. EnsureVideoFile/ApplyVideoFile. }
    FVideoByFile: TVideoFileMap;
    { Скачивание стикеров — см. EnsureStickerFile/ApplyStickerFile. }
    FStickerByFile: TStickerFileMap;

    function GetCount: integer;
    function GetRow(AIndex: integer): TMsgRow;
    function Lookup(AId: Int64): TMsgRow;
    function Obtain(AId: Int64): TMsgRow;

    procedure ApplyMessage(AMsg: TJSONObject);
    procedure ApplyContentUpdate(AChatId, AMessageId: Int64; ANewContent: TJSONObject);
    procedure ExtractFormatted(AContent: TJSONObject; const AType: utf8string;
      out APlainText: utf8string; out AEntities: TMsgEntityArray);
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
      out AWidth, AHeight, ADuration: integer; out AMinithumb: RawByteString;
      out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadVideoDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyVideoFile(AFile: TJSONObject);
    procedure ExtractStickerMeta(AContent: TJSONObject; const AType: utf8string;
      out AWidth, AHeight: integer; out AFormat: TStickerFormat;
      out AFileId: integer; out ALocalPath: utf8string);
    procedure DownloadStickerDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyStickerFile(AFile: TJSONObject);

    procedure Touch;
    procedure Rebuild(Sender: TObject);
    procedure SetLoadingOlder(AValue: boolean);
    procedure HistoryDone(Sender: TObject; const AResp: TTdResponse);
    procedure RetryTick(Sender: TObject);
    procedure SendTextDone(Sender: TObject; const AResp: TTdResponse);
    procedure ActionDone(Sender: TObject; const AResp: TTdResponse);
    procedure JumpDone(Sender: TObject; const AResp: TTdResponse);
    function IsReplyPending(AId: Int64): boolean;
    procedure MarkReplyPending(AId: Int64);
    procedure ClearReplyPending(AId: Int64);
    procedure RequestReply(AMessageId: Int64);
    procedure GetRepliedDone(Sender: TObject; const AResp: TTdResponse);
  public
    { Модель принадлежит аккаунту, резолвер передаётся снаружи —
      тот же приём, что у TTdChats. }
    constructor Create(AOwner: TComponent; const ASession: ITdSession;
      AReq: TTdRequests); reintroduce;
    destructor Destroy; override;

    procedure Clear;
    { Переключение на другой чат. Тот же id — no-op (кроме
      AJumpToMessageId <> 0, см. ниже). AJumpToMessageId <> 0 — вместо
      обычной LoadOlder (свежие сообщения, с конца) грузит пачку ВОКРУГ
      этого id (см. JumpTo) — переход по цитате репоста на чужое
      сообщение в другом (или том же) чате, тем же путём, что и
      "перейти к сообщению" в официальном клиенте: открыть чат и
      прокрутить к сообщению, а не строить шэрабельную ссылку
      (getMessageLink требует членства в чате — не наш случай для
      источника репоста, которого обычно нет в списке чатов). }
    procedure OpenChat(AChatId: Int64; AJumpToMessageId: Int64 = 0);
    procedure CloseChat;
    { Подгрузить более старую страницу истории. }
    procedure LoadOlder;
    { Индекс сообщения в Rows[] по его id, -1 если не загружено.
      Нужен framehistory для выделения текста через несколько
      сообщений и для удержания якоря прокрутки при LoadOlder. }
    function IndexOfId(AId: Int64): integer;

    procedure SendText(const AText: utf8string);
    procedure MarkRead(const AMessageIds: array of Int64);
    { Догрузить (если ещё не загружено) и подготовить к показу пачку
      сообщений ВОКРУГ AMessageId в ТЕКУЩЕМ открытом чате — не путать с
      OpenChat(AChatId, AJumpToMessageId), который сначала переключает
      чат целиком. Готовность — через OnJumpReady, синхронно (без RPC),
      если AMessageId уже в FAll. }
    procedure JumpTo(AMessageId: Int64);
    { Данные для отрисовки цитаты reply_to — только для реплаев В ТОМ
      ЖЕ чате (AChatId <> ChatId — кросс-чатные реплаи, напр. канал и
      его группа обсуждения, не поддержаны в этом заходе: редкий
      случай, не стоит заводить под него кэш с составным ключом
      chat+message — возвращает False без попытки резолва).
      Возвращает True и данные, если превью уже есть (в FAll или в
      FReplyCache); False — превью ещё нет, но уже запущен (или вот-вот
      запустится) getRepliedMessage, результат придёт через OnChanged. }
    function ReplyPreview(AChatId, AMessageId: Int64;
      out ASenderUserId, ASenderChatId: Int64; out APreviewText: utf8string): boolean;
    { Запросить скачивание аудиофайла сообщения (см. AudioFileId), если
      ещё не скачан и не запрошен. Результат приходит через updateFile
      -> Touch (ARow.AudioLocalPath заполнится сам); framehistory узнаёт
      об этом обычной перерисовкой, отдельного события не заводим — тот
      же приём, что уже принят для аватарок (см. CLAUDE.md). }
    procedure EnsureAudioFile(ARow: TMsgRow);
    { То же самое для голосового сообщения (см. VoiceFileId) — тем же
      приёмом. }
    procedure EnsureVoiceFile(ARow: TMsgRow);
    { EnsureAudioFile/EnsureVoiceFile под одним именем — та же развязка
      audio/voice_note "для вызывающего это один проигрываемый трек",
      что и у PlayableLocalPath (см. её комментарий). }
    procedure EnsurePlayableFile(ARow: TMsgRow);
    { То же самое для файла-документа (см. DocFileId) — тем же приёмом. }
    procedure EnsureDocFile(ARow: TMsgRow);
    { То же самое для фото (см. PhotoFileId) — тем же приёмом. }
    procedure EnsurePhotoFile(ARow: TMsgRow);
    { Оригинал фото (см. PhotoBestFileId) — для "Save as"/"Show in
      folder", отдельно от превью выше (см. комментарий у поля). }
    procedure EnsurePhotoBestFile(ARow: TMsgRow);
    { То же самое для "гифки" (см. AnimFileId) — тем же приёмом. }
    procedure EnsureAnimFile(ARow: TMsgRow);
    { То же самое для видео-сообщения (см. VideoFileId) — тем же приёмом. }
    procedure EnsureVideoFile(ARow: TMsgRow);
    { То же самое для стикера (см. StickerFileId) — тем же приёмом. }
    procedure EnsureStickerFile(ARow: TMsgRow);

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

    property Session: ITdSession read FSession;
    property OnChanged: TTdMessagesEvent read FOnChanged write FOnChanged;
    property OnActionError: TTdMessagesErrorEvent read FOnActionError write FOnActionError;
    property OnLoadingChanged: TTdMessagesEvent read FOnLoadingChanged write FOnLoadingChanged;
    property OnJumpReady: TTdMessagesJumpEvent read FOnJumpReady write FOnJumpReady;
  end;

{ Значок статуса ИСХОДЯЩЕГО сообщения — то же понятие, что ChatReceipt в
  tdchats.pas (переиспользуем его TChatReceipt, второй enum не заводим).
  ALastReadOutbox — TChatRow.LastReadOutbox чата, которому принадлежит
  ARow; framehistory.pas достаёт его через TdChatList.Lookup(ARow.ChatId). }
function MessageReceipt(ARow: TMsgRow; ALastReadOutbox: Int64): TChatReceipt;

{ Путь к уже скачанному файлу трека для проигрывания — messageAudio и
  messageVoiceNote хранят его в РАЗНЫХ полях (AudioLocalPath/
  VoiceLocalPath, разные file_id, разные карты скачивания в TTdMessages),
  но framehistory.pas работает с ними как с ОДНИМ проигрываемым треком:
  TAudioWidget — общий виджет и для аудио, и для голосового (по прямому
  запросу пользователя, "функционал и внешний вид идентичные"), поэтому
  и код вокруг проигрывания (StartPlayback/AudioPlayClick/ModelChanged)
  не должен на каждом шагу решать заново, какое из двух полей читать.
  '' — не Kind=mckAudio/mckVoiceNote, или файл ещё не скачан. }
function PlayableLocalPath(ARow: TMsgRow): utf8string;
{ Та же развязка audio/voice_note, для длительности (AudioDuration/
  VoiceDuration) — нужна при перемотке (AFraction * длительность). }
function PlayableDuration(ARow: TMsgRow): integer;

implementation

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

{ Длина UTF-8 символа по ведущему байту — тот же приём, что в
  avatarcache.Utf8CharLen. Не переиспользуем сам юнит: avatarcache
  тянет Graphics/BGRABitmap, а tdmessages обязан остаться без LCL,
  как и tdchats. }
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

{ TDLib считает offset/length сущности в UTF-16 code units (суррогатная
  пара — 2 единицы). PlainText — utf8string, индексируем байтами.
  Проходим строку один раз, декодируя кодпоинты, и считаем совпадающие
  байтовые границы. Сущность, чья граница провалилась бы ВНУТРЬ
  суррогатной пары (можно только для не-BMP символов, то есть
  большинства эмодзи), округляется до ближайшей границы кодпоинта —
  такое встречается редко и не критично для v1. }
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
        AByteStart := I;   { TargetStart попал внутрь последнего символа }
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
    { Большая анимированная эмодзи-реакция (просто эмодзи в сообщении,
      без текста вокруг) — TDLib заворачивает её В ТОЧНОСТИ в тот же
      sticker-объект, что и обычный стикер, просто на один уровень
      глубже (content.animated_emoji.sticker вместо content.sticker,
      см. ExtractStickerMeta) — проверено по tdlib_raw.log (106
      вхождений за сессию, заметно ЧАЩЕ обычных стикеров, 32) — тот же
      виджет, тот же рендер, никакого отдельного Kind не нужно. }
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
  FStickerByFile.Clear;
  SetLength(FReplyPending, 0);
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
    { Тот же чат — обычно no-op, но переход по цитате может указывать
      на сообщение в ТЕКУЩЕМ же открытом чате (репост из соседнего
      сообщения той же переписки) — историю целиком не перезагружаем,
      просто догружаем/показываем нужный участок. }
    if AJumpToMessageId <> 0 then begin
      JumpTo(AJumpToMessageId);
    end;
    Exit;
  end;
  { closeChat/openChat — не для данных (те идут апдейтами и RPC-ответами
    независимо), а чтобы СКАЗАТЬ TDLib, какой чат сейчас реально
    показан пользователю. Без этого TDLib считает себя вправе вытеснять
    кэш сообщений давно не "открытого" явно чата и присылает
    updateDeleteMessages с from_cache:true — раньше это принималось за
    настоящее удаление (см. TdUpdate), и открытый часами чат мог
    свестись к одному сообщению. }
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
  { Намеренно линейный проход по FRows, а не FAll.IndexOf: FAll и
    FRows могут разойтись на время окна коалесации (до 50 мс после
    Touch, пока не сработал Rebuild) — LoadOlder добавляет в FAll
    сообщения с МЕНЬШИМ id, то есть сдвигает индексы существующих
    записей в FAll раньше, чем FRows это увидит. Линейный проход по
    FRows всегда согласован с Count/Rows[], которыми и пользуется
    вызывающий (framehistory). }
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

  { FAll отсортирован по id (TFPGMap.Sorted), а id сообщений в TDLib
    монотонно неубывающий в рамках чата — то есть FAll.Data уже в
    хронологическом порядке, пересортировка не нужна. }
  FRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    FRows.Add(FAll.Data[I]);
  end;

  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
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
begin
  if FLoadingOlder or FOldestLoaded or (FReq = nil) or (FChatId = 0) then begin
    Exit;
  end;
  if (FSession = nil) or (FSession.State <> tasReady) then begin
    Exit;
  end;
  SetLoadingOlder(True);

  { ВАЖНО: якорь берём из FAll, а не FRows. FRows — производный вид,
    пересобирается отложенно, по 50-мс таймеру (Touch/Rebuild), а FAll
    обновляется СИНХРОННО внутри ApplyMessage. Если якорь брать из
    FRows, есть окно до 50 мс, где FRows ещё не видит только что
    применённый ответ — LoadOlder, вызванный в этом окне (пользователь
    продолжает скроллить, ScrollerNearTop стреляет повторно), уходит
    со старым, уже устаревшим from_message_id. Подтверждено логом
    (tdlib_raw.log): req:13/req:14 ушли с ТЕМ ЖЕ from_message_id, что
    и req:12, хотя req:12 к тому моменту уже сдвинул историю дальше —
    именно потому, что LoadOlder читал ещё не пересобранный FRows.

    from_message_id = якорь МИНУС TD_MESSAGE_ID_STEP (не сам якорь) при
    offset:0 — не сама известная граница, а соседняя "позиция" чуть
    старше нашего самого старого сообщения. offset:0 у TDLib
    "начинается точно с from_message_id"; если передавать сам якорь
    (уже известное, закэшированное сообщение), это на практике не
    двигает историю вовсе — см. предыдущую попытку с отрицательным
    offset, которая хоть и не залипала намертво, но давала эмпирически
    ровно одно новое сообщение за запрос из-за 49/50 перекрытия окна
    при offset:-(limit-1).

    ВНИМАНИЕ (одна версия этого фикса уже наступила на эти грабли):
    вычитать нужно именно TD_MESSAGE_ID_STEP, НЕ произвольную единицу —
    id обязан остаться кратным этой константе, иначе TDLib отвечает
    "code":400 "Invalid value of parameter from_message_id specified"
    на КАЖДЫЙ такой запрос, а поскольку ошибка не продвигает якорь,
    следующий вызов LoadOlder пересчитывает ТОТ ЖЕ невалидный id и
    получает ту же ошибку — без защиты в HistoryDone (см. ниже) это
    плотный бесконечный цикл запрос/ошибка, что и произошло. }
  if FAll.Count = 0 then begin
    Anchor := 0;
    Offset := 0;
  end else begin
    Anchor := FAll.Data[0].Id - TD_MESSAGE_ID_STEP;
    Offset := 0;
  end;

  { ВНИМАНИЕ: имена параметров сверены по общему знанию схемы TDLib,
    не по локальному td_api.tl (его в репозитории нет) — при первом
    реальном запуске стоит перепроверить по документации.

    Tag = FChatId: если пользователь успеет переключиться на другой
    чат, пока этот запрос летит, ответ придёт УЖЕ для чужого FChatId.
    HistoryDone сверяет Tag и молча игнорирует такой ответ — иначе он
    мог бы сбросить FLoadingOlder/FOldestLoaded ТЕКУЩЕГО чата чужими
    данными (PtrInt на этой платформе — 8 байт, как и Int64: проект
    собирается только под win64). }
  FReq.SendRequest('getChatHistory',
    '"chat_id":' + utf8string(IntToStr(FChatId)) +
    ',"from_message_id":' + utf8string(IntToStr(Anchor)) +
    ',"offset":' + utf8string(IntToStr(Offset)) +
    ',"limit":' + utf8string(IntToStr(FLoadLimit)) +
    ',"only_local":false', @HistoryDone, PtrInt(FChatId));
end;

procedure TTdMessages.HistoryDone(Sender: TObject; const AResp: TTdResponse);
var
  Arr: TJSONArray;
  I: integer;
  OldestBefore, OldestAfter: Int64;
begin
  { Ответ по чату, который пользователь уже закрыл/сменил, пока
    запрос летел — не наш случай, состояние ТЕКУЩЕГО чата не трогаем. }
  if AResp.Tag <> PtrInt(FChatId) then begin
    Exit;
  end;

  SetLoadingOlder(False);
  if not AResp.Success then begin
    if AResp.ErrorCode = 404 then begin
      FOldestLoaded := True;
      Exit;
    end;
    if Assigned(FOnActionError) then begin
      { Иначе сбой getChatHistory (напр. неверное имя параметра) тонет
        молча: список остаётся пустым без единого следа почему. }
      FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'history');
    end;
    { ВАЖНО: ошибка обязана идти через ТОТ ЖЕ счётчик/бэкофф, что и
      "успех без продвижения" ниже, а не просто Exit. Причина — не
      гипотетическая: именно отсутствие этой защиты превратило один
      неверно посчитанный from_message_id в плотный бесконечный цикл
      запрос→ошибка→(FLoadingOlder уже False)→MaybeLoadMore/
      ScrollerNearTop зовёт LoadOlder снова→тот же якорь→та же ошибка
      (см. tdlib_raw.log: 108 тысяч запросов подряд с кодом 400).
      Если LoadOlder при следующем вызове пересчитает тот же самый
      негодный якорь — за MAX_NO_PROGRESS_RETRIES попыток сдаёмся и
      считаем историю исчерпанной, вместо бесконечного долбления. }
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

  { Самое старое сообщение ДО применения пачки — берём из FAll
    (отсортирован по id), а не FRows: FRows пересобирается отложенно,
    по 50-мс таймеру Touch/Rebuild, и в этот самый момент ещё не
    видит то, что мы вот-вот применим. }
  if FAll.Count = 0 then begin
    OldestBefore := 0;
  end else begin
    OldestBefore := FAll.Data[0].Id;
  end;

  { getChatHistory отдаёт сообщения от новых к старым — применяем в
    обратном порядке, чтобы FAll заполнялся от старых к новым.
    Каждое сообщение — в своём try/except: одна неожиданная форма
    JSON (например, ещё не встречавшийся тип content) не должна
    обрывать всю пачку и уж тем более не должна вылететь наружу через
    TTdRequests.Resolve, где её никто не ловит. }
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

  { НЕ "Arr.Count < FLoadLimit ⇒ история кончилась": по документации
    getChatHistory число реально возвращённых сообщений выбирает сам
    TDLib "для оптимальной производительности" и может быть меньше
    limit ЗАДОЛГО до того, как история кончится (официально
    подтверждено: "fewer messages may be returned... even if the end
    of the message history has not been reached" — иногда потому что
    остальное ещё летит из фонового префетча с сервера, см.
    github.com/tdlib/td issues #236 и #740). Единственный надёжный
    признак конца — пустой массив (см. выше) или 404.

    Но точно так же нельзя бесконечно долбить getChatHistory тем же
    якорем без счётчика: если пачка НЕ продвинула историю дальше в
    прошлое (частый случай — TDLib присылает 1 дубликат самого
    якоря, см. комментарий мейнтейнера в issue #236), даём ещё
    несколько попыток С ЗАДЕРЖКОЙ (через FRetryTimer, не синхронно —
    синхронный повтор внутри этого же колбэка уже один раз подвесил
    приложение плотным циклом запрос/ответ/перестройка). Только после
    MAX_NO_PROGRESS_RETRIES неудач подряд считаем историю
    исчерпанной. }
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
    { Остальные типы, у которых бывает подпись (фото, видео, аудио,
      документ, анимация, ...), хранят её тоже как formattedText —
      в поле caption. }
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
    if EKind = mekTextUrl then begin
      AEntities[N].URL := JGetStr(TypeObj, 'url');
    end else begin
      AEntities[N].URL := '';
    end;
    Inc(N);
  end;
  SetLength(AEntities, N);
end;

{ messageAudio.audio — метаданные из самого файла (ID3 и т.п.), TDLib
  отдаёт их сразу в content, без скачивания/декода аудио. Проверено по
  tdlib_raw.log: "content":{"@type":"messageAudio","audio":{"@type":
  "audio","duration":214,"title":"...","performer":"...","file_name":
  "..."}}. }
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

  { content.audio.audio — сам скачиваемый файл (TDLib-объект file),
    отдельный уровень от content.audio (метаданные трека) — оба зовутся
    "audio", проверено по tdlib_raw.log, не по памяти. }
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

{ messageVoiceNote.voice_note — тот же двухуровневый приём, что и
  content.audio.audio: content.voice_note — метаданные (тут — только
  duration, TDLib не даёт title/performer/file_name для голосовых),
  content.voice_note.voice — сам скачиваемый TDLib-объект file.
  Проверено по tdlib_raw.log ("voice_note":{"@type":"voiceNote",
  "duration":7,"waveform":"...","mime_type":"audio/ogg","voice":
  {"@type":"file",...}}), не по памяти. waveform — есть, не читаем:
  виджет "тот же, что аудио" не рисует форму волны (см. запрос
  пользователя — идентичный внешний вид с TAudioWidget). }
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

{ messageDocument.document — тот же приём двойного "document" в JSON,
  что и content.audio.audio выше: content.document — метаданные (имя
  файла), content.document.document — сам скачиваемый TDLib-объект
  file. Проверено по tdlib_raw.log, не по памяти. }
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

{ messagePhoto.photo — content.photo.minithumbnail — крошечный JPEG
  прямо в контенте (base64, поле data), не нужно скачивать; content.
  photo.sizes — массив photoSize (type/width/height/photo — сам
  скачиваемый TDLib-объект file), проверено по tdlib_raw.log, не по
  памяти. Два РАЗНЫХ слоя выбираются из одного массива за один проход:
  AFileId/ALocalPath — НАИМЕНЬШИЙ слой, которого хватает, чтобы заполнить
  превью PHOTO_MAX_WIDTH×PHOTO_MAX_HEIGHT (msglayout.pas) БЕЗ апскейла —
  раньше здесь был жёстко зашит type='m' (по прямому запросу пользователя
  переделано: 'm' у Telegram — фиксированный бокс примерно 320px,
  заметно мельче PHOTO_MAX_WIDTH/HEIGHT=400, и ComputePhotoPreviewSize
  всё равно не станет его увеличивать — итог был не "наш плохой ресемпл",
  а честно мелкая, к тому же сильнее сжатая JPEG-прослойка, показанная
  МЕНЬШЕ, чем место под неё в блоке). Если ни один слой не дотягивает до
  цели (сам исходник мельче PHOTO_MAX_WIDTH/HEIGHT) — тот же слой, что и
  ABestFileId ниже, крупнее найти неоткуда. ABestFileId/ABestLocalPath —
  слой с максимальным width*height, для "Save as"/"Show in folder"
  (сохранять нужно оригинал, не превью-копию) — по площади, а не по
  порядку в массиве, не полагаемся на то, что TDLib всегда отдаёт sizes
  от меньшего к большему. }
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

{ messageAnimation.animation — content.animation.minithumbnail — тот же
  крошечный JPEG, что и у фото (base64, поле data), без скачивания;
  content.animation.animation — сам скачиваемый TDLib-объект file (тот
  же приём двойного имени, что content.audio.audio) — проверено по
  tdlib_raw.log (реальные сообщения с "гифками" уже встречались там),
  не по памяти. В отличие от фото — ОДИН слой, не массив sizes: Telegram
  отдаёт "гифку" одним MP4-файлом целиком, набора превью-размеров нет. }
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

{ messageVideo.video — тот же приём двойного имени "video" в JSON
  (content.video.video — сам скачиваемый TDLib-объект file,
  content.video — метаданные, включая content.video.minithumbnail —
  крошечный JPEG, без скачивания), что и у content.animation.animation
  — проверено по tdlib_raw.log (55 совпадений с реальными видео-
  сообщениями), не по памяти. Один слой, как у "гифки", не массив
  sizes, как у фото. }
procedure TTdMessages.ExtractVideoMeta(AContent: TJSONObject; const AType: utf8string;
  out AWidth, AHeight, ADuration: integer; out AMinithumb: RawByteString;
  out AFileId: integer; out ALocalPath: utf8string);
var
  VideoObj, MiniObj, FileObj, LocalObj: TJSONObject;
  B64: utf8string;
begin
  AWidth := 0;
  AHeight := 0;
  ADuration := 0;
  AMinithumb := '';
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

  MiniObj := JGetObj(VideoObj, 'minithumbnail');
  if MiniObj <> nil then begin
    B64 := JGetStr(MiniObj, 'data');
    if B64 <> '' then begin
      AMinithumb := DecodeStringBase64(string(B64));
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
    { content.animated_emoji.sticker — тот же sticker-объект, что и у
      обычного стикера, на один уровень глубже (см. её же комментарий
      в ContentKindFromType). animated_emoji может в принципе прийти
      без стикера вовсе (TDLib формально допускает sticker=null, если
      для этого эмодзи анимация не настроена) — JGetObj вернёт nil,
      обработано ниже тем же общим Exit, что и у обычного стикера. }
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

  { content.sticker.sticker — тот же приём двойного имени, что и у
    video/audio/animation, но ЗДЕСЬ поле идёт ПОСЛЕ thumbnail (сверено
    по официальным docs.core.telegram.org/tdlib, не угадано и не по
    аналогии с остальными типами — там порядок другой). }
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

  { forward_info отсутствует у обычных сообщений (JGetObj вернёт nil) —
    origin разбирается по @type, см. комментарий у TMsgForwardKind. }
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

  { reply_to — только messageReplyToMessage (ответ на сообщение);
    messageReplyToStory (ответ на сторис) не разбираем, ReplyMessageId
    остаётся 0 — цитата тогда просто не рисуется, как и без reply_to
    вовсе. Сам TDLib НЕ кладёт сюда содержимое цитируемого сообщения —
    только chat_id/message_id (проверено по tdlib_raw.log), текст/имя
    для отрисовки резолвит ReplyPreview отдельно, лениво. }
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

  ContentObj := JGetObj(AMsg, 'content');
  if ContentObj <> nil then begin
    T := JGetStr(ContentObj, '@type');
    NewContentRaw := utf8string(ContentObj.AsJSON);
  end else begin
    T := '';
    NewContentRaw := '';
  end;

  { То же самое сообщение может прилететь повторно байт-в-байт —
    перекрытие страниц пагинации, повторный getChatHistory и т.п.
    Если контент не изменился, не гоняем разбор entities и не рушим
    LayoutCache: у сообщений с медиа content — это base64-превью,
    разбор и последующий пересчёт переноса текста заметно нагружают
    главный поток, а при пачке из полусотни таких сообщений это и
    выглядит как подвисание интерфейса. }
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
    R.VideoMinithumb, R.VideoFileId, R.VideoLocalPath);
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
    R.VideoMinithumb, R.VideoFileId, R.VideoLocalPath);
  ExtractStickerMeta(ANewContent, T, R.StickerWidth, R.StickerHeight, R.StickerFormat,
    R.StickerFileId, R.StickerLocalPath);
  if R.LayoutCache <> nil then begin
    R.LayoutCache.Free;
    R.LayoutCache := nil;
  end;
  Touch;
end;

procedure TTdMessages.SendText(const AText: utf8string);
var
  TextObj, Content: TJSONObject;
  Body: utf8string;
begin
  if (FReq = nil) or (FChatId = 0) or (Trim(string(AText)) = '') then begin
    Exit;
  end;

  { Текст пользователя может содержать кавычки/бэкслеши/переводы строк —
    тело строим через TJSONObject.AsJSON, а не конкатенацией строк,
    как это уже сделано в TTdChats.SetMuted для notification_settings. }
  TextObj := TJSONObject.Create;
  TextObj.Strings['@type'] := 'formattedText';
  TextObj.Strings['text'] := string(AText);

  Content := TJSONObject.Create;
  try
    Content.Strings['@type'] := 'inputMessageText';
    Content.Add('text', TextObj);   { Content становится владельцем TextObj }
    Body := '"chat_id":' + utf8string(IntToStr(FChatId)) +
            ',"input_message_content":' + utf8string(Content.AsJSON);
  finally
    Content.Free;
  end;

  { Ответ sendMessage — сам объект нового сообщения, отдельного
    временного отрицательного id заводить не нужно: см. SendTextDone. }
  FReq.SendRequest('sendMessage', Body, @SendTextDone);
end;

procedure TTdMessages.SendTextDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    ApplyMessage(AResp.Obj);
  end else if Assigned(FOnActionError) then begin
    FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, 'send');
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
    { Уже загружено — например, повторный клик на ту же цитату, или
      сообщение попало в окно предыдущей обычной подгрузки истории.
      RPC не нужен, сразу сообщаем о готовности. }
    if Assigned(FOnJumpReady) then begin
      FOnJumpReady(Self, AMessageId);
    end;
    Exit;
  end;
  { offset:-(N) — "ещё N сообщений НОВЕЕ от_message_id" (официальные
    docs.core.telegram.org/tdlib, getChatHistory.offset), в дополнение
    к самому AMessageId и более старым, до заполнения limit. Тем самым
    сообщение оказывается не в самом конце пачки, а где-то посередине —
    видна часть переписки вокруг него, не только то, что было раньше. }
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
    { Тот же порядок, что и в HistoryDone: getChatHistory отдаёт от
      новых к старым, применяем в обратном порядке. }
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

  { ApplyMessage выше только помечает FDirty (Touch) — настоящая
    пересборка FRows идёт отложенно, по 50-мс таймеру. Вызывающему
    (см. framehistory.pas: TMsgScroller.ScrollToMessage) нужен готовый,
    актуальный FRows/FOffsets ПРЯМО в момент OnJumpReady — синхронный
    Rebuild здесь, а не ожидание таймера, как в обычном потоке апдейтов. }
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

{ То же самое сопоставление "тип контента -> подпись превью", что и
  MessagePreview (tdchats.pas), но по уже разобранным Kind/PlainText
  TMsgRow, а не по сырому JSON — не перепарсивать ContentRaw на каждую
  отрисовку уже загруженной цитаты (единственный путь, где это нужно:
  сообщение уже в FAll, см. ReplyPreview). Для ДОгружаемых через
  getRepliedMessage сообщений используется сам MessagePreview напрямую
  с сырым JSON ответа — см. GetRepliedDone. }
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
begin
  Id := Int64(AResp.Tag);
  ClearReplyPending(Id);
  if not AResp.Success then begin
    { Молча не показываем цитату — тем же приёмом, что и промах getUser
      в tdusers.pas: цитируемое сообщение могло быть удалено, это не
      повод засорять статус-строку на каждый такой случай в истории. }
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
  P.PreviewText := MessagePreview(JGetObj(AResp.Obj, 'content'));

  if FReplyCache.IndexOf(Id) < 0 then begin
    FReplyCache.Add(Id, P);
  end else begin
    P.Free;   { не должно случаться (см. IsReplyPending), но не течь на всякий случай }
  end;
  Touch;
end;

{ Скачивание аудиофайла — тот же приём, что TTdChats.EnsureAvatar/
  DownloadDone/ApplyFile (tdchats.pas) для аватарок, адаптированный на
  TMsgRow вместо TChatRow: файл может уже быть на диске, тогда путь
  придёт прямо в ответе на downloadFile и updateFile может не прийти
  вовсе — оба случая ведут в ApplyAudioFile. }
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
  { priority 32 — высший: в отличие от аватарок (фон, не мешать
    истории), это явный запрос пользователя на прослушивание,
    ждать его не должны. }
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

{ Скачивание голосового сообщения — точная копия EnsureAudioFile/
  DownloadAudioDone/ApplyAudioFile выше, отдельная от них ровно потому,
  что file_id аудио и file_id голосового — раздельные карты (FByFile/
  FVoiceByFile), тот же принцип, что уже у документа/фото. }
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
  { priority 32 — та же логика, что у аудио: явный запрос пользователя
    на прослушивание, не фоновая подгрузка. }
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

{ Скачивание файла-документа — точная копия EnsureAudioFile/
  DownloadAudioDone/ApplyAudioFile выше, отдельная от них ровно потому,
  что file_id аудио и file_id документа — раздельные карты (FByFile/
  FDocByFile), см. комментарий у TDocFileMap. }
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
  { priority 32 — высший, как и у аудио: явный запрос пользователя
    "хочу сохранить этот файл", не фоновая подгрузка. }
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

{ Скачивание фото — точная копия EnsureDocFile/DownloadDocDone/
  ApplyDocFile выше, отдельная от них ровно по той же причине, что и
  документ от аудио (см. комментарий у TPhotoFileMap). }
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

procedure TTdMessages.ApplyPhotoFile(AFile: TJSONObject);
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
  Idx := FPhotoByFile.IndexOf(FileId);
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

  R := FPhotoByFile.Data[Idx];
  if R.PhotoLocalPath = Path then begin
    Exit;
  end;
  R.PhotoLocalPath := Path;
  Touch;
end;

{ Оригинал (самый большой слой) — точная копия EnsurePhotoFile/
  DownloadPhotoDone/ApplyPhotoFile выше, отдельная своя карта
  (FPhotoBestByFile), потому что file_id и, соответственно, кэш-путь
  TDLib у оригинала и у превью-копии — РАЗНЫЕ (см. комментарий у
  TMsgRow.PhotoBestFileId). }
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

{ "Гифка" — один файл, точная копия EnsureDocFile/DownloadDocDone/
  ApplyDocFile по форме (не EnsurePhotoFile — у той два слоя, animation
  устроен проще), своя карта FAnimByFile. priority 32 — то же самое
  "явный интерес пользователя, не фон", что и у остальных Ensure*File. }
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

{ Видео-сообщение — тот же приём, один файл, что и у "гифки" выше,
  своя карта FVideoByFile. }
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
begin
  if AFile = nil then begin
    Exit;
  end;
  FileId := JGetInt(AFile, 'id');
  Idx := FVideoByFile.IndexOf(FileId);
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

  R := FVideoByFile.Data[Idx];
  if R.VideoLocalPath = Path then begin
    Exit;
  end;
  R.VideoLocalPath := Path;
  Touch;
end;

{ Стикеры — по прямому запросу пользователя ("полная анимация, включая
  TGS") качаются БЕЗ гейта настроек Auto download вовсе (см.
  TMsgScroller.MaybeAutoDownload, framehistory.pas) — файлы стикеров
  типично крошечные (единицы-десятки КБ у TGS/webp, редко больше у
  webm), сама суть стикера — мгновенный визуальный отклик, а не
  осознанное "хочу посмотреть", как у видео/файла. EnsureStickerFile/
  DownloadStickerDone/ApplyStickerFile — точная копия EnsureVideoFile/
  DownloadVideoDone/ApplyVideoFile по форме, своя карта FStickerByFile. }
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

procedure TTdMessages.TdUpdate(const AJson: utf8string; AData: TJSONObject);
var
  Obj: TJSONObject;
  T: utf8string;
  Id, OldId: Int64;
  R: TMsgRow;
  Arr: TJSONArray;
  I, Idx: integer;
begin
  { AData уже разобран приёмным потоком (tdrecv.pas) — раньше здесь
    была своя дешёвая Pos-отсечка перед своим же GetJSON; парсинг
    теперь один на всех подписчиков, отсечка не нужна. }
  if AData = nil then begin
    Exit;
  end;
  Obj := AData;
  T := JGetStr(Obj, '@type');

  { Апдейты сообщений идут потоком, десятками в секунду в активном
    чате — одна неожиданная форма JSON (ещё не встречавшийся тип
    контента и т.п.) не должна ронять/подвешивать всё приложение:
    TTdAccount.HandleUpdate вызывает TdUpdate каждого подписчика без
    своего try/except, исключение отсюда улетело бы наружу
    необработанным. }
  try
    if T = 'updateNewMessage' then begin
      ApplyMessage(JGetObj(Obj, 'message'));
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
      ApplyStickerFile(JGetObj(Obj, 'file'));
    end else if T = 'updateMessageEdited' then begin
      if JGetInt64(Obj, 'chat_id') = FChatId then begin
        R := Lookup(JGetInt64(Obj, 'message_id'));
        if R <> nil then begin
          R.EditDate := JGetInt64(Obj, 'edit_date');
          Touch;
        end;
      end;
    end else if T = 'updateMessageSendSucceeded' then begin
      { Заменяем временную запись новой целиком — проще и надёжнее,
        чем пытаться переиспользовать тот же объект под другим id. }
      OldId := JGetInt64(Obj, 'old_message_id');
      if OldId <> 0 then begin
        Idx := FAll.IndexOf(OldId);
        if Idx >= 0 then begin
          FAll.Data[Idx].Free;
          FAll.Delete(Idx);
        end;
      end;
      ApplyMessage(JGetObj(Obj, 'message'));
    end else if T = 'updateMessageSendFailed' then begin
      R := Lookup(JGetInt64(Obj, 'old_message_id'));
      if R <> nil then begin
        R.Delivery := mdsFailed;
        Touch;
      end;
    end else if T = 'updateDeleteMessages' then begin
      { from_cache:true — TDLib вытеснило сообщение из СВОЕГО кэша
        (обычно из-за того, что openChat для чата не был отправлен
        достаточно давно/своевременно), не удалило его на самом деле.
        FAll — наша собственная, уже загруженная копия; выкидывать её
        из-за постороннего кэша нечем оправдать — и раньше делали
        именно так, отчего часами открытый чат мог свестись к одному
        сообщению. Теперь openChat/closeChat зовутся из OpenChat, так
        что для АКТИВНОГО чата этого вообще быть не должно — но
        проверка остаётся: дешёвая и на будущее. }
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
  { На выходе/закрытии клиента история открытого чата теряет смысл —
    сам чат тоже, скорее всего, скоро сменится. Автозагрузку по
    tasReady, в отличие от TTdChats, не делаем: пока OpenChat не
    вызван явно (пользователь не открыл чат), грузить нечего. }
  if TdIsShuttingState(AState) then begin
    Clear;
    FChatId := 0;
  end;
end;

procedure TTdMessages.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Ошибки авторизации модели не касаются. }
end;

end.
