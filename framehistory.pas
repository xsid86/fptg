unit framehistory;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  { Windows — первым: юниты, идущие позже в uses, перекрывают его
    символы при неквалифицированном использовании (LCLIntf/LCLType
    объявляют часть одноимённых GDI-функций кросс-платформенно) — сам
    Windows нужен здесь только за CreateRoundRectRgn/SelectClipRgn/
    DeleteObject (TPhotoWidget.DrawBmpRounded, SMOOTH_CORNERS=False —
    у LCLIntf/LCLType их нет вовсе, проверено чтением исходников LCL,
    не угадано), все три вызываются квалифицированно (Windows.), но
    порядок в uses всё равно имеет значение для перегрузок. }
  Windows,
  Classes, SysUtils, Types, Math, DateUtils, LCLType, LCLIntf,
  Controls, constants, Forms, Graphics, Clipbrd, fgl, StdCtrls, ExtCtrls,
  Dialogs, Menus, ShellApi, BGRABitmap, BGRABitmapTypes, BGRAFilters, avatarcache,
  tdauth, tdcore, tdchats, tdmessages, tdusers, tdaccentcolors, msglayout,
  uiframe, framechats, audioplayer, videoplayer, photodecoder;

type
  { TAudioWidget

    UI-заглушка аудио-сообщения: подложка/контур тем же приёмом, что и
    у плашки цитаты ответа (AUDIO_COLOR вместо цвета отправителя),
    кнопка play/pause (ImageList1 у TFrameHistory, назначается через
    Images), название трека, полоса прогресса. Реального
    воспроизведения нет (только UI) — та часть, что реально требует
    декодирования (через ffmpeg), заедет отдельным заходом поверх этого
    же класса; пока прогресс всегда 0%, кнопка всегда в состоянии
    "play". Recycled-контрол: живёт в пуле TMsgScroller, Visible
    переключается, сам объект не пересоздаётся на каждый скролл — но
    данные ТРЕКА меняются при каждом переиспользовании под другое
    сообщение, см. SetTrack. }
  TAudioSeekEvent = procedure(Sender: TObject; AFraction: double) of object;

  TAudioWidget = class(TCustomControl)
  private
    FRowId: Int64;
    FTitle, FPerformer, FFileName: utf8string;
    FDuration: integer;
    FImages: TImageList;
    { Проигрывание — см. SetPlayback/TMsgScroller.AudioPlayClick.
      FIsActive=False — сообщение не то, что сейчас играет/на паузе
      (обычное состояние подавляющего большинства виджетов). }
    FIsActive:    boolean;
    FPlaying:     boolean;
    FPositionSec: double;
    { Перетаскивание ползунка — предпросмотр локальный (FDragFraction),
      сам факт перемотки (TMsgScroller.AudioSeek — новый TAudioPlayer с
      позиции) срабатывает один раз по отпусканию, не на каждый пиксель
      движения мыши: иначе пересоздавали бы поток декодирования/wave-
      устройство на каждый MouseMove, дорого и дёргано. }
    FDraggingSeek: boolean;
    FDragFraction: double;
    FOnPlayClick: TNotifyEvent;
    FOnSeek: TAudioSeekEvent;
    { Фон снаружи скруглённой подложки — см. WidgetBackdropColor и
      комментарий у TPhotoWidget.FBgColor, тот же приём. }
    FBgColor: TColor;
    function PlayButtonRect: TRect;
    { Общая геометрия контента (справа от кнопки play) — один источник
      правды для Paint И для хит-теста ползунка (TrackAreaRect/
      FractionFromX), чтобы не разъехались при правке. False, если
      места не хватает (см. Paint). }
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
    { Данные конкретного сообщения — вызывается из LayoutAudioWidgets
      при каждом переиспользовании виджета под (возможно) другое
      сообщение, не только при создании. Сбрасывает состояние
      проигрывания (виджет из пула мог до этого представлять активный
      трек) — актуальное состояние восстанавливает SetPlayback сразу
      следом, если новый ARowId и есть активный трек. }
    procedure SetTrack(ARowId: Int64; const ATitle, APerformer, AFileName: utf8string; ADuration: integer);
    procedure SetPlayback(AIsActive, APlaying: boolean; APositionSec: double);
    property Images: TImageList read FImages write FImages;
    property RowId: Int64 read FRowId;
    { Идёт перетаскивание ползунка ПРЯМО СЕЙЧАС — LayoutAudioWidgets
      должен пропустить SetPlayback на этот заход, иначе перезапишет
      локальный предпросмотр перетаскивания реальной (ещё старой)
      позицией на следующем же Paint. }
    property Dragging: boolean read FDraggingSeek;
    property OnPlayClick: TNotifyEvent read FOnPlayClick write FOnPlayClick;
    property OnSeek: TAudioSeekEvent read FOnSeek write FOnSeek;
    property BackgroundColor: TColor read FBgColor write FBgColor;
  end;

  TAudioMap = specialize TFPGMap<Int64, TAudioWidget>;

  { TFileWidget

    Виджет файла-документа — по прямому запросу пользователя, тот же
    внешний вид, что и у финальной реализации TAudioWidget (подложка/
    контур/скругление/отступы, одна и та же FILE_WIDGET_H=AUDIO_WIDGET_H),
    но без play/pause и полосы прогресса (у файла нет ни того, ни
    другого): слева — значок по расширению файла (FileIconIndex,
    FileTypes ImageList на TFrameHistory), справа — имя файла (там же,
    где у аудио заголовок трека) и его размер (там же, где у аудио
    время). Курсор — рука на всём виджете (не только над значком, как
    у play/pause кнопки audio), клик в любом месте — сохранить файл. }
  TFileWidget = class(TCustomControl)
  private
    FRowId: Int64;
    FFileName: utf8string;
    FFileSize: Int64;
    FIconIndex: integer;
    FDownloaded: boolean;
    FImages: TImageList;         { FileTypes — значки по расширению }
    FDownloadImages: TImageList; { ImageList1 — значок "скачать" (AUDIO_ICON_DOWNLOAD) }
    FOnClick: TNotifyEvent;
    { Фон снаружи скруглённой подложки — см. WidgetBackdropColor и
      комментарий у TPhotoWidget.FBgColor, тот же приём. }
    FBgColor: TColor;
    function IconRect: TRect;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    { ADownloaded — файл уже есть на диске (ARow.DocLocalPath<>'') —
      значок мим-типа; иначе значок "скачать" (AUDIO_ICON_DOWNLOAD). }
    procedure SetFile(ARowId: Int64; const AFileName: utf8string; AFileSize: Int64;
      ADownloaded: boolean);
    property Images: TImageList read FImages write FImages;
    property DownloadImages: TImageList read FDownloadImages write FDownloadImages;
    property RowId: Int64 read FRowId;
    { Левый клик: не скачан — качает молча (без диалога); скачан —
      открывает файл системным приложением по умолчанию (см.
      TMsgScroller.FileWidgetClick). Контекстное меню (правый клик) —
      не своё, общий компонент формы (см. TMsgScroller.FilePopupMenu),
      LCL показывает его сам через унаследованное свойство PopupMenu. }
    property OnFileClick: TNotifyEvent read FOnClick write FOnClick;
    property BackgroundColor: TColor read FBgColor write FBgColor;
  end;

  { Не TFileMap — то имя уже занято tdchats.TFileMap (file_id -> TChatRow,
    для аватарок), framehistory тянет tdchats в uses. }
  TFileWidgetMap = specialize TFPGMap<Int64, TFileWidget>;

  { TPhotoWidget

    Превью фото — по прямому запросу пользователя. В отличие от
    TAudioWidget/TFileWidget — БЕЗ подложки/контура-карточки (только
    само изображение, скруглённое PHOTO_CORNER_RADIUS): "рамки вокруг
    предпросмотра не нужно". Взаимодействие — тот же приём, что у
    TFileWidget: курсор-рука на весь виджет, левый клик качает
    (молча, если не скачано) либо открывает системным приложением
    (если уже скачано), контекстное меню — тот же общий FilePopupMenu.

    Пока файл не скачан — показываем блюр-плейсхолдер из
    content.photo.minithumbnail (крошечный JPEG, приходит сразу в
    контенте, без скачивания) поверх которого — значок "скачать"
    (тот же AUDIO_ICON_DOWNLOAD, что и у TFileWidget). Оба декодированных
    битмапа (блюр-превью и настоящее фото) кэшируются в самом виджете —
    тот recycled (пул TMsgScroller), пересчитываются только когда
    виджет реально переиспользован под ДРУГОЕ сообщение (см. SetPhoto),
    не на каждую перерисовку. }
  TPhotoWidget = class(TCustomControl)
  private
    FRowId: Int64;
    FNaturalW, FNaturalH: integer;
    FTargetW, FTargetH: integer;
    FLocalPath: utf8string;
    FDownloaded: boolean;
    FBlurBmp: TBGRABitmap;   { блюр-плейсхолдер из minithumbnail, до скачивания }
    FRealBmp: TBGRABitmap;   { настоящее фото, после скачивания }
    FDownloadImages: TImageList; { ImageList1 — значок "скачать" }
    { Цвет фона БЛОКА сообщения в этой точке (BlendWithBackground(
      SenderColor(R), SENDER_BG_OPACITY, clWindow) — та же формула, что
      красит сам блок в TMsgScroller.Paint) — НЕ голый clWindow: виджет,
      как и TAudioWidget/TFileWidget, реальный дочерний control и не
      просвечивает canvas родителя, а у фото (в отличие от аудио/файла)
      нет своей непрозрачной карточки-подложки поверх этого фона — без
      подмены угол превью снаружи скруглённой маски показывал бы белый
      clWindow, заметно отличающийся от подкрашенного фона блока
      ("белые треугольники по углам"). }
    FBgColor: TColor;
    FOnClick: TNotifyEvent;
    { Декод настоящего (не блюр-плейсхолдера) фото — в фоновом потоке,
      см. photodecoder.pas и комментарий у DecodeDone/SetPhoto.
      FDecodeThread <> nil — декод для ЭТОГО виджета сейчас идёт;
      старый декод, ставший неактуальным (виджет переиспользован под
      другое сообщение/путь, или сам виджет уничтожается), ВСЕГДА
      явно отменяется через Cancel ДО того, как заведут новый/
      уничтожат виджет — тогда DoDone для него просто освободит
      результат сам, ни разу не тронув поля этого объекта, и отдельная
      проверка "для какого пути был этот декод" не нужна. }
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
    { AMinithumb — сырые (уже base64-декодированные) байты JPEG, может
      быть '' (не пришёл/уже не нужен — скачано). ADownloaded/ALocalPath
      — есть ли уже настоящий файл на диске. AMaxW — реальная доступная
      ширина колонки в этом месте (см. ComputePhotoPreviewSize) — без
      неё превью могло вылезти за карточку сообщения на нешироких
      окнах. }
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

    "Гифка" (messageAnimation — физически короткое MP4/H.264 без звука)
    — тот же интерфейс, что у TPhotoWidget: курсор-рука на весь виджет,
    скругление PHOTO_CORNER_RADIUS, БЕЗ подложки/контура-карточки. Пока
    не скачано — блюр-плейсхолдер из content.animation.minithumbnail
    (тот же пайплайн декодирования, что у фото), поверх — значок
    "скачать".

    Клики — по прямому запросу пользователя, как у файла: первый клик
    по недокачанному — только скачивание, БЕЗ автопоказа; второй клик
    по уже скачанному, ещё не играющему — запускает зацикленное
    воспроизведение. Клик по УЖЕ играющему — ничего не делает: никаких
    контролов запуска/остановки, "гифка" либо не играет, либо крутится
    в цикле, пока виджет жив и виден (framehistory.pas это решает через
    OnAnimClick/StartLoop/StopLoop).

    Живое воспроизведение — TAnimationPlayer (videoplayer.pas), фоновый
    поток-декодер, зацикленный сам по себе. У КАЖДОГО виджета — свой
    независимый поток и свой TTimer-опрос нового кадра (PollTick), НЕ
    общий с TMsgScroller.FPlaybackTimer (тот — про позицию ОДНОГО
    активного аудио-плеера; "гифок" на экране одновременно может
    крутиться сколько угодно, никакого "только один разом" ограничения
    для видео нет).

    Скругление — ВСЕГДА через дешёвый GDI-регион (CreateRoundRectRgn/
    SelectClipRgn, тот же приём, что у TPhotoWidget при
    SMOOTH_CORNERS=False), НЕЗАВИСИМО от глобального SMOOTH_CORNERS —
    сознательное отличие от остальных 13 мест в файле: живой кадр видео
    обновляется десятки раз в секунду на КАЖДУЮ одновременно играющую
    "гифку", пересчитывать BGRA-маску (ApplyMask/RoundRectAntialias) на
    каждый такой кадр — совсем другой порядок затрат CPU, чем та же
    операция на статичном фото (там перерисовка не идёт непрерывным
    потоком). Использовать РАЗНЫЕ способы скругления для плейсхолдера
    и живого кадра ОДНОГО И ТОГО ЖЕ виджета тоже нежелательно — граница
    заметно "мигнула" бы в момент старта воспроизведения — поэтому оба
    состояния виджета красятся одним и тем же дешёвым способом. }
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
    FFrameBuf: PByte;           { BGRA, FTargetW*FTargetH*4 байт }
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
    { Та же сигнатура/роль, что у TPhotoWidget.SetPhoto — AMinithumb
      может быть '' (не пришёл/уже не нужен), ADownloaded/ALocalPath —
      есть ли уже настоящий файл на диске, AMaxW — реальная доступная
      ширина колонки (см. ComputePhotoPreviewSize). НЕ запускает
      воспроизведение сама — только готовит плейсхолдер/состояние
      "скачано"; старт — отдельно, StartLoop (framehistory.pas решает,
      когда: второй клик или авто-воспроизведение по настройкам). }
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

  { Ключ — id пользователя или чата-источника репоста (см. поле у
    TMsgScroller, где заведены два разных инстанса этого типа). }
  TForwardAvatarMap = specialize TFPGMap<Int64, TBGRABitmap>;

  { Что сделать с файлом-документом, как только он скачается — "Save
    as..."/"Show in folder" в контекстном меню на ещё не скачанном
    файле сначала запускают загрузку (FPendingSaveMsgId), действие
    выполняется отложенно, см. TMsgScroller.ModelChanged. У клика по
    превью фото — своя, ПРЯМАЯ (без отложенного действия) логика
    "первый клик качает, второй открывает" (см. PhotoWidgetClick), этот
    enum её не касается. }
  TPendingFileAction = (pfaNone, pfaSaveDialog, pfaShowInFolder);

  { TMsgScroller

    Сердце фрейма переписки: сам виртуально скроллит (позиция —
    FScrollTop, диапазон синхронизируется с нативным TScrollBar в
    TFrameHistory через OnScrollRangeChanged/OnScroll — своей
    прорисовки скроллбара тут больше нет), сам раскладывает и красит
    видимые сообщения через msglayout.RendererFor, сам считает
    попадание мыши (ссылки, выделение текста), сам держит пул
    TAudioWidget. Высоты сообщений кэшируются на TMsgRow.LayoutCache —
    пересчитывается только то, что реально изменилось (см. RebuildOffsets). }
  TMsgScroller = class(TCustomControl)
  private
    FModel:   TTdMessages;
    FOffsets: array of integer;   { длина Count+1, накопленная высота }
    { id сообщения на каждой позиции FOffsets — снимок ТОГО ЖЕ момента,
      что и сам FOffsets (заполняется в том же цикле RebuildOffsets).
      Нужен ModelChanged: к моменту его вызова FModel уже отражает
      НОВОЕ состояние (TTdMessages.Rebuild отработал до FOnChanged), а
      FOffsets — ещё СТАРОЕ. Если якорь верхней видимой строки читать
      через FModel[индекс из старых FOffsets], после LoadOlder (который
      добавляет сообщения В НАЧАЛО, сдвигая индексы всех остальных)
      получится id случайного другого сообщения — отсюда и "вставляются
      вразнобой". FRowIds всегда того же винтажа, что и FOffsets,
      поэтому такого смешения нет. }
    FRowIds:  array of Int64;
    FTotalHeight: integer;
    FScrollTop:   integer;

    FSelAnchorMsg, FSelFocusMsg:   Int64;
    FSelAnchorChar, FSelFocusChar: integer;
    FSelecting: boolean;

    FAudioPool:   TFPList;   { of TAudioWidget, все когда-либо созданные }
    FAudioActive: TAudioMap; { сейчас позиционированные, по id сообщения }
    { Кнопки play/pause для TAudioWidget — назначается TFrameHistory
      сразу после создания FScroller (см. её конструктор), свой список
      на форме (не framechats.ImageList1 — те 16x16, эти 32x32). }
    FAudioImages: TImageList;

    { Виджет файла-документа — тот же пул-приём, что у аудио. }
    FFilePool:   TFPList;       { of TFileWidget }
    FFileActive: TFileWidgetMap;
    FFileImages: TImageList;    { FileTypes на TFrameHistory }
    { Общее контекстное меню файла (правый клик) — компонент формы
      (TFrameHistory.FilePopupMenu, в LFM, редактируется пользователем
      в дизайнере), не создаётся здесь: каждый TFileWidget получает на
      него ссылку через свойство PopupMenu (LCL сам показывает его по
      правому клику и выставляет PopupComponent на нажатый виджет —
      обработчики пунктов меню читают его оттуда, см.
      TFrameHistory.MenuItemFileSaveAsClick/MenuItemFileShowInFolderClick). }
    FFilePopupMenu: TPopupMenu;
    { Клик по ещё не скачанному файлу в контекстном меню ("Save as..."/
      "Show in folder") — EnsureDocFile только запрашивает загрузку;
      когда путь придёт (ModelChanged/Touch), нужное действие
      выполняется само (FPendingFileAction решает, какое) — тот же
      приём, что FPendingPlayMsgId у аудио. }
    FPendingSaveMsgId: Int64;
    FPendingFileAction: TPendingFileAction;

    { Превью фото — тот же пул-приём, что у аудио/файла; общий
      FilePopupMenu/FAudioImages переиспользуются, свой список
      значков-по-типу не нужен (нет "типа" — только само фото). }
    FPhotoPool:   TFPList;       { of TPhotoWidget }
    FPhotoActive: TPhotoWidgetMap;
    { Тот же приём, что FPendingSaveMsgId у файла — своя пара полей,
      не общая: разные Kind, разные Local-поля у TMsgRow. }
    FPendingPhotoMsgId: Int64;
    FPendingPhotoAction: TPendingFileAction;

    { "Гифки" (messageAnimation) — тот же recycled-пул, что у фото/
      аудио/файла. Воспроизведение — НЕ здесь (в отличие от аудио, у
      которого один активный плеер на весь скроллер): у каждого
      TAnimationWidget свой независимый TAnimationPlayer, "гифок"
      одновременно может крутиться сколько угодно — состояние
      проигрывания живёт в самом виджете (см. TAnimationWidget.FPlayer),
      скроллеру достаточно пула позиционирования. }
    FAnimPool:   TFPList;       { of TAnimationWidget }
    FAnimActive: TAnimationWidgetMap;

    { Проигрывание аудио — один активный плеер на весь скроллер (как и
      в самом Telegram, играет не более одного трека разом). Виджет —
      recycled-пул (см. FAudioActive/FAudioPool выше), состояние
      проигрывания живёт ЗДЕСЬ, не в виджете: тот может уйти с экрана
      при скролле, пока сообщение продолжает играть.
      FDonePlayer — плеер, чей поток уже завершается/завершился
      (TAudioPlayer.State перешёл в apsStopped/apsError через
      PlayerStateChanged, вызванный самим потоком через Synchronize) —
      освобождать TThread ИЗНУТРИ его же Synchronize-колбэка нельзя
      (Free внутри может ждать завершения потока — тот самый поток,
      что сейчас заблокирован в Synchronize, ожидая нас — взаимная
      блокировка); PlaybackTick освобождает его безопасно, из другого
      контекста (обычный вызов по таймеру, не изнутри Synchronize). }
    FActivePlayer:      TAudioPlayer;
    FActivePlayerMsgId: Int64;
    FDonePlayer:        TAudioPlayer;
    { Клик по play, когда файл ещё не скачан — EnsureAudioFile только
      запрашивает загрузку; когда путь придёт (ModelChanged/Touch),
      если он всё ещё нужен (пользователь мог передумать/кликнуть по
      другому треку), проигрывание запускается автоматически. }
    FPendingPlayMsgId:  Int64;
    FPlaybackTimer:     TTimer;

    { Аватарки источников репоста — маленькие (диаметр HEADER_H),
      свой кэш, а не avatarcache.TAvatarCache: тот заточен под
      AVATAR_SIZE=44 и TChatRow (список чатов), здесь же нужны и чаты
      (mfoChat/mfoChannel — по ForwardChatId), и пользователи (mfoUser —
      по ForwardUserId, для которых в проекте вообще нет скачанных фото,
      только TChatRow их имеет). Раздельные карты — id пользователя и
      id чата не одно и то же пространство, а совпадение по значению
      возможно. Ключ — Id источника; значение освобождается в Destroy. }
    FForwardChatAvatars: TForwardAvatarMap;
    FForwardUserAvatars: TForwardAvatarMap;

    FOnScrollRangeChanged: TNotifyEvent;
    FOnNearTop: TNotifyEvent;

    { Кэш "тип текущего чата -> ключ AUTODL_CHAT_KINDS" (см.
      CurrentChatKind) — вычисляется лениво и только заново при смене
      чата (FChatKindChatId <> FModel.ChatId), не на каждый вызов: тот
      вызывается из ClampScrollTop, самого частого места в файле (колесо
      мыши/драг скроллбара), TdChatList.Lookup+case там был бы не
      бесплатным. FChatKindChatId=0 — ещё не считали (0 не бывает
      настоящим chat_id). }
    FChatKindChatId: Int64;
    FChatKindCache:  string;
    function CurrentChatKind: string;
    { Автозагрузка (FormMain.AutoDownloadEnabled) — если включена для
      пары (тип медиа этого сообщения, тип текущего чата), запрашивает
      файл ЗАРАНЕЕ (Ensure*File), тем же вызовом, что и первый клик по
      виджету сейчас, но без открытия/проигрывания — только загрузка,
      по прямому запросу пользователя. Idempotent (как и сами Ensure*),
      можно звать сколько угодно раз на одну и ту же строку. }
    procedure MaybeAutoDownload(ARow: TMsgRow);
    { Однократно, на весь диапазон [FirstVisible..LastVisible] — вызывается
      из ModelChanged (открытие чата, новые сообщения, догрузка истории). }
    procedure AutoDownloadVisible;
    { На каждое РЕАЛЬНОЕ изменение позиции скролла (см. ClampScrollTop) —
      с упреждением на AUTODL_PREFETCH_MESSAGES сообщений в сторону
      скролла (ADirection>0 — вниз/к новым, <0 — вверх/к старым), чтобы
      к моменту, когда сообщение реально появится на экране, загрузка
      уже давно шла или уже завершилась. Было ровно ОДНО сообщение
      вперёд — по прямому запросу пользователя расширено до целого окна
      ("загружать изображения сильно заранее", жалоба на подтормаживание
      прокрутки: сеть — не единственная причина задержки, см. её же
      запрос про декод в отдельном потоке, DecodeDone/photodecoder.pas
      — но и сама сеть, когда файл ещё даже не запрошен к моменту
      появления строки на экране, вносит свою задержку, окно шире её
      устраняет тоже). }
    procedure PrefetchAutoDownload(ADirection: integer);

    procedure AudioPlayClick(Sender: TObject);
    procedure AudioSeek(Sender: TObject; AFraction: double);
    procedure PlayerStateChanged(Sender: TObject);
    procedure PlaybackTick(Sender: TObject);
    procedure FlushDonePlayer;
    procedure StopActivePlayer;
    procedure StartPlayback(ARow: TMsgRow; AStartPositionSec: double = 0);

    procedure RebuildOffsets;
    { Левая/правая граница центрированной колонки сообщений — не шире
      MAX_MSG_W. Один источник правды для RebuildOffsets (ширина
      переноса текста), BlockRect и ContentRect — иначе разъедутся при
      малейшей правке одного из них. }
    procedure ColumnBounds(out ALeft, ARight: integer);
    { Единый расчёт для строки с репостом — сколько места до и после
      контента занимает цитата (шапка+паддинги источника, БЕЗ высоты
      самого контента) и какая ширина остаётся контенту внутри неё.
      ARow=nil или не репост — APreH/APostH такие же, как и без цитаты
      (см. реализацию), AInnerW=AAvailW без изменений. Источник истины
      и для RebuildOffsets (высота строки), и для ContentRect/
      ForwardCardRect/ForwardHeaderRect (где рисовать) — как ColumnBounds. }
    { Обычный вертикальный отступ контента от заголовка/от нижнего края —
      MSG_PAD_V, кроме аудио: у него оба этих отступа совпадают с его же
      собственным внутренним отступом (MSG_PAD_H). Один источник правды
      для ForwardMetrics И ForwardCardRect — раньше ForwardCardRect не
      знал про этот особый случай и всегда прибавлял MSG_PAD_V, отчего
      нижний отступ аудио-виджета внутри карточки репоста был у́же
      остальных трёх сторон (6px вместо 11px). }
    function ContentPadV(ARow: TMsgRow): integer;
    procedure ForwardMetrics(ARow: TMsgRow; AColW: integer;
      out APreH, APostH, AInnerW: integer);
    { Рамка цитаты целиком (для заливки/обводки) и её собственная строка
      "аватар+имя+время" (для отрисовки и хит-теста клика по имени). }
    function ForwardCardRect(AIndex: integer): TRect;
    function ForwardHeaderRect(AIndex: integer): TRect;
    { Высота плашки цитаты ответа (reply_to) + отступ до того, что
      после неё — 0, если у сообщения нет reply_to. Складывается с
      PreH из ForwardMetrics (ортогональные свойства, см. реализацию). }
    function ReplyExtraH(ARow: TMsgRow): integer;
    function ReplyBoxRect(AIndex: integer): TRect;
    procedure PaintReplyBox(AIndex: integer; ARow: TMsgRow);
    { AOwned=True — вызывающий обязан сам освободить результат (снимок
      "пока не скачано", не кэшируется, см. реализацию); False —
      результат в кэше, освобождать нельзя. }
    function ForwardAvatarBmp(ARow: TMsgRow; out AOwned: boolean): TBGRABitmap;
    procedure ClearForwardAvatars;
    procedure PaintForwardCard(AIndex: integer; ARow: TMsgRow);
    function IndexAtY(AY: integer): integer;
    function FirstVisible: integer;
    function LastVisible: integer;
    function BlockRect(AIndex: integer): TRect;
    function ContentRect(AIndex: integer): TRect;
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
    function HitTestAt(X, Y: integer; out AIndex: integer): TMsgHit;
    function ResolveSelection(out ALowIdx, AHighIdx, ALowChar, AHighChar: integer): boolean;
    procedure RangeForRow(AIndex, ALowIdx, AHighIdx, ALowChar, AHighChar,
      ATextLen: integer; out ASelStart, ASelEnd: integer);
    procedure ClampScrollTop(AValue: integer);
    procedure SetScrollTop(AValue: integer);
    procedure DoLinkClick(const AUrl: utf8string);
    { Клик по источнику цитаты репоста (только mfoChannel — см. вызов) —
      не строим шэрабельную ссылку (getMessageLink требует членства в
      чате, для чужого источника обычно не наш случай), а переходим,
      как в официальном клиенте: открываем чат-источник и
      прокручиваем к сообщению. }
    procedure OpenForwardSource(ARow: TMsgRow);
    { Прокрутить и показать конкретное сообщение — вызывается из
      TFrameHistory в ответ на TTdMessages.OnJumpReady, когда нужная
      пачка истории уже применена и FOffsets/FRowIds её видят. }
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
    { AModel = nil отвязывает (смена аккаунта на пустой список). }
    procedure BindModel(AModel: TTdMessages);
    { Модель прислала OnChanged: пересчитать оффсеты, удержать якорь
      прокрутки (см. реализацию — без прыжка при подгрузке вверх). }
    procedure ModelChanged;
    procedure ScrollToBottom;
    property ScrollTop: integer read FScrollTop write SetScrollTop;
    property TotalHeight: integer read FTotalHeight;
    property OnScrollRangeChanged: TNotifyEvent read FOnScrollRangeChanged write FOnScrollRangeChanged;
    property OnNearTop: TNotifyEvent read FOnNearTop write FOnNearTop;
    property AudioImages: TImageList read FAudioImages write FAudioImages;
    property FileImages: TImageList read FFileImages write FFileImages;
    property FilePopupMenu: TPopupMenu read FFilePopupMenu write FFilePopupMenu;
    { Обработчики пунктов TFrameHistory.FilePopupMenu — вызываются
      оттуда (LFM резолвит OnClick только на методы владельца-формы,
      не динамически создаваемого TMsgScroller), Sender — сам
      TFileWidget, добытый через PopupMenu.PopupComponent. }
    procedure FileWidgetSaveAsClick(Sender: TObject);
    procedure FileWidgetShowInFolderClick(Sender: TObject);
    { Те же два — для TPhotoWidget, тот же общий FilePopupMenu. }
    procedure PhotoWidgetSaveAsClick(Sender: TObject);
    procedure PhotoWidgetShowInFolderClick(Sender: TObject);
  end;

  { TFrameHistory

    Экран переписки. Открывается через OpenChat(chatId) — вызывающая
    сторона (main.pas, клик по чату) сама решает, когда его показать
    через навигатор. }
  TFrameHistory = class(TFrameBase, ITdActiveListener)
    ImageList1: TImageList;
    FileTypes: TImageList;
    Actions16: TImageList;
    FilePopupMenu: TPopupMenu;
    MenuItemFileSaveAs: TMenuItem;
    MenuItemFileShowInFolder: TMenuItem;
    { Пункты FilePopupMenu (LFM, редактируется в дизайнере) — LFM
      резолвит OnClick только на методы владельца-формы, поэтому сами
      обработчики здесь, а не на TMsgScroller (тот создаётся в коде, не
      компонент формы); дальше просто передают вызов в FScroller,
      беря исходный TFileWidget из PopupMenu.PopupComponent — тот же
      компонент показан по правому клику именно на этом виджете. }
    procedure MenuItemFileSaveAsClick(Sender: TObject);
    procedure MenuItemFileShowInFolderClick(Sender: TObject);
  private
    FReady: boolean;
    FModel: TTdMessages;
    { Кэш имён — не "модель этого фрейма" в том же смысле, что FModel
      (история одного открытого чата): один на аккаунт, переживает
      смену чата, поэтому у него собственная лёгкая привязка внутри
      BindModel/UnbindModel, а не полноценный Bind/Unbind как у FModel. }
    FUsers: TTdUsers;
    { Тот же принцип, что у FUsers — один на аккаунт, лёгкая привязка,
      без офсетов. }
    FAccentColors: TTdAccentColors;
    FScroller:  TMsgScroller;
    FScrollbar: TScrollBar;
    pnlStatus:  TPanel;
    lblStatus:  TLabel;
    procedure BindModel;
    procedure UnbindModel;
    procedure ModelChanged(Sender: TObject);
    procedure LoadingChanged(Sender: TObject);
    { Кэшу имён/аватарке отправителя пришёл ответ на getUser — просто
      перерисовать: высота блока не меняется от того, что имя
      дорезолвилось, полная пересборка офсетов не нужна. }
    procedure UsersChanged(Sender: TObject);
    procedure ActionError(Sender: TObject; ACode: integer;
      const AMessage, AAction: utf8string);
    { Нужная вокруг AMessageId пачка истории применена (TTdMessages.
      JumpTo/JumpDone) — переход по цитате репоста: прокрутить к ней. }
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

    { AJumpToMessageId <> 0 — переход по цитате репоста, см.
      TTdMessages.OpenChat/JumpTo. }
    procedure OpenChat(AChatId: Int64; AJumpToMessageId: Int64 = 0);

    { ITdActiveListener }
    procedure TdActiveChanged(ANew: TTdAccount);
    procedure TdAccountsChanged;
  end;

implementation

{ main в реализации, а не в интерфейсе: main сам использует
  framehistory (навигатор рабочей области), и в интерфейсе это дало бы
  цикл — тот же приём, что у main/login (см. main.pas). Нужен только
  ради FormMain.Chats.ImageList1 (значки статуса сообщения, §3 плана). }
uses
  main;

{$R *.lfm}

{ Цвет по кругу, детерминированно по id — общий резолвер для отправителя
  сообщения (SenderColor), источника репоста (ForwardSourceColor) и
  цитируемого в reply_to (ReplySenderColor): три структурно одинаковых
  случая "раскрасить кого-то по id", вынесены в одно место. Ровно один
  из AUserId/AChatId должен быть ненулевым (как и везде в проекте —
  отправитель это либо пользователь, либо чат, не оба разом); оба
  нулевые (напр. mfoHiddenUser) — берём Id=1, лишь бы не всегда одна и
  та же ячейка палитры. AChatId у каналов/супергрупп бывает
  отрицательным (см. tdlib_raw.log) — Abs, чтобы не уйти за границу
  массива. }
function ResolveAccentColor(AUserId, AChatId: Int64): TColor;
var
  Id: Int64;
  AccId: integer;
  C: TChatRow;
  L: TTdChats;
  AC: TTdAccentColors;
begin
  { У Telegram уже есть свой закреплённый за контактом/чатом цвет
    (accent_color_id, из updateUser/updateChatAccentColors — см.
    tdaccentcolors.pas) — используем его вместо хэша по id, когда он
    известен. Хэш по SENDER_PALETTE остаётся запасным вариантом: пока
    accent_color_id ещё не резолвился (первая прорисовка нового
    отправителя) или для совсем неожиданного случая, когда ни один
    источник его не даёт. }
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

{ Смешивает AColor с ABackground в пропорции AOpacity (0..1) —
  подложка блока сообщения, "цвет отправителя приглушённо поверх фона",
  без настоящей альфа-композиции (BGRABitmap) — она была бы избыточна
  для сплошной заливки прямоугольника, а Paint дёргается на каждый
  скролл. ColorToRGB разворачивает системные цвета (напр. clWindow)
  в реальные RGB — без этого блендинг псевдо-цвета дал бы мусор. }
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

{ Единая антиалиасинговая замена GDI Canvas.RoundRect для ЛЮБОЙ
  скруглённой заливки/обводки в этом файле (блок сообщения, карточка
  репоста, плашка цитаты ответа, аудио/файл-виджет). Рисует во
  временный прозрачный BGRA-битмап размером ровно с ABox и композитит
  его на ACanvas с альфа-блендингом (Draw ... False) — то, что снаружи
  скругления, остаётся тем, что уже было на canvas, ничего лишнего не
  перекрывает.

  AFillColor/ABorderColor = clNone — соответствующий проход пропускается
  (только заливка, только обводка, или разом, если оба заданы). Радиус
  (ARadius) — ПРИНИМАЕТСЯ КАК ЕСТЬ, ни один вызывающий не поменял ни
  одного числа при переходе на эту функцию, только сам способ рисовать
  скругление.

  Три захода на TPhotoWidget.DrawBmpRounded (белый зазор в углу →
  обрезанная обводка → мутная обводка, все три — см. CLAUDE.md)
  свелись к одному факту: FillRoundRectAntialias/RoundRectAntialias
  по умолчанию (APixelCenteredCoordinates=True, подтверждено чтением
  исходника BGRABitmap, не угадано) считают целую координату N ЦЕНТРОМ
  пикселя N, не границей между пикселями N-1 и N, как в GDI. Отсюда две
  поправки ниже, сразу верные, без повторения того же пути проб:
  -0.5 у заливки (её край должен пройти ровно между "пиксель ещё есть"
  и "пикселя уже нет") и AWidth-ABorderWidth/2-0.5 у дальнего края
  обводки (сама линия centered на своём пути, толщиной ABorderWidth —
  весь её след обязан остаться внутри битмапа). }
procedure PaintRoundRectAA(ACanvas: TCanvas; const ABox: TRect; ARadius: single;
  AOptions: TRoundRectangleOptions; AFillColor, ABorderColor: TColor;
  ABorderWidth: single = 1);
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

  if not SMOOTH_CORNERS then begin
    { Старый метод, ДО перехода на BGRA (см. CLAUDE.md) — обычный GDI
      Canvas.RoundRect, без единого TBGRABitmap. Заведено по прямому
      запросу пользователя — тест, действительно ли сама антиалиасинговая
      отрисовка (аллокация+заливка временного битмапа на каждый вызов,
      их тут 12 на кадр в худшем случае) заметна на плавности скролла,
      не только субъективно "выглядит более гладко".
      GDI RoundRect не умеет per-corner — единственный набор AOptions,
      реально встречающийся в этом файле, [rrBottomLeftSquare,
      rrBottomRightSquare] (спрямить низ у мини-заголовка), и оба места,
      что его просят, всегда без обводки (ABorderColor=clNone) — тем же
      старым трюком "нарисовать все 4 скруглёнными, потом спрямить низ
      отдельным FillRect", что и был в проекте до перехода на BGRA.
      Другие сочетания AOptions в файле не встречаются — не обобщаем
      сверх того, что реально нужно. }
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
    if (AFillColor <> clNone) and (rrBottomLeftSquare in AOptions) and
      (rrBottomRightSquare in AOptions) then begin
      ACanvas.Pen.Style := psClear;
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Brush.Color := AFillColor;
      ACanvas.FillRect(Rect(ABox.Left, ABox.Bottom - IRadius, ABox.Right, ABox.Bottom));
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

{ Обрезает S по ширине AMaxW (пикселей, шрифтом уже выставленным на
  ACanvas) с "…" на конце — используется и цитатой ответа, и аудио-
  виджетом, оба однострочные, без word-wrap. }
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

{ ЧЧ:ММ:СС, "-" спереди для отрицательных (оставшееся время трека). }
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

{ Имя по id — общий резолвер, тем же приёмом, что и ResolveAccentColor
  (отправитель сообщения / источник репоста / цитируемый в reply_to).
  AChatId (анонимный админ/пост от имени канала) резолвится через уже
  загруженный список чатов, не через TTdUsers — это не пользователь. }
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

{ Индекс кадра в ImageList1 (framechats.pas) под значок статуса
  исходящего сообщения; -1 — не рисовать (crNone, входящее). }
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

{ Отображаемое имя источника репоста. mfoChannel/mfoChat резолвятся
  через уже загруженный список чатов (ForwardChatId) — тот же приём,
  что и SenderDisplayName для анонимных постов от чата. mfoUser — через
  кэш пользователей. mfoHiddenUser — TDLib присылает готовое имя и
  больше ничего (отправитель сам скрыл, откуда переслано). }
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

{ Цвет источника репоста — тот же приём, что и SenderColor (настоящий
  accent_color_id, хэш по SENDER_PALETTE запасным вариантом), но по
  ForwardUserId/ForwardChatId, а не по отправителю самого сообщения:
  это два разных, независимо раскрашенных участка одного блока — кто
  прислал репост (внешний заголовок) и откуда он изначально (цитата). }
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
    { mfoHiddenUser (и любой другой случай без числового id) — стабильный,
      но произвольный запасной цвет: важно не 0, иначе всегда одна и та
      же ячейка палитры для всех подряд. }
    Id := 1;
  end;
  Result := SENDER_PALETTE[Abs(Id) mod Length(SENDER_PALETTE)];
end;

{ Цвет фона ПОД скруглённым виджетом (аудио/файл/фото) в этой точке —
  для их собственного BackgroundColor: реальные дочерние control'ы не
  просвечивают canvas родителя (см. комментарий у TPhotoWidget), и без
  подмены их угла СНАРУЖИ скруглённой заливки/маски показывали бы
  clWindow (белый) — заметно отличается от того, что там на самом деле
  нарисовано.

  Раньше формула (BlendWithBackground(SenderColor(R), SENDER_BG_OPACITY,
  clWindow)) была только у TPhotoWidget и всегда брала цвет ВНЕШНЕГО
  блока — верно для фото не внутри репоста, но ВНУТРИ репоста виджет
  сидит на подложке карточки цитаты (свой, независимый цвет —
  ForwardSourceColor, не SenderColor), не самого блока — не учитывалось
  нигде, включая LayoutPhotoWidgets: угол виджета внутри репоста был
  подкрашен цветом блока, а не цветом карточки, в которой он реально
  лежит. Пойман на аудио-виджете (белые углы внутри цветной карточки
  репоста, см. CLAUDE.md) — тот же класс, что и "белые треугольники" у
  фото, но TAudioWidget/TFileWidget вообще не имели BackgroundColor:
  предполагалось, что их собственная непрозрачная карточка покрывает
  всё до края — ошибочно, скруглённая карточка «до края» не доходит по
  определению, у неё как раз скруглённые (не залитые) углы. }
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
  FBgColor := clWindow;   { запасной вариант до первого LayoutAudioWidgets }
end;

procedure TAudioWidget.SetTrack(ARowId: Int64; const ATitle, APerformer, AFileName: utf8string; ADuration: integer);
begin
  if ARowId <> FRowId then begin
    { Виджет из пула переиспользован под ДРУГОЕ сообщение — старое
      состояние проигрывания/перетаскивания относится не к этому
      треку, обнуляем. Если ARowId тот же (обычный повторный проход
      LayoutAudioWidgets — вызывается на КАЖДЫЙ Paint скроллера, в том
      числе каждый тик таймера прогресса) — состояние НЕ трогаем: раньше
      именно это и рвало перетаскивание ползунка и клик по полосе —
      следующий же Paint (буквально через доли секунды) отбрасывал
      FDraggingSeek/позицию обратно к нулю прямо под курсором. }
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
  { Хит-зона выше и ниже визуальной полосы/ползунка — тем удобнее в
    неё попасть мышью, сам ползунок всего AUDIO_THUMB_H пикселей. }
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
  { Перемотка — только у активного (проигрывается/на паузе) трека:
    у остальных ползунок всегда в начале, тащить там нечего. }
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

  { TAudioWidget — настоящий дочерний control, не рисуется "сквозь"
    canvas родителя, как цитаты/карточки репоста — вне скруглённых
    углов нужен сплошной фон, FBgColor (WidgetBackdropColor,
    LayoutAudioWidgets) — реальный цвет блока/карточки репоста под
    виджетом в этой точке, не голый clWindow: тот был виден белыми
    углами по краям скруглённой подложки, особенно заметно внутри
    цветной карточки репоста — пойман пользователем по скриншоту. }
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(Box);

  { Подложка — тем же приёмом, что и у плашки цитаты ответа/карточки
    репоста (SENDER_BG_OPACITY), но своим цветом (AUDIO_COLOR), не
    завязанным на отправителя — один и тот же для любого аудио. }
  PaintRoundRectAA(Canvas, Box, Radius, [],
    BlendWithBackground(AUDIO_COLOR, SENDER_BG_OPACITY, clWindow), clNone);

  { Кнопка play/pause — левый край, по вертикали центрирована. }
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

  { Название — исполнитель и трек через дефис; то, что есть из двух,
    если не хватает второго; имя файла, если метаданных нет вовсе. }
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

  { Полоса прогресса — реальная позиция, только пока ЭТО сообщение
    активно (проигрывается/на паузе); иначе, как и раньше, 0%. }
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

  { Время — слева от начала трека, справа до конца (отрицательное).
    Brush.Style сброшен обратно в bsClear явно — FillRect выше (трек/
    ползунок) на этом виджет-сете переключает его в bsSolid как побочный
    эффект заливки, иначе текст рисовался бы с непрозрачным фоном. }
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

  { Контур — последним, поверх содержимого, тем же приёмом, что и у
    прочих карточек (SENDER_BORDER_OPACITY). }
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
  { Расширение -> индекс кадра в FileTypes (TFrameHistory). Не считано
    со скриншотов на глаз — сгенерировано из реального списка файлов в
    res/file_types/ (тот самый каталог, откуда пользователь массово
    импортировал кадры в ImageList редактором Lazarus): отсортированные
    по имени file_extension_<ext>.png дают ТОЧНО тот же порядок, что и
    кадры 1..98 (кадр 0 — page_white.png, общая заглушка, добавлена до
    массового импорта). Poka строится один раз командой в оболочке
    (ls | sed | awk), не вручную — почти по определению без ошибок
    транскрипции, в отличие от более ранней версии этой таблицы,
    считанной со скриншотов (там едва не потерялись MSWMM и TORRENT —
    оба между соседними по алфавиту расширениями, глазом за них легко
    проскочить). Каждая запись — независимая пара (индекс, расширение),
    не позиция в массиве, на случай будущей ручной правки одной строки. }
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

{ "Show in folder" — открывает Проводник с уже выделенным файлом.
  Только Windows (explorer.exe /select) — тот же класс правки, что и
  audiodevices.pas/winmm для вывода звука: платформенный шим, декод/
  модель остаются общими, меняется только это тонкое место при
  будущем переносе на другую ОС. }
procedure ShowDocInFolder(const APath: utf8string);
begin
  if APath = '' then begin
    Exit;
  end;
  { SW_SHOWNORMAL = 1 — общеизвестное значение Win32, не тянуть Windows
    юнит целиком ради одной константы. }
  ShellExecute(0, 'open', 'explorer.exe',
    PChar('/select,"' + string(APath) + '"'), nil, 1);
end;

constructor TFileWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  Cursor := crHandPoint;   { весь виджет кликабелен, не только значок }
  FBgColor := clWindow;   { запасной вариант до первого LayoutFileWidgets }
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

  { Тот же приём, что у TAudioWidget — настоящий дочерний control, не
    просвечивает canvas родителя, поэтому сплошной фон вне скруглённых
    углов обязателен — FBgColor (WidgetBackdropColor), не голый
    clWindow (см. комментарий в TAudioWidget.Paint). }
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(Box);

  PaintRoundRectAA(Canvas, Box, Radius, [],
    BlendWithBackground(AUDIO_COLOR, SENDER_BG_OPACITY, clWindow), clNone);

  IconR := IconRect;
  if not FDownloaded then begin
    { Файла ещё нет на диске — значок "скачать", не мим-тип: клик по
      нему запускает загрузку, не открытие несуществующего файла. }
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

  { Нет полосы прогресса (в отличие от аудио) — незачем разносить
    строки на её высоту: имя — по верхнему краю значка, размер — по
    нижнему, без зазора между ними, кроме собственной высоты строк. }
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
  Cursor := crHandPoint;   { весь виджет кликабелен }
  FBgColor := clWindow;    { запасной вариант до первого LayoutPhotoWidgets }
end;

destructor TPhotoWidget.Destroy;
begin
  { ClearBitmaps отменяет ещё не завершившийся фоновый декод (см. её
    же комментарий) — без этого DecodeDone позже вызвала бы метод на
    уже уничтоженном объекте. }
  ClearBitmaps;
  inherited Destroy;
end;

procedure TPhotoWidget.ClearBitmaps;
begin
  if FDecodeThread <> nil then begin
    { Виджет переиспользован под другое сообщение/размер до того, как
      прежний фоновый декод успел закончиться — тот больше не нужен;
      Cancel гарантирует, что DoDone не тронет поля этого объекта
      результатом, который уже никого не интересует (см. её же
      комментарий). Указатель обнуляем сразу — виджет живёт дальше,
      "декод для меня сейчас не идёт" должно быть верно немедленно. }
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
    { Виджет из пула переиспользован под ДРУГОЕ сообщение — старые
      декодированные битмапы относятся не к этому фото, обнуляем.
      Если ARowId тот же (обычный повторный проход LayoutPhotoWidgets,
      вызывается на каждый Paint скроллера) — битмапы НЕ трогаем, та
      же причина, что уже документирована у TAudioWidget.SetTrack. }
    ClearBitmaps;
  end;
  FRowId := ARowId;
  FNaturalW := ANaturalW;
  FNaturalH := ANaturalH;
  OldTargetW := FTargetW;
  OldTargetH := FTargetH;
  ComputePhotoPreviewSize(ANaturalW, ANaturalH, AMaxW, FTargetW, FTargetH);
  if (FTargetW <> OldTargetW) or (FTargetH <> OldTargetH) then begin
    { Ширина колонки поменялась (окно изменило размер) — уже
      декодированные битмапы теперь не того размера. FLocalPath
      сбрасываем тоже — иначе блок "путь появился/сменился" ниже не
      перезайдёт в decode заново для того же самого пути. }
    ClearBitmaps;
    FLocalPath := '';
  end;

  { Блюр-плейсхолдер из minithumbnail — декодируем и блюрим один раз
    (пока не готов), не при каждом заходе: сам файл крошечный, но
    ресемпл+блюр не бесплатны, а этот метод вызывается на каждый Paint.
    Двойной блюр (10px на источнике, растягивание, ещё 10px на
    результате) — первый проход на крошечном (~30×40) исходнике убирает
    блочность JPEG ДО растягивания, второй — сглаживает сам ресемпл
    (rmFineResample и так даёт мягкую интерполяцию, но второй блюр
    добавляет запас на случай, если исходник был не настолько мал). }
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

  { Настоящее фото — декодируем, только когда путь реально появился/
    сменился, не на каждый заход, и ТЕПЕРЬ В ФОНОВОМ ПОТОКЕ (photodecoder.
    pas), не синхронно здесь — при агрессивной автозагрузке "далеко
    вперёд" несколько строк с уже скачанным, но ещё ни разу не
    показанным фото могут стать видимыми почти одновременно при
    быстром скролле; полноразмерный JPEG-декод+ресемпл на каждую из
    них синхронно внутри SetPhoto (а тот вызывается из LayoutPhotoWidgets,
    из Paint) ощутимо подвешивал прокрутку — отчёт пользователя. Сам
    результат применяется позже, в DecodeDone (Synchronize, главный
    поток) — Invalidate ниже в этом методе картинку ещё не покажет,
    только фон/блюр-плейсхолдер, актуальный кадр придёт отдельно. }
  if (ALocalPath <> '') and (ALocalPath <> FLocalPath) then begin
    if FDecodeThread <> nil then begin
      { Не должно случаться на практике (путь для одной и той же строки
        меняется максимум один раз, с '' на реальный) — но если всё же
        случится, прежний ещё не завершившийся декод больше не нужен. }
      FDecodeThread.Cancel;
    end;
    FreeAndNil(FRealBmp);
    FDecodeThread := TPhotoDecodeThread.Create(ALocalPath, FTargetW, FTargetH, @DecodeDone);
  end;

  FDownloaded := ADownloaded;
  FLocalPath := ALocalPath;
  Invalidate;
end;

{ Колбэк TPhotoDecodeThread — уже на главном потоке (Synchronize).
  FDecodeThread обнуляется здесь безусловно: это ЕДИНСТВЕННОЕ место,
  где декод завершается сам, естественным путём (ClearBitmaps —
  единственное ДРУГОЕ место, трогающее это поле — само обнуляет его,
  когда декод отменяется ДО этого момента, см. её комментарий, так что
  к моменту, когда DoDone вызвал этот колбэк, если он вообще вызвал —
  FCanceled уже был бы True и этот метод не вызвался бы, см.
  TPhotoDecodeThread.DoDone). }
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

{ Заливает клиентскую область (уже настоящим цветом фона clWindow —
  реальный дочерний control, не просвечивает canvas родителя) и рисует
  переданный битмап, растянутый на весь TargetW x TargetH, с маской
  скругления PHOTO_CORNER_RADIUS — тем же приёмом, что и круглые
  аватарки (avatarcache.ApplyRoundMaskTo), только прямоугольная маска
  вместо круглой. }
procedure TPhotoWidget.DrawBmpRounded(ABmp: TBGRABitmap);
const
  BORDER_W = 1;
var
  Mask, Masked: TBGRABitmap;
  Radius, RgnRadius: integer;
  NearXY, FarX, FarY: single;
  Rgn: HRGN;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(ClientRect);

  if (ABmp = nil) or (ABmp.Width <= 0) or (ABmp.Height <= 0) then begin
    Exit;
  end;

  if not SMOOTH_CORNERS then begin
    { Старый метод — без BGRABitmap-маски (тест влияния сглаженной
      отрисовки на плавность скролла, см. SMOOTH_CORNERS), но углы
      всё равно должны оставаться скруглёнными — ПРАВКА ПО МЕСТУ:
      первая версия рисовала битмап прямоугольным вовсе без скругления,
      пользователь указал, что скругление именно фото-превью потерялось
      при переходе на этот флаг, попросил вернуть. GDI не умеет
      альфа-маскировать произвольное изображение (ApplyMask — только
      BGRABitmap), но умеет ограничить область вывода регионом —
      CreateRoundRectRgn/SelectClipRgn (тот же приём, что уже
      использовался в этом файле для похожей задачи — клип-регион под
      полосу цитаты ответа, впоследствии убранную вместе с самой
      полосой, см. CLAUDE.md). Регион — временный, снимается и
      освобождается сразу после отрисовки. Обводка поверх — обычный
      GDI Canvas.RoundRect, тем же радиусом, без антиалиасинга. }
    RgnRadius := Min(PHOTO_CORNER_RADIUS, Min(ABmp.Width, ABmp.Height) div 2);
    Rgn := Windows.CreateRoundRectRgn(0, 0, ABmp.Width, ABmp.Height,
      RgnRadius * 2, RgnRadius * 2);
    Windows.SelectClipRgn(Canvas.Handle, Rgn);
    try
      ABmp.Draw(Canvas, 0, 0, False);
    finally
      Windows.SelectClipRgn(Canvas.Handle, 0);
      Windows.DeleteObject(Rgn);
    end;
    Canvas.Pen.Style := psSolid;
    Canvas.Pen.Color := PHOTO_BORDER_COLOR;
    Canvas.Pen.Width := BORDER_W;
    Canvas.Brush.Style := bsClear;
    Canvas.RoundRect(0, 0, ABmp.Width, ABmp.Height, RgnRadius * 2, RgnRadius * 2);
    Exit;
  end;

  Radius := Min(PHOTO_CORNER_RADIUS, Min(ABmp.Width, ABmp.Height) div 2);

  { Корень трёх последовательных правок этой функции (белый зазор в
    углу, потом обрезанная обводка справа/снизу, потом мутная обводка
    слева/сверху) — один и тот же факт, каждый раз понятый чуть
    точнее: BGRABitmap считает координаты "по центру пикселя"
    (APixelCenteredCoordinates=True — это ЗНАЧЕНИЕ ПО УМОЛЧАНИЮ и у
    FillRoundRectAntialias, и у RoundRectAntialias, проверено чтением
    исходника bgrapolygon.pas, не угадано) — целая координата N это
    ЦЕНТР пикселя N, а не граница между пикселями N-1 и N, как в GDI
    (тем способом координаты читал я, отсюда все три правки). Из-за
    этого (0,0,Width,Height) — не "весь битмап", а сдвинуто на +0.5
    пикселя вправо/вниз от истинных границ: левый/верхний край задевает
    мягкую антиалиасинговую кромку (мутно), правый/нижний уходит ЗА
    истинный край, там сглаживать уже нечему (чётко, но обрезано у
    обводки — обводка ведь ограничена самим битмапом). Верная граница
    заливки для FillRoundRectAntialias (пиксель-центрированные
    координаты) — не (0,0,W,H), а (-0.5,-0.5,W-0.5,H-0.5): ровно
    середина между "здесь есть пиксель" и "здесь уже нет". }
  Masked := ABmp.Duplicate as TBGRABitmap;
  Mask := TBGRABitmap.Create(ABmp.Width, ABmp.Height, BGRABlack);
  try
    Mask.FillRoundRectAntialias(-0.5, -0.5, ABmp.Width - 0.5, ABmp.Height - 0.5,
      Radius, Radius, BGRAWhite);
    Masked.ApplyMask(Mask);

    { Обводка — та же поправка, плюс сам путь линии (она рисуется
      ЦЕНТРИРОВАННОЙ на своих координатах) сдвинут так, чтобы вся её
      толщина BORDER_W легла внутрь битмапа: путь ближнего края —
      BORDER_W/2 минус та же поправка на пиксель-центрирование (0.5),
      дальнего — Width минус то же самое. При BORDER_W=1 это ровно
      (0, 0, Width-1, Height-1) — путь через центры крайних пикселей. }
    NearXY := BORDER_W / 2 - 0.5;
    FarX := ABmp.Width - BORDER_W / 2 - 0.5;
    FarY := ABmp.Height - BORDER_W / 2 - 0.5;
    Masked.RoundRectAntialias(NearXY, NearXY, FarX, FarY, Radius, Radius,
      ColorToBGRA(PHOTO_BORDER_COLOR), BORDER_W);
    Masked.Draw(Canvas, 0, 0, False);
  finally
    Mask.Free;
    Masked.Free;
  end;
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
    { Значок "скачать" — по центру превью, тот же кадр, что и у
      TFileWidget для недокачанного файла. }
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

{ Блит уже готового BGRA-буфера (AWidth*AHeight*4 байт, порядок строк
  сверху вниз — тот же, что отдаёт swscale в videoplayer.pas) напрямую
  на Canvas, без промежуточного TBGRABitmap — единственная причина
  завести отдельную функцию, не переиспользовать TBGRABitmap.Draw:
  тому пришлось бы каждый раз оборачивать чужую память во временный
  объект, а SetDIBitsToDevice делает то же самое одним системным
  вызовом. AV_PIX_FMT_BGRA (ffdecode.pas) — тот же порядок байт
  (B,G,R,A) в памяти, что и стандартный 32-битный DIB Windows
  (biBitCount=32, BI_RGB) — конвертация не нужна, только описать
  формат. biHeight отрицательный — DIB "сверху вниз", без переворота
  строк. }
procedure DrawBgraBuffer(ACanvas: TCanvas; ABuf: PByte; AWidth, AHeight: integer);
var
  Bmi: Windows.BITMAPINFO;
begin
  { Windows.BITMAPINFO квалифицировано явно — LCLType тоже объявляет
    свой TBitmapInfo (другой, нижнеуровнево несовместимый тип), а он
    идёт позже Windows в uses этого файла и перекрывает имя при
    неквалифицированном использовании (та же ловушка, что уже описана
    в комментарии у самого uses) — SetDIBitsToDevice из модуля Windows
    требует именно Windows.BITMAPINFO, не чужой одноимённый тип. }
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
  { Интервал опроса — частота "проверить, не появился ли новый кадр и
    перерисоваться", НЕ пауза между кадрами исходного видео (ту решает
    сам поток-декодер, см. TAnimationPlayer.ExecuteInner/HandleFrame) —
    ~30 раз в секунду с запасом относительно типичного видео 24-30fps. }
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
    { Виджет из пула переиспользован под ДРУГОЕ сообщение — тот же
      приём, что у TPhotoWidget.SetPhoto: старое воспроизведение (если
      играло) и старый декодированный плейсхолдер к этому сообщению
      больше не относятся. }
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
    { Ширина колонки поменялась — старые FFrameBuf/декодированный
      плейсхолдер теперь не того размера. FFrameBuf освобождаем
      (не просто оставляем) — иначе следующий TryGetFrame записал бы
      кадр НОВОГО размера в буфер СТАРОГО размера, повреждая память. }
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
        { НЕ композитим маску/обводку в сам битмап (в отличие от
          TPhotoWidget) — скругление у этого виджета всегда рисуется в
          Paint через дешёвый GDI-регион, одинаково для плейсхолдера и
          живого кадра (см. комментарий у класса) — FBlurBmp остаётся
          простым прямоугольным битмапом. }
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
    { FreeOnTerminate=True на стороне TAnimationPlayer (videoplayer.pas,
      см. её же комментарий про причину) — StopPlayback асинхронно
      просит поток остановиться и забываем указатель сразу же, не
      обращаемся к объекту после: он может быть уничтожен (сам собой,
      из своего же потока) в любой момент после этого. }
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
  Rgn: HRGN;
  RgnRadius: integer;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Style := psClear;
  Canvas.Brush.Color := FBgColor;
  Canvas.FillRect(ClientRect);

  if (Width > 0) and (Height > 0) then begin
    RgnRadius := Min(PHOTO_CORNER_RADIUS, Min(Width, Height) div 2);
    Rgn := Windows.CreateRoundRectRgn(0, 0, Width, Height, RgnRadius * 2, RgnRadius * 2);
    Windows.SelectClipRgn(Canvas.Handle, Rgn);
    try
      if FPlaying and (FFrameBuf <> nil) then begin
        DrawBgraBuffer(Canvas, FFrameBuf, Width, Height);
      end else if FBlurBmp <> nil then begin
        FBlurBmp.Draw(Canvas, 0, 0, False);
      end;
    finally
      Windows.SelectClipRgn(Canvas.Handle, 0);
      Windows.DeleteObject(Rgn);
    end;
    Canvas.Pen.Style := psSolid;
    Canvas.Pen.Color := PHOTO_BORDER_COLOR;
    Canvas.Pen.Width := 1;
    Canvas.Brush.Style := bsClear;
    Canvas.RoundRect(0, 0, Width, Height, RgnRadius * 2, RgnRadius * 2);
  end;

  if not FDownloaded then begin
    { Значок "скачать" — по центру превью, тот же кадр, что и у
      TFileWidget/TPhotoWidget для недокачанного. Не рисуется, пока
      играет (FPlaying) — если уже скачано и играет, показывать нечего:
      никаких контролов, скачивание давно позади. }
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
end;

destructor TMsgScroller.Destroy;
begin
  StopActivePlayer;
  FlushDonePlayer;
  FAudioActive.Free;
  { Сами виджеты не освобождаем: они дочерние control'ы Self,
    их уничтожит LCL вместе с родителем. }
  FAudioPool.Free;
  FFileActive.Free;
  FFilePool.Free;
  FPhotoActive.Free;
  FPhotoPool.Free;
  FAnimActive.Free;
  FAnimPool.Free;
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
  { Align/Resize может дёрнуть это ещё в конструкторе TFrameHistory,
    когда у фрейма самого ещё нет Parent (навигатор выставляет его
    только ПОСЛЕ Create) — обращение к Canvas в этот момент кидает
    EInvalidOperation "Control has no parent window". Досчитаем,
    когда появится настоящий хэндл: BindModel и следующий Resize это
    гарантируют. }
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
    { Цитата ответа (reply_to) рисуется ВЫШЕ цитаты репоста/контента —
      её высота добавляется к PreH отдельно, а не внутри ForwardMetrics
      (это два независимых, ортогональных свойства сообщения: реплай и
      репост технически могут встретиться на одном сообщении разом). }
    PreH := PreH + ReplyExtraH(FModel[I]);
    Ctx.AvailWidth := InnerW;
    H := HEADER_BAR_H + PreH + RendererFor(FModel[I].Kind).Measure(FModel[I], Ctx) + PostH;
    FOffsets[I + 1] := FOffsets[I] + H + MSG_GAP;
  end;

  FTotalHeight := FOffsets[Cnt];
end;

{ Метрики цитаты репоста — единый источник для RebuildOffsets (высота
  строки) и ContentRect/ForwardCardRect/ForwardHeaderRect (где рисовать),
  тем же приёмом, что ColumnBounds. AColW — ШИРИНА КОЛОНКИ целиком
  (ColR-ColL, ДО вычитания чьих-либо паддингов) — у цитаты свой,
  цитата структурно нарочно то же самое "заголовок+контент", что и весь
  блок, вложенное — переиспользует ровно те же MSG_PAD_H/MSG_PAD_V, что
  и обычный (не вложенный) блок, чтобы отступы контента от рамки цитаты
  визуально совпадали с отступами обычного сообщения от рамки блока.
  FORWARD_HEADER_GAP — единственное по-настоящему отдельное число,
  и только для одного места: зазор МЕЖДУ основным заголовком блока и
  рамкой цитаты (см. FORWARD_HEADER_GAP выше). Не репост — APreH/APostH/
  AInnerW как у обычного блока. }
function TMsgScroller.ContentPadV(ARow: TMsgRow): integer;
begin
  { Обычный вертикальный отступ контента от заголовка блока/от нижнего
    края блока — MSG_PAD_V, кроме аудио/голосового/файла/фото/"гифки":
    у всех по месту пользователя этот отступ должен совпадать с
    MSG_PAD_H=11, не с обычным вертикальным (MSG_PAD_V=6). Список рос
    по одному правкой "по месту" на каждый новый тип виджета —
    ContentPadV затем единственное место, которое их всех и покрывает
    разом (голосовое — тот же TAudioWidget, что и аудио, "гифка" —
    тот же класс отступа, что у фото, тем же рассуждением). }
  if (ARow <> nil) and
    (ARow.Kind in [mckAudio, mckVoiceNote, mckFile, mckPhoto, mckAnimation]) then begin
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
  { До контента: зазор от основного заголовка (FORWARD_HEADER_GAP) +
    мини-заголовок цитаты (HEADER_BAR_H) + её собственный отступ до
    контента — тот же PadV, что и у обычного блока. После контента
    — собственный нижний отступ цитаты (PadV, симметричен верхнему
    внутри самой цитаты) + отступ ОТ рамки цитаты до края основного
    блока — тот же FORWARD_HEADER_GAP, что и сверху (симметрия с
    зазором "заголовок блока → цитата", а не обычный PadV: цитата
    — не обычный контент, а вложенный элемент со своим отступом от
    родителя с обеих сторон). }
  APreH := FORWARD_HEADER_GAP + HEADER_BAR_H + PadV;
  APostH := PadV + FORWARD_HEADER_GAP;
  { Ширина контента: рамка цитаты отстоит от краёв блока на MSG_PAD_H
    (как обычный контент от блока), содержимое внутри рамки — ещё на
    такой же MSG_PAD_H от неё. }
  AInnerW := AColW - 4 * MSG_PAD_H;
  if AInnerW < 20 then begin
    AInnerW := 20;
  end;
end;

procedure TMsgScroller.ColumnBounds(out ALeft, ARight: integer);
var
  W: integer;
begin
  { MAX_MSG_W = 0 — колонка во всю ширину фрейма, без ограничения. }
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

{ ---------------- автозагрузка ---------------- }

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
  case ARow.Kind of
    mckPhoto: MediaKind := 'images';
    { Голосовое — тот же виджет и та же настройка "Audio", что и
      обычное аудио (см. LayoutAudioWidgets) — отдельной категории для
      voice note в настройках Auto download нет и не нужно. }
    mckAudio, mckVoiceNote: MediaKind := 'audio';
    mckFile:  MediaKind := 'files';
    mckAnimation: MediaKind := 'gif';
  else
    { Видео/стикеры — по-прежнему только плейсхолдер (см. TODO.md),
      скачивать заранее нечего: у них нет ни своего Ensure*File, ни
      своего file_id на TMsgRow. }
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
      { Обе копии — превью (для инлайн-показа в самом чате) и оригинал
        (чтобы открытие по клику потом было мгновенным) — то же самое,
        что уже сейчас качает первый клик по фото (см. PhotoWidgetClick),
        только без клика. }
      FModel.EnsurePhotoFile(ARow);
      FModel.EnsurePhotoBestFile(ARow);
    end;
    mckAudio, mckVoiceNote:
      FModel.EnsurePlayableFile(ARow);
    mckFile:
      FModel.EnsureDocFile(ARow);
    mckAnimation: begin
      { По прямому запросу пользователя — при включённой автозагрузке
        "гифка" не просто качается, а сразу зацикленно проигрывается.
        AnimAutoPlay — постоянная пометка строки (не разовая команда):
        сам запуск StartLoop делает LayoutAnimationWidgets на каждом
        заходе раскладки, как только файл готов (см. её комментарий) —
        здесь достаточно попросить загрузку и выставить флаг. }
      FModel.EnsureAnimFile(ARow);
      ARow.AnimAutoPlay := True;
    end;
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
  end;
end;

procedure TMsgScroller.PrefetchAutoDownload(ADirection: integer);
var
  Idx, EndIdx: integer;
begin
  if (FModel = nil) or (ADirection = 0) then begin
    Exit;
  end;
  if ADirection > 0 then begin
    Idx := LastVisible + 1;
    EndIdx := Min(FModel.Count - 1, LastVisible + AUTODL_PREFETCH_MESSAGES);
    while Idx <= EndIdx do begin
      MaybeAutoDownload(FModel[Idx]);
      Inc(Idx);
    end;
  end else begin
    Idx := FirstVisible - 1;
    EndIdx := Max(0, FirstVisible - AUTODL_PREFETCH_MESSAGES);
    while Idx >= EndIdx do begin
      MaybeAutoDownload(FModel[Idx]);
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
  ContentH := BlockH - HEADER_BAR_H - PreH - PostH;
  TopY := FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + PreH;
  if (R <> nil) and (R.ForwardKind <> mfoNone) then begin
    { Контент цитаты — внутри рамки ForwardCardRect, у которой уже свой
      MSG_PAD_H от краёв блока (как у обычного контента); ещё один такой
      же MSG_PAD_H — собственный отступ содержимого ОТ этой рамки (см.
      ForwardMetrics) — тот же по величине отступ, что у контента
      обычного сообщения от его блока, не отдельное число. }
    Result := Rect(ColL + 2 * MSG_PAD_H, TopY,
      ColR - 2 * MSG_PAD_H, TopY + ContentH);
    Exit;
  end;
  Result := Rect(ColL + MSG_PAD_H, TopY, ColR - MSG_PAD_H, TopY + ContentH);
end;

{ Рамка цитаты целиком (заливка/обводка) — от конца основного заголовка
  плюс FORWARD_HEADER_GAP (единственный отступ, специфичный для цитаты),
  до нижнего внутреннего отступа цитаты после ContentRect (см.
  ForwardMetrics: APostH = 2*MSG_PAD_V, первый MSG_PAD_V — как раз этот
  нижний отступ). Горизонтально — тот же MSG_PAD_H, что и у обычного
  (не вложенного) контента от блока — см. комментарий у ForwardMetrics.
  Не репост — пустой Rect, вызывающий обязан сам проверить ForwardKind
  перед вызовом. }
function TMsgScroller.ForwardCardRect(AIndex: integer): TRect;
var
  ColL, ColR: integer;
  CR: TRect;
begin
  ColumnBounds(ColL, ColR);
  CR := ContentRect(AIndex);
  { ReplyExtraH — если у сообщения ЕЩЁ и есть цитата ответа (reply_to),
    она рисуется первой, а карточка репоста сдвигается ниже её.
    Нижний отступ — ContentPadV(ARow), НЕ голый MSG_PAD_V: у аудио он
    11px (как и остальные три стороны), не обычные 6px — раньше здесь
    было захардкожено MSG_PAD_V, отчего у аудио-виджета внутри карточки
    репоста нижний отступ был у́же трёх остальных сторон. }
  Result := Rect(ColL + MSG_PAD_H,
    FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + ReplyExtraH(FModel[AIndex]) + FORWARD_HEADER_GAP,
    ColR - MSG_PAD_H, CR.Bottom + ContentPadV(FModel[AIndex]));
end;

{ Строка "аватар+имя+время" внутри цитаты — верхняя полоса ForwardCardRect,
  высотой HEADER_BAR_H (та же величина, что и у основного заголовка блока —
  цитата структурно то же самое "заголовок+контент", см. ForwardMetrics). }
function TMsgScroller.ForwardHeaderRect(AIndex: integer): TRect;
var
  Card: TRect;
begin
  Card := ForwardCardRect(AIndex);
  Result := Rect(Card.Left, Card.Top, Card.Right, Card.Top + HEADER_BAR_H);
end;

{ FORWARD_HEADER_GAP — зазор ОТ ОСНОВНОГО ЗАГОЛОВКА до плашки цитаты
  ответа, тот же самый (не просто равный по значению), что и у карточки
  репоста, по месту пользователя: "цитата от верхнего края основного
  сообщения так же должна отстоять на 11 пикселей, как и пересланное
  сообщение" — переиспользуем именно эту константу, а не заводим
  REPLY_TOP_GAP с тем же числом, чтобы они не могли разъехаться при
  следующей правке. "REPLY_BOX_H" ниже — уже сама плашка; отступ ПОСЛЕ
  неё (до карточки репоста, если есть, либо до контента) — обычный
  MSG_PAD_V, как и у всего остального в ForwardMetrics, см. вызовы
  ReplyExtraH в RebuildOffsets/ContentRect/ForwardCardRect: везде это
  прибавляется К ГОЛОВЕ уже готового PreH из ForwardMetrics (который
  сам начинается с MSG_PAD_V для обычного контента или с
  FORWARD_HEADER_GAP для карточки репоста) — то есть "отступ после
  плашки" тут получается автоматически, из уже существующего PreH, а
  не отдельным слагаемым здесь. }
function TMsgScroller.ReplyExtraH(ARow: TMsgRow): integer;
begin
  if (ARow = nil) or (ARow.ReplyMessageId = 0) then begin
    Result := 0;
  end else begin
    Result := FORWARD_HEADER_GAP + REPLY_BOX_H;
  end;
end;

{ Плашка цитаты ответа — сразу под основным заголовком блока, на том же
  отступе (FORWARD_HEADER_GAP), что и карточка репоста от него. Если у
  сообщения ЕЩЁ и репост — карточка репоста и контент сдвинуты ниже
  неё, см. ReplyExtraH в ForwardCardRect/ContentRect/RebuildOffsets. }
function TMsgScroller.ReplyBoxRect(AIndex: integer): TRect;
var
  ColL, ColR, TopY: integer;
begin
  ColumnBounds(ColL, ColR);
  TopY := FOffsets[AIndex] - FScrollTop + HEADER_BAR_H + FORWARD_HEADER_GAP;
  Result := Rect(ColL + MSG_PAD_H, TopY, ColR - MSG_PAD_H, TopY + REPLY_BOX_H);
end;

{ Зажимает и применяет позицию без уведомления "около верха — догрузи
  ещё". Внутренняя бухгалтерия (ModelChanged, Resize) правит
  FScrollTop программно и НЕ должна интерпретироваться как "юзер
  прокрутил и хочет больше" — за досыл короткой истории отвечает
  MaybeLoadMore в TFrameHistory.ModelChanged, вызываемый отдельно и
  ровно один раз. }
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
  { Упреждающая автозагрузка на AUTODL_PREFETCH_MESSAGES сообщений
    вперёд по направлению скролла — единственное место, где ЛЮБОЕ
    реальное изменение позиции (колесо, клавиши, драг скроллбара,
    программные правки вроде ScrollToBottom) проходит, см. комментарий
    у SetScrollTop. }
  if AValue > OldTop then begin
    PrefetchAutoDownload(1);
  end else if AValue < OldTop then begin
    PrefetchAutoDownload(-1);
  end;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

{ Публичный сеттер — только для настоящей прокрутки пользователем
  (колесо, клавиши, нативный скроллбар). Раньше OnNearTop дёргался
  отсюда же ИЗНУТРИ вложенной цепочки ModelChanged->ScrollToBottom
  ->SetScrollTop->OnNearTop->LoadOlder ещё до возврата в сам
  ModelChanged — рабочей эта цепочка была, но реентрантной и хрупкой.
  Теперь программные правки позиции идут через ClampScrollTop и в
  OnNearTop не заходят вовсе. }
procedure TMsgScroller.SetScrollTop(AValue: integer);
begin
  ClampScrollTop(AValue);
  { НЕ внутри проверки "значение изменилось" у ClampScrollTop: если
    пользователь уже упёрся в самый верх (FScrollTop=0=MaxTop) и
    продолжает крутить колесо вверх, зажатое AValue совпадёт с уже
    текущим FScrollTop — и если бы OnNearTop звался только при
    изменении, подгрузка старой истории переставала бы запускаться
    намертво ровно тогда, когда она нужнее всего.
    ScrollerNearTop idempotent (гвардится LoadingOlder/OldestLoaded),
    повторный вызов безопасен. }
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
  { "Была внизу" — только когда реально существовала прокручиваемая
    область и мы были у её конца. OldMax<=0 (весь список помещался на
    экране) раньше ЛЮБОЙ такой случай засчитывал как "внизу" — из-за
    этого короткий, ещё догружаемый чат (MaybeLoadMore подгружает
    историю сам, пока контента не хватает на экран) на каждую подгрузку
    прыгал к низу, забивая попытку пользователя проскроллить вверх ДО
    того, как список вырастет больше экрана. Для OldCount=0 (самое
    первое открытие чата) низ всё равно нужен явно — якорить не к чему. }
  WasAtBottom := (OldCount > 0) and (OldMax > 0) and (FScrollTop >= OldMax - 4);

  { Запоминаем сообщение в верхней видимой строке — после подгрузки
    истории (LoadOlder добавляет контент ВЫШЕ) вернём его на то же
    место в окне, иначе список визуально прыгнет.

    ВАЖНО: id берём из FRowIds, СВОЕГО снимка того же винтажа, что и
    FOffsets/AnchorIdx — НЕ из FModel[AnchorIdx]. К моменту вызова
    ModelChanged модель (TTdMessages) уже перестроена (Rebuild отработал
    до FOnChanged), а FOffsets/FRowIds — ещё старые. LoadOlder вставляет
    новые сообщения В НАЧАЛО списка, сдвигая индексы всех остальных;
    FModel[тот же индекс] после такой вставки — уже СОВСЕМ ДРУГОЕ
    сообщение. Отсюда и "вставляются вразнобой" при подгрузке во время
    скролла вверх — старый индекс молча читался из уже сдвинутых данных. }
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

  { Ждали скачивания файла, чтобы начать проигрывание (клик по play на
    ещё не скачанном треке, см. AudioPlayClick) — путь мог появиться
    именно в этом апдейте. }
  if FPendingPlayMsgId <> 0 then begin
    PendingIdx := FModel.IndexOfId(FPendingPlayMsgId);
    if (PendingIdx >= 0) and (PlayableLocalPath(FModel[PendingIdx]) <> '') then begin
      StartPlayback(FModel[PendingIdx]);
      FPendingPlayMsgId := 0;
    end;
  end;

  { То же самое для "Save as..."/"Show in folder" на ещё не скачанном
    файле, см. FileWidgetSaveAsClick/FileWidgetShowInFolderClick. }
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

  { То же для фото, см. PhotoWidgetSaveAsClick/PhotoWidgetShowInFolderClick.
    PhotoBestLocalPath (оригинал), не PhotoLocalPath (превью-копия) —
    оба меню-действия ждут именно оригинал, см. комментарий у
    TMsgRow.PhotoBestFileId. }
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

  { Открытие чата и новые сообщения проходят ЗДЕСЬ, не через
    ClampScrollTop — то упреждает окном сообщений ТОЛЬКО при реальном
    изменении позиции скролла, а самая первая страница чата (и любое
    сообщение, прилетевшее сразу в уже видимую область без скролла)
    иначе не попала бы под автозагрузку вовсе. }
  AutoDownloadVisible;

  Invalidate;
  if Assigned(FOnScrollRangeChanged) then begin
    FOnScrollRangeChanged(Self);
  end;
end;

procedure TMsgScroller.Resize;
begin
  inherited Resize;
  { Тоже вне try/except-обвязки TFrameHistory.ModelChanged: Resize
    зовёт LCL напрямую (изменение размера окна, сплиттер), а не
    ModelChanged. RebuildOffsets — то же измерение реальных
    сообщений, что и там, значит те же риски. }
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
    Exit;   { пустое выделение — обычный клик без drag }
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

{ Аватарка источника репоста. AOwned=False (обычный случай) — результат
  в FForwardChatAvatars/FForwardUserAvatars, вызывающий НЕ освобождает.
  AOwned=True — снимок "фото ещё не скачано" (см. ниже), вызывающий
  обязан освободить сам. nil — строить не из чего вовсе (mfoHiddenUser,
  нет числового id — см. вызов в PaintForwardCard, там свой запасной
  вариант без кэша). Источник данных — TChatRow (mfoChat/mfoChannel, по
  ForwardChatId через TdChatList) или ничего, кроме имени (mfoUser — в
  проекте пока нет скачанных фото произвольных пользователей,
  tdusers.pas хранит только имя/цвет, см. ARCHITECTURE.md). }
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
    Exit;   { mfoNone/mfoHiddenUser — нет стабильного id, см. комментарий выше }
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
      { Список чатов сам скачивает настоящее фото только для строк,
        реально видимых в TDrawGrid (framechats.pas:757,
        TTdChats.EnsureAvatar) — источник репоста туда обычно не входит
        (это ЧУЖОЙ канал/группа, необязательно наш, в списке чатов).
        Без явного запроса здесь PhotoPath остался бы пустым навсегда, и
        рисовалось бы только Minithumb — заведомо мелкое, размытое
        превью (Telegram сам генерирует его таким, "заглушка на время
        загрузки", не полноценная миниатюра — вот и вся причина
        "размытости" из жалобы). }
      L.EnsureAvatar(C);
      Result := RenderAvatarBmp(C.PhotoPath, C.Minithumb, SrcName, Id, HEADER_H, True);
      if C.PhotoPath = '' then begin
        { Настоящее фото ещё не скачано — НЕ кэшируем: со следующей
          перерисовкой (скролл, новое сообщение, что угодно) попробуем
          снова, и как только EnsureAvatar докачает файл, подхватим уже
          настоящую картинку вместо Minithumb. Результат при этом уже
          не принадлежит кэшу — вызывающий обязан его освободить сам
          (иначе утечка: RenderAvatarBmp создаёт новый TBGRABitmap на
          каждый такой вызов). Не идеально (decode Minithumb на каждый
          Paint, пока файл не готов), но дёшево и временно — реальных
          цитат на экране одновременно немного. }
        AOwned := True;
        Exit;
      end;
    end else begin
      Result := RenderAvatarBmp('', '', SrcName, Id, HEADER_H, True);
    end;
  end else begin
    { mfoUser — для произвольных пользователей в проекте вообще нет
      механизма скачивания фото (см. TODO.md), апгрейда не будет —
      кэшировать инициалы насовсем можно спокойно. }
    Result := RenderAvatarBmp('', '', SrcName, Id, HEADER_H, True);
  end;
  if Result <> nil then begin
    Map.Add(Id, Result);
  end;
end;

{ Цитата репоста — рамка (заливка тем же приёмом, что и подложка
  внешнего блока, SENDER_BG_OPACITY) и внутри неё своя строка
  "аватар+имя+время" с СОБСТВЕННОЙ подложкой (SENDER_HEADER_OPACITY,
  скруглены только верхние углы — тот же приём "нарисовать всё
  скруглённым и спрямить низ FillRect'ом", что и у основного заголовка
  блока, см. Paint) — оба цвета источника, не отправителя. Обводка
  рамки рисуется отдельно, в Paint, ПОСЛЕ содержимого цитаты — тем же
  порядком, что и у внешнего блока (контур поверх всего). Имя — ссылка
  (курсор меняется на руку в MouseMove) только для mfoChannel: только
  там TDLib вообще даёт message_id исходного поста, без которого
  getMessageLink нечего резолвить (см. TMsgForwardKind в tdmessages.pas
  — приватность остальных случаев запрещает строить ссылку). }
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

  PaintRoundRectAA(Canvas, CardRect, Radius, [],
    BlendWithBackground(Clr, SENDER_BG_OPACITY, clWindow), clNone);

  { Скруглены только верхние углы — своим набором AOptions вместо
    прежнего трюка "нарисовать все 4 и спрямить низ FillRect'ом"
    (GDI RoundRect не умел per-corner, BGRA умеет нативно). }
  HeaderRadius := Min(FORWARD_CORNER_RADIUS, HEADER_BAR_H div 2);
  PaintRoundRectAA(Canvas, HeaderRect, HeaderRadius, [rrBottomLeftSquare, rrBottomRightSquare],
    BlendWithBackground(Clr, SENDER_HEADER_OPACITY, clWindow), clNone);

  AvBmp := ForwardAvatarBmp(ARow, FreeAvBmp);
  if AvBmp = nil then begin
    { mfoHiddenUser (или ещё не резолвившийся id) — рендерим на месте,
      без кэша: это только инициалы, decode файла/превью тут не бывает
      (см. ForwardAvatarBmp), так что дёшево даже каждую перерисовку. }
    AvBmp := RenderAvatarBmp('', '', ForwardSourceName(ARow), 0, HEADER_H, True);
    FreeAvBmp := True;
  end;
  { Тот же горизонтальный отступ, что и у внешнего заголовка
    (HeaderX := BR.Left + MSG_PAD_H, см. Paint) — и та же вертикальная
    центровка (HEADER_PAD_V). }
  AvX := HeaderRect.Left + MSG_PAD_H;
  AvY := HeaderRect.Top + HEADER_PAD_V;
  if AvBmp <> nil then begin
    AvBmp.Draw(Canvas, AvX, AvY, False);
    if FreeAvBmp then begin
      AvBmp.Free;
    end;
  end;

  { Имя+время — ОДНОЙ строкой в цвете источника, тем же приёмом, что и
    у внешнего заголовка (там тоже единый TextOut на "Имя (HH:MM)",
    цветом отправителя целиком — время не отдельным серым суффиксом). }
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
end;

{ Цитата ответа (reply_to) — компактная плашка: значок цитаты + имя
  цитируемого отправителя (жирным, цветом) + первая строка его текста
  (серым) — подложка/контур/скругление тем же приёмом, что и у карточки
  репоста (см. константы REPLY_*), но без аватара — источник тут не
  внешний объект, а просто своё же более раннее сообщение, значок
  вместо фото. Данные — FModel.ReplyPreview: если ещё не разрешены
  (сообщение ещё грузится через getRepliedMessage), рисуем временную
  серую заглушку — перерисуется сама, как только придут (см.
  TTdMessages.GetRepliedDone → Touch → полный ModelChanged, не просто
  Invalidate: высота плашки не меняется, но текст появляется). }
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
      { Только первая строка — многострочный текст сжимаем в одну,
        как и оригинальный клиент. }
      SnippetStr := Copy(SnippetStr, 1, NlPos - 1);
    end;
  end else begin
    Clr := clGrayText;
    NameStr := '';
    SnippetStr := 'Loading…';
  end;

  { Подложка — тем же приёмом, что и у карточки репоста (SENDER_BG_
    OPACITY, скруглённые углы с той же защитой от "капсулы", см.
    PaintForwardCard) — но свой радиус, REPLY_CORNER_RADIUS, не
    FORWARD_CORNER_RADIUS напрямую: по прямому запросу пользователя
    каждая карточка получила свою ручку, раньше значение было общим. }
  Radius := Min(REPLY_CORNER_RADIUS, (Box.Bottom - Box.Top) div 2);
  PaintRoundRectAA(Canvas, Box, Radius, [],
    BlendWithBackground(Clr, SENDER_BG_OPACITY, clWindow), clNone);

  { Значок цитаты — из того же ImageList1, что и значки статуса
    сообщения/аватар источника репоста (FormMain.Chats.ImageList1, см.
    комментарий в Paint про общий список с одной сквозной нумерацией). }
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

  { Контур — последним, поверх содержимого, тем же приёмом, что и у
    карточки репоста (SENDER_BORDER_OPACITY, тот же Radius). }
  PaintRoundRectAA(Canvas, Box, Radius, [], clNone,
    BlendWithBackground(Clr, SENDER_BORDER_OPACITY, clWindow));
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

  { Значок статуса — по чату целиком, не по строке: LastReadOutbox
    одинаков для всех сообщений текущего чата, доставать его на
    каждую строку внутри цикла ниже незачем. }
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

  { Единственный путь исполнения из всей смены чата, где раньше не
    было try/except: Paint вызывается напрямую системой отрисовки
    (WM_PAINT), а не через ModelChanged, поэтому туда не долетала
    защита, добавленная в TFrameHistory.ModelChanged/OpenChat.
    Необработанное исключение внутри WM_PAINT — классический источник
    зависаний Win32-приложений (окно перестаёт отвечать на дальнейшую
    перерисовку/ввод); каждая строка — в своём try/except, чтобы одно
    проблемное сообщение не убивало всю перерисовку. }
  for I := Lo to Hi do begin
    try
      R := FModel[I];
      BR := BlockRect(I);
      CR := ContentRect(I);

      { Подложка блока — цвет отправителя приглушённо поверх фона,
        SENDER_BG_OPACITY. Заливаем ПЕРЕД заголовком/контентом, чтобы
        текст и разделительная линия легли поверх, не под. Только
        заливка, без обводки — PaintRoundRectAA (BGRA-антиалиасинг
        вместо GDI Canvas.RoundRect, см. её комментарий) сама не
        трогает состояние Canvas.Brush/Pen. }
      PaintRoundRectAA(Canvas, BR, MSG_CORNER_RADIUS, [],
        BlendWithBackground(SenderColor(R), SENDER_BG_OPACITY, clWindow), clNone);

      { Подложка самой строки заголовка (значок+имя) — заметнее фона
        блока (SENDER_HEADER_OPACITY > SENDER_BG_OPACITY), поверх уже
        закрашенного фона блока. Отступ значка/текста от верхнего и
        нижнего края этой полосы — свой, HEADER_PAD_V, не MSG_GAP
        (HeaderY, а не BR.Top напрямую). Скруглены только ВЕРХНИЕ углы —
        те же, что у блока снаружи; нижние скруглённые превращали бы
        короткую полосу в подобие таблетки, отдельной от блока под ней
        — раньше это требовало нарисовать все 4 скруглёнными и спрямить
        низ отдельным FillRect (GDI RoundRect не умел per-corner),
        теперь низ просто квадратный по built-in опциям BGRA
        (rrBottomLeftSquare/rrBottomRightSquare). Радиус для этой
        полосы — свой, HeaderRadius, не MSG_CORNER_RADIUS напрямую:
        полоса всего HEADER_BAR_H пикселей высотой, и если радиус
        блока больше её половины, скругление вместо аккуратных углов
        превращается в растянутую "таблетку" (оба конца — полукруги,
        сходящиеся у середины) — тот же класс проблемы, что уже был у
        превью фото (см. TPhotoWidget.DrawBmpRounded/CLAUDE.md), не
        исчезает сам по себе просто оттого, что рисуем через BGRA, а
        не GDI — защита остаётся нужна. }
      HeaderRect := Rect(BR.Left, BR.Top, BR.Right, BR.Top + HEADER_BAR_H);
      HeaderRadius := Min(MSG_CORNER_RADIUS, HEADER_BAR_H div 2);
      PaintRoundRectAA(Canvas, HeaderRect, HeaderRadius, [rrBottomLeftSquare, rrBottomRightSquare],
        BlendWithBackground(SenderColor(R), SENDER_HEADER_OPACITY, clWindow), clNone);
      HeaderY := BR.Top + HEADER_PAD_V;

      Canvas.Brush.Style := bsClear;
      Canvas.Font.Name := 'default';
      Canvas.Font.Height := -11;
      HeaderX := BR.Left + MSG_PAD_H;

      { У исходящих — статус доставки, у входящих — просто маркер
        направления (ICON_MSG_INCOMING, не статус: у чужого сообщения
        "доставлено/прочитано" с нашей стороны не бывает). Слот
        зарезервирован в любом случае, чтобы имя не "прыгало" по
        горизонтали от строки к строке. }
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

      RendererFor(R.Kind).Paint(R, Canvas, CR, SelStart, SelEnd);

      if R.ForwardKind <> mfoNone then begin
        { Контур цитаты — тем же порядком, что и у внешнего блока ниже:
          после содержимого, поверх него. }
        FwdBR := ForwardCardRect(I);
        FwdRadius := Min(FORWARD_CORNER_RADIUS, (FwdBR.Bottom - FwdBR.Top) div 2);
        PaintRoundRectAA(Canvas, FwdBR, FwdRadius, [], clNone,
          BlendWithBackground(ForwardSourceColor(R), SENDER_BORDER_OPACITY, clWindow));
      end;

      { Контур блока — рисуется последним, поверх содержимого: только
        обводка, сам текст на MSG_PAD_H от края и краем не задевается. }
      PaintRoundRectAA(Canvas, BR, MSG_CORNER_RADIUS, [], clNone,
        BlendWithBackground(SenderColor(R), SENDER_BORDER_OPACITY, clWindow));
    except
      { Молча пропускаем эту строку: статус-строка обновляется из
        ModelChanged, а не отсюда — Paint может вызываться десятками
        раз в секунду, спамить в неё было бы только хуже. }
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
      { Голосовое — тот же виджет, что и обычное аудио (по прямому
        запросу пользователя, "функционал и внешний вид идентичные"),
        не отдельный класс. }
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
    { Виджет из пула переиспользован — мог представлять ДРУГОЕ
      сообщение до этого, данные трека обновляем при каждом заходе,
      не только при первом получении. }
    W.Images := FAudioImages;
    R := FModel[MIdx];
    W.BackgroundColor := WidgetBackdropColor(R);
    { Голосовое — без title/performer/file_name (TDLib их не даёт, см.
      TMsgRow.VoiceDuration) — статичная подпись вместо них, тем же
      TAudioWidget.SetTrack, без единой правки в самом виджете:
      TitleStr там уже падает на AFileName, когда Title/Performer
      пусты. }
    if R.Kind = mckVoiceNote then begin
      W.SetTrack(R.Id, '', '', 'Voice message', R.VoiceDuration);
    end else begin
      W.SetTrack(R.Id, R.AudioTitle, R.AudioPerformer, R.AudioFileName, R.AudioDuration);
    end;
    { Пока идёт перетаскивание ползунка — не трогаем состояние
      проигрывания этим заходом (LayoutAudioWidgets вызывается на
      КАЖДЫЙ Paint, в т.ч. каждый тик FPlaybackTimer): иначе реальная
      (ещё не догнавшая клик/драг) позиция перезаписала бы локальный
      предпросмотр прямо под курсором. }
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

{ Копия LayoutAudioWidgets — тот же приём recycled-пула, для файлов
  вместо аудио (Kind=mckFile). }
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
    { Файл уже скачан — открываем системным приложением по умолчанию,
      не диалог сохранения (тот теперь только через контекстное меню
      "Save as...", см. FileWidgetSaveAsClick). }
    OpenDocument(string(Row.DocLocalPath));
    Exit;
  end;
  { Ещё не скачан — просто качаем, без диалога: значок сам сменится на
    мим-тип, как только путь придёт (см. ModelChanged/LayoutFileWidgets). }
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
  { Ещё не скачан — запрашиваем и запоминаем, что диалог сохранения
    нужно открыть, как только путь придёт (см. ModelChanged), тот же
    приём, что FPendingPlayMsgId у аудио. }
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
    { Файл уже скачан TDLib'ом в свой кэш — здесь просто копия в место,
      выбранное пользователем, не повторное скачивание. }
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

{ Копия LayoutFileWidgets — тот же приём recycled-пула, для фото
  вместо файла (Kind=mckPhoto). Отличие — ширина/высота виджета не
  во всю колонку (CR), а натуральный размер превью (TargetWidth/
  TargetHeight, посчитан внутри SetPhoto): узкое вертикальное фото не
  должно растягиваться на всю ширину блока. }
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
    { WidgetBackdropColor — не голый BlendWithBackground(SenderColor(R),
      ...): та версия всегда брала цвет ВНЕШНЕГО блока, даже когда фото
      внутри репоста (сидит на подложке карточки цитаты, свой,
      независимый цвет — ForwardSourceColor). Тот же класс правки, что
      и у аудио/файла — см. WidgetBackdropColor. }
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

  { Строго два клика, по прямому запросу пользователя — без
    автоматического открытия, как только оригинал докачается: первый
    клик ТОЛЬКО качает (и превью — блюр -> настоящая миниатюра в самом
    чате, и оригинал — для последующего открытия), повторный клик,
    когда оригинал уже готов — открывает. Ensure*File сами не делают
    лишнего — no-op, если уже скачано/уже запрошено, так что вызывать
    оба безусловно безопасно. }
  if Row.PhotoLocalPath = '' then begin
    FModel.EnsurePhotoFile(Row);
  end;
  if Row.PhotoBestLocalPath = '' then begin
    FModel.EnsurePhotoBestFile(Row);
    Exit;
  end;
  OpenDocument(string(Row.PhotoBestLocalPath));
end;

{ Копия LayoutPhotoWidgets — тот же приём recycled-пула, для "гифок"
  (Kind=mckAnimation) вместо фото. Отличие — после обычного
  позиционирования проверяет R.AnimAutoPlay (см. MaybeAutoDownload):
  если автозагрузка для этого типа диалога включена и файл уже
  скачан, а виджет ещё не играет — запускает луп сам, без клика. Эта
  проверка выполняется на КАЖДЫЙ заход (дёшево — два boolean и
  сравнение строки), а не только в момент, когда файл только что
  докачался — самовосстанавливающееся поведение: если проигрывание
  почему-то остановилось (пересоздание виджета при смене размера
  колонки и т.п.), следующий же заход снова его запустит, пока
  R.AnimAutoPlay не снят (а он не снимается никогда — это постоянное
  свойство строки "эта настройка хотела, чтобы это крутилось", не
  разовый флаг). }
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
      { Виджет уходит из видимой области — останавливаем воспроизведение
        (не пускаем "гифку" бесконечно крутиться в фоне после того, как
        её прокрутили мимо), тем же StopLoop, что и при переиспользовании
        под другое сообщение (см. SetAnim). }
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

{ Ровно два клика, по прямому запросу пользователя, тем же приёмом,
  что и у файла (не как у фото — там дополнительно догружается
  "оригинал" для сохранения, здесь ровно один файл): первый клик по
  недокачанной — только запрашивает скачивание, БЕЗ автопоказа; второй
  клик, когда уже скачано — запускает зацикленное воспроизведение.
  Клик по уже играющей — намеренно ничего не делает: контролов
  запуска/остановки у "гифки" нет вовсе. }
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

  { "Save as" сохраняет ОРИГИНАЛ (PhotoBestLocalPath), не мелкую
    превью-копию (PhotoLocalPath — та для быстрого инлайн-показа,
    см. комментарий у TMsgRow.PhotoBestFileId). }
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

  { "Show in folder" — тот же оригинал, что и "Save as" (см. там же). }
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
    { Оригинал (PhotoBestLocalPath) — не превью-копия. }
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

{ ---------------- проигрывание аудио ---------------- }

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
    { Тот же трек — просто пауза/продолжить, не пересоздаём плеер. }
    if FActivePlayer.State = apsPlaying then begin
      FActivePlayer.Pause;
    end else if FActivePlayer.State = apsPaused then begin
      FActivePlayer.Resume;
    end;
    Invalidate;
    Exit;
  end;

  { Другой трек (или ничего не играло) — прежний останавливаем. }
  FPendingPlayMsgId := 0;

  if PlayableLocalPath(Row) = '' then begin
    { Файл ещё не скачан — запрашиваем и запомним, что именно этот
      трек нужно начать проигрывать, как только путь придёт (см.
      ModelChanged). Прежний плеер, если играл, всё равно останавливаем
      сейчас — не ждать же его до момента, когда новый файл скачается. }
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
  { Перемотка имеет смысл только для АКТИВНОГО (проигрывается/на паузе)
    трека — виджет разрешает драг ползунка только когда FIsActive
    (см. TAudioWidget.MouseDown), так что сюда и не должно прилетать
    иначе, но проверяем ещё раз на всякий случай. }
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
  { TFrameHistory — синглтон навигатора (TFrameNavigator.ShowFrame сам
    решает создавать или переиспользовать), так что если источник —
    ТЕКУЩИЙ открытый чат, это буквально вызов метода у самого Self же
    владельца, просто через новую точку входа TFrameHistory.OpenChat. }
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
    { Не должно случаться после синхронного Rebuild в TTdMessages.
      JumpDone, но на всякий случай — просто не скроллим, не падаем. }
    Exit;
  end;
  RowH := FOffsets[Idx + 1] - FOffsets[Idx];
  { Центрируем сообщение в видимой области, а не прижимаем к верху —
    так виднее и то, что было до, и то, что после. }
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
  { Клик по плашке цитаты ответа — прыжок к цитируемому сообщению В ТОМ
    ЖЕ чате (ReplyPreview/JumpTo поддерживают только этот случай, см.
    комментарий у TTdMessages.ReplyPreview) — тем же приёмом, что тап
    по цитате в оригинальном клиенте. }
  if (R.ReplyMessageId <> 0) and (FModel <> nil) and (R.ReplyChatId = FModel.ChatId)
    and PtInRect(ReplyBoxRect(Idx), Point(X, Y)) then begin
    FModel.JumpTo(R.ReplyMessageId);
    Exit;
  end;

  { Имя источника в цитате репоста — ссылка только у mfoChannel (только
    там TDLib знает message_id исходного поста, см. TMsgForwardKind).
    Кликабельна вся строка "аватар+имя+время", не только текст имени —
    для такой маленькой строки точный хит-тест по ширине текста не
    стоит лишнего кода. }
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
  { Без захвата мыши: увели курсор за пределы control'а во время
    drag'а и отпустили кнопку там — MouseUp сюда не долетит (LCL не
    маршрутизирует его без MouseCapture), FSelecting зависает в True
    навсегда, и дальше обычное движение мыши БЕЗ зажатой кнопки
    начинает выглядеть как продолжающееся выделение. Это и есть
    "странное поведение выделения". }
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
  { Не константа: список чатов (framechats, TDrawGrid) рисует свой
    скроллбар нативно, шириной под системный метрик — тот же
    GetSystemMetrics(SM_CXVSCROLL), которым Windows и масштабирует
    его под DPI. Фиксированное число здесь просто разъезжалось бы с
    ним при любом отличном от 100% масштабе экрана. }
  FScrollbar.Width := GetSystemMetrics(SM_CXVSCROLL);
  FScrollbar.OnScroll := @ScrollbarScroll;

  FScroller := TMsgScroller.Create(Self);
  FScroller.Parent := Self;
  FScroller.Align := alClient;
  FScroller.OnScrollRangeChanged := @ScrollerRangeChanged;
  FScroller.OnNearTop := @ScrollerNearTop;
  { ImageList1/FileTypes — компоненты фрейма (LFM), к этому моменту уже
    созданы inherited-стримингом, до тела этого конструктора. }
  FScroller.AudioImages := ImageList1;
  FScroller.FileImages := FileTypes;
  FScroller.FilePopupMenu := FilePopupMenu;

  { Флаг ставится последним по тому же правилу, что и во всех формах
    и фреймах проекта: LFM-стриминг (тут его формально нет, но
    Align-докинг может дёрнуть Resize раньше) не должен наткнуться на
    недособранные поля. }
  FReady := True;

  { BindModel сюда, в конструктор, НЕ зовём: у фрейма в этот момент
    ещё нет Parent (TFrameNavigator.ShowFrame выставляет его только
    ПОСЛЕ Create) — до тех пор у control'ов нет настоящего окна, и
    любое обращение к Canvas валит EInvalidOperation "has no parent
    window". Первое связывание — в DoActivate, куда навигатор
    попадает уже после Parent/Visible. }
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

  { Кэш имён и кэш акцентных цветов — не смотрим на nil-раннюю Exit
    ниже: привязываются независимо от того, есть ли уже открытый чат. }
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
  { OpenChat синхронно дёргает FOnChanged (=ModelChanged) прямо
    отсюда — та цепочка сама уже обвязана try/except, но ловим и
    здесь: если исключение всё же прорвётся откуда-то ещё по пути
    (напр. из самой TTdMessages.OpenChat/Clear), пусть осядет в
    статус-строке, а не уйдёт необработанным в LCL — под отладчиком
    это выглядит как наглухо зависшее приложение, если диалог
    исключения всплывает не поверх активного окна. }
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
  { состав аккаунтов фрейму переписки не важен }
end;

procedure TFrameHistory.ModelChanged(Sender: TObject);
begin
  if (not FReady) or (FModel = nil) then begin
    Exit;
  end;
  { Диагностическая обвязка: FScroller.ModelChanged — самый сложный
    кусок (пересчёт оффсетов, удержание якоря прокрутки, измерение
    реальных сообщений через msglayout) и единственное на весь чейн
    смены чата место без своего try/except. Если зависание при
    переключении чатов вызвано необработанным исключением где-то
    здесь (напр. неожиданная форма контента конкретного сообщения при
    первом реальном измерении) — оно осядет в статус-строке вместо
    того, чтобы просочиться в Application.HandleException. }
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
  { Ошибка getChatHistory/sendMessage/viewMessages — без этого сбой
    RPC был бы совсем незаметен: пустой список и тишина. }
  if lblStatus = nil then begin
    Exit;
  end;
  if AAction = 'jump' then begin
    { getChatHistory вокруг сообщения (переход по цитате репоста) не
      удался — обычно потому, что само сообщение с тех пор удалено в
      чате-источнике, а не баг: chat_id/message_id идут как есть из
      forward_info.origin, без ручных преобразований (см.
      TMsgForwardKind в tdmessages.pas). }
    lblStatus.Caption := 'Не удалось перейти к сообщению — возможно, оно удалено';
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
  { Дорезолвилось (или обновилось) чьё-то имя — высота блоков от этого
    не меняется, полная FScroller.ModelChanged (пересчёт офсетов) не
    нужна, только перерисовать. }
  if FReady and (FScroller <> nil) then begin
    FScroller.Invalidate;
  end;
end;

procedure TFrameHistory.MaybeLoadMore;
begin
  if (FModel = nil) or FModel.LoadingOlder or FModel.OldestLoaded then begin
    Exit;
  end;
  { Загруженной истории не хватает даже на один экран — подгружаем
    ещё, иначе пользователь увидит короткий обрубок списка без
    возможности проскроллить и без triggerа "около верха". }
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
  { Классическая Win32-семантика SCROLLINFO: Max — верх диапазона
    прокрутки целиком (как TotalHeight), PageSize вычитается из него
    самим контролом при вычислении крайней позиции ползунка — так же,
    как у нативного скролла в любом другом приложении. }
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
  { Первый настоящий показ — Parent и Visible навигатор уже
    выставил, здесь Canvas-операции внутри BindModel безопасны. }
  if FModel = nil then begin
    BindModel;
  end;
end;

end.
