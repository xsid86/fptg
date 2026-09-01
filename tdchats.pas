unit tdchats;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, base64, fgl, ExtCtrls, fpjson, jsonparser,
  tdauth, tdsession, tdreq;

type
  TChatKind = (ckUnknown, ckPrivate, ckBasicGroup, ckSupergroup, ckChannel, ckSecret);

  { Состояние отправки последнего сообщения. }
  TMsgSendState = (mssDelivered, mssPending, mssFailed);

  { Что показывать справа от времени. Только для исходящих. }
  TChatReceipt = (crNone, crPending, crFailed, crSent, crRead);

  { TChatRow

    Чистые данные, без единой ссылки на LCL. Мини-превью хранится сырыми
    байтами JPEG, а не TBitmap: раскодировкой и кэшем картинок занимается
    фрейм списка. Так модель тестируется без виджетсета и не тащит
    графику в юнит, который её не касается. }

  TChatRow = class
  public
    Id:                 Int64;
    Order:              Int64;
    IsPinned:           boolean;
    InList:             boolean;   { есть позиция в chatListMain }
    InArchive:          boolean;   { есть позиция в chatListArchive }
    ArchiveOrder:       Int64;
    Kind:               TChatKind;
    Title:              utf8string;
    LastText:           utf8string;
    LastDate:           Int64;
    LastIsOutgoing:     boolean;
    LastMessageId:      Int64;
    LastSending:        TMsgSendState;
    LastReadOutbox:     Int64;   { id последнего прочитанного собеседником }
    UnreadCount:        integer;
    UnreadMentionCount: integer;
    IsMarkedAsUnread:   boolean;
    IsMuted:            boolean;   { mute_for > 0 }
    { Сырые настройки уведомлений. Хранятся целиком, потому что
      setChatNotificationSettings принимает объект ЦЕЛИКОМ: собрав
      его из двух полей, мы бы затёрли звук, превью и всё прочее. }
    NotifyRaw:          utf8string;
    UserId:             Int64;        { собеседник, только для личных чатов }
    PhotoFileId:        integer;      { small.id, 0 — фото нет }
    PhotoPath:          utf8string;   { локальный путь, если уже скачан }
    Minithumb:          RawByteString;{ сырой JPEG из minithumbnail }
    AvatarRequested:    boolean;      { downloadFile уже отправлен }
  end;

  { Сводка по архиву для псевдостроки в начале списка. }
  TArchiveInfo = record
    KnownChats:  integer;    { сколько архивных чатов загружено }
    TotalChats:  integer;    { сколько их всего, по данным TDLib }
    UnreadChats: integer;    { чатов с непрочитанным }
    Preview:     utf8string; { названия через запятую }
  end;

  TChatMap = specialize TFPGMap<Int64, TChatRow>;
  TFileMap = specialize TFPGMap<integer, TChatRow>;
  TBotMap = specialize TFPGMap<Int64, boolean>;

  TTdChatsEvent = procedure(Sender: TObject) of object;
  TTdChatsErrorEvent = procedure(Sender: TObject; ACode: integer;
    const AMessage, AAction: utf8string) of object;

  { TTdChats

    Список не постраничный: TDLib присылает чаты апдейтами, а loadChats
    лишь просит подгрузить ещё и отвечает 404, когда всё загружено.
    Поэтому модель — наблюдатель, а не источник запросов данных. }

  TTdChats = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FReq:     TTdRequests;
    FAll:   TChatMap;     { все известные чаты по id }
    FByFile: TFileMap;    { file_id аватарки -> чат }
    { Боты определяются не по чату, а по пользователю: у чата тип
      всегда chatTypePrivate. Апдейты updateUser приходят сами. }
    FBots:   TBotMap;
    FRows:  TFPList;      { отображаемые, отсортированные }
    FTimer: TTimer;
    FDirty: boolean;
    FLoading: boolean;
    FAllLoaded: boolean;
    FLoadLimit: integer;
    FArchive: TArchiveInfo;     { сводка по архиву }
    FMainInfo: TArchiveInfo;    { сводка по основному списку }
    FArchiveRows: TFPList;      { архивные чаты, отсортированные }
    FArchiveLoading: boolean;
    FArchiveAllLoaded: boolean;
    FOnChanged: TTdChatsEvent;
    FOnLoadingChanged: TTdChatsEvent;
    FOnActionError: TTdChatsErrorEvent;

    function GetCount: integer;
    function GetRow(AIndex: integer): TChatRow;
    function Obtain(AId: Int64): TChatRow;
    function Lookup(AId: Int64): TChatRow;

    procedure ApplyChat(AChat: TJSONObject);
    procedure ApplyPositions(ARow: TChatRow; APositions: TJSONArray);
    procedure ApplyPosition(ARow: TChatRow; APos: TJSONObject);
    procedure ApplyPhoto(ARow: TChatRow; APhoto: TJSONObject);
    procedure ApplyLastMessage(ARow: TChatRow; AMsg: TJSONObject);

    procedure Touch;
    procedure Rebuild(Sender: TObject);
    procedure SetLoading(AValue: boolean);
    procedure LoadChatsDone(Sender: TObject; const AResp: TTdResponse);
    procedure ArchiveDone(Sender: TObject; const AResp: TTdResponse);
    function GetArchiveCount: integer;
    function GetArchiveRow(AIndex: integer): TChatRow;
    procedure RebuildArchive;
    procedure ApplyUnreadCount(AObj: TJSONObject);
    procedure ActionDone(Sender: TObject; const AResp: TTdResponse);
    procedure DownloadDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyFile(AFile: TJSONObject);
    procedure ApplyUser(AUser: TJSONObject);
    procedure ApplyNotifySettings(ARow: TChatRow; ASettings: TJSONObject);
  public
    { Модель принадлежит аккаунту. Резолвер передаётся снаружи, а не
      берётся синглтоном: у каждого аккаунта он свой. }
    constructor Create(AOwner: TComponent; const ASession: ITdSession;
      AReq: TTdRequests); reintroduce;
    destructor Destroy; override;

    procedure Clear;
    { --- действия над чатом ---
      Результат приходит апдейтами (updateChatReadInbox, updateChatPosition
      и прочими), которые модель и так разбирает, поэтому список
      обновится сам. Здесь только отправка. }
    { Включить или выключить уведомления. Периоды mute пока не
      поддерживаем: выключение — навсегда. }
    procedure SetMuted(ARow: TChatRow; AMuted: boolean);
    procedure MarkAsRead(ARow: TChatRow);
    procedure MarkAsUnread(ARow: TChatRow);
    procedure SetPinned(ARow: TChatRow; APinned: boolean);
    procedure SetArchived(ARow: TChatRow; AArchived: boolean);
    procedure LeaveChat(ARow: TChatRow);

    { Является ли собеседник ботом. Для не-личных чатов всегда False. }
    function IsBotChat(ARow: TChatRow): boolean;

    { Запросить настоящую аватарку. Зовётся фреймом только для видимых
      строк — качать все подряд незачем. Повторные вызовы безвредны. }
    procedure EnsureAvatar(ARow: TChatRow);

    { Попросить TDLib подгрузить следующую порцию. Сами чаты придут
      апдейтами, а не в ответе на этот запрос. }
    procedure LoadMore;
    { То же для архивного списка: у него свой курсор и свой признак
      «всё загружено». }
    procedure LoadMoreArchive;

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property Count: integer read GetCount;
    property Rows[AIndex: integer]: TChatRow read GetRow; default;
    { Сводки по спискам. Обновляются вместе с перестройкой. }
    property Archive: TArchiveInfo read FArchive;
    property MainInfo: TArchiveInfo read FMainInfo;

    { Архивные чаты — второй список, живёт параллельно основному. }
    property ArchiveCount: integer read GetArchiveCount;
    property ArchiveRows[AIndex: integer]: TChatRow read GetArchiveRow;
    property ArchiveLoading: boolean read FArchiveLoading;
    property ArchiveAllLoaded: boolean read FArchiveAllLoaded;
    property Loading: boolean read FLoading;
    property AllLoaded: boolean read FAllLoaded;
    property LoadLimit: integer read FLoadLimit write FLoadLimit;

    property Session: ITdSession read FSession;
    property OnChanged: TTdChatsEvent read FOnChanged write FOnChanged;
    property OnActionError: TTdChatsErrorEvent read FOnActionError write FOnActionError;
    property OnLoadingChanged: TTdChatsEvent read FOnLoadingChanged write FOnLoadingChanged;
  end;

function ChatKindToStr(AKind: TChatKind): string;
{ Отметка о прочтении. «Прочитано» — когда id последнего сообщения
  не больше last_read_outbox_message_id. }
function ChatReceipt(ARow: TChatRow): TChatReceipt;
{ Короткое превью содержимого сообщения для второй строки элемента. }
function MessagePreview(AContent: TJSONObject): utf8string;

implementation

const
  COALESCE_MS = 50;

function ChatKindToStr(AKind: TChatKind): string;
begin
  case AKind of
    ckPrivate:    Result := 'private';
    ckBasicGroup: Result := 'group';
    ckSupergroup: Result := 'supergroup';
    ckChannel:    Result := 'channel';
    ckSecret:     Result := 'secret';
  else
    Result := 'unknown';
  end;
end;

function ChatReceipt(ARow: TChatRow): TChatReceipt;
begin
  Result := crNone;
  if (ARow = nil) or (not ARow.LastIsOutgoing) or (ARow.LastMessageId = 0) then begin
    Exit;
  end;
  case ARow.LastSending of
    mssPending: Result := crPending;
    mssFailed:  Result := crFailed;
  else
    if ARow.LastMessageId <= ARow.LastReadOutbox then begin
      Result := crRead;
    end else begin
      Result := crSent;
    end;
  end;
end;

function ChatUserId(AType: TJSONObject): Int64;
begin
  Result := 0;
  if (AType <> nil) and (JGetStr(AType, '@type') = 'chatTypePrivate') then begin
    Result := JGetInt64(AType, 'user_id');
  end;
end;

function KindFromType(AType: TJSONObject): TChatKind;
var
  T: utf8string;
begin
  Result := ckUnknown;
  if AType = nil then begin
    Exit;
  end;
  T := JGetStr(AType, '@type');
  if T = 'chatTypePrivate' then begin
    Result := ckPrivate;
  end else if T = 'chatTypeBasicGroup' then begin
    Result := ckBasicGroup;
  end else if T = 'chatTypeSupergroup' then begin
    if JGetBool(AType, 'is_channel') then begin
      Result := ckChannel;
    end else begin
      Result := ckSupergroup;
    end;
  end else if T = 'chatTypeSecret' then begin
    Result := ckSecret;
  end;
end;

function MessagePreview(AContent: TJSONObject): utf8string;
var
  T, Cap: utf8string;

  function CaptionOr(const ADefault: utf8string): utf8string;
  begin
    Cap := JGetStr(JGetObj(AContent, 'caption'), 'text');
    if Cap <> '' then begin
      Result := ADefault + ': ' + Cap;
    end else begin
      Result := ADefault;
    end;
  end;

begin
  Result := '';
  if AContent = nil then begin
    Exit;
  end;
  T := JGetStr(AContent, '@type');

  if T = 'messageText' then begin
    Result := JGetStr(JGetObj(AContent, 'text'), 'text');
  end else if T = 'messagePhoto' then begin
    Result := CaptionOr('Photo');
  end else if T = 'messageVideo' then begin
    Result := CaptionOr('Video');
  end else if T = 'messageAnimation' then begin
    Result := CaptionOr('GIF');
  end else if T = 'messageDocument' then begin
    Result := CaptionOr('File');
  end else if T = 'messageAudio' then begin
    Result := CaptionOr('Audio');
  end else if T = 'messageVoiceNote' then begin
    Result := CaptionOr('Voice message');
  end else if T = 'messageVideoNote' then begin
    Result := 'Video message';
  end else if T = 'messageSticker' then begin
    Result := 'Sticker';
  end else if T = 'messageAnimatedEmoji' then begin
    Result := JGetStr(AContent, 'emoji');
  end else if T = 'messageLocation' then begin
    Result := 'Location';
  end else if T = 'messageContact' then begin
    Result := 'Contact';
  end else if T = 'messagePoll' then begin
    Result := 'Poll';
  end else if T = 'messageCall' then begin
    Result := 'Call';
  end else begin
    { Неизвестный вид — показываем сам тип, это полезнее пустоты. }
    Result := T;
  end;

  { Перевод строки в однострочном превью недопустим. }
  Result := utf8string(StringReplace(StringReplace(string(Result),
    #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]));
end;

{ ---------------- сортировка ---------------- }

function CompareRows(P1, P2: Pointer): integer;
var
  A, B: TChatRow;
begin
  A := TChatRow(P1);
  B := TChatRow(P2);
  { Схема требует убывания по паре (order, chat.id). }
  if A.Order > B.Order then begin
    Result := -1;
  end else if A.Order < B.Order then begin
    Result := 1;
  end else if A.Id > B.Id then begin
    Result := -1;
  end else if A.Id < B.Id then begin
    Result := 1;
  end else begin
    Result := 0;
  end;
end;

function CompareArchive(P1, P2: Pointer): integer;
var
  A, B: TChatRow;
begin
  A := TChatRow(P1);
  B := TChatRow(P2);
  if A.ArchiveOrder > B.ArchiveOrder then begin
    Result := -1;
  end else if A.ArchiveOrder < B.ArchiveOrder then begin
    Result := 1;
  end else if A.Id > B.Id then begin
    Result := -1;
  end else if A.Id < B.Id then begin
    Result := 1;
  end else begin
    Result := 0;
  end;
end;

{ ---------------- TTdChats ---------------- }

constructor TTdChats.Create(AOwner: TComponent; const ASession: ITdSession;
  AReq: TTdRequests);
begin
  inherited Create(AOwner);
  FSession := ASession;
  FReq := AReq;
  FAll := TChatMap.Create;
  FAll.Sorted := True;
  FByFile := TFileMap.Create;
  FByFile.Sorted := True;
  FBots := TBotMap.Create;
  FBots.Sorted := True;
  FRows := TFPList.Create;
  FArchiveRows := TFPList.Create;
  FLoadLimit := 30;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := COALESCE_MS;
  FTimer.OnTimer := @Rebuild;
  FTimer.Enabled := False;

  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdChats.Destroy;
begin
  FTimer.Enabled := False;
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  Clear;
  FRows.Free;
  FArchiveRows.Free;
  FBots.Free;
  FByFile.Free;
  FAll.Free;
  inherited Destroy;
end;

procedure TTdChats.Clear;
var
  I: integer;
begin
  FRows.Clear;
  FArchiveRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    FAll.Data[I].Free;
  end;
  FAll.Clear;
  FByFile.Clear;
  FBots.Clear;
  FAllLoaded := False;
  FArchiveLoading := False;
  FArchiveAllLoaded := False;
  FillChar(FArchive, SizeOf(FArchive), 0);
  FArchive.Preview := '';
  FillChar(FMainInfo, SizeOf(FMainInfo), 0);
  FMainInfo.Preview := '';
  FDirty := False;
  FTimer.Enabled := False;
end;

function TTdChats.GetArchiveCount: integer;
begin
  Result := FArchiveRows.Count;
end;

function TTdChats.GetArchiveRow(AIndex: integer): TChatRow;
begin
  if (AIndex < 0) or (AIndex >= FArchiveRows.Count) then begin
    Result := nil;
  end else begin
    Result := TChatRow(FArchiveRows[AIndex]);
  end;
end;

function TTdChats.GetCount: integer;
begin
  Result := FRows.Count;
end;

function TTdChats.GetRow(AIndex: integer): TChatRow;
begin
  if (AIndex < 0) or (AIndex >= FRows.Count) then begin
    Result := nil;
  end else begin
    Result := TChatRow(FRows[AIndex]);
  end;
end;

function TTdChats.Lookup(AId: Int64): TChatRow;
var
  Idx: integer;
begin
  Result := nil;
  Idx := FAll.IndexOf(AId);
  if Idx >= 0 then begin
    Result := FAll.Data[Idx];
  end;
end;

function TTdChats.Obtain(AId: Int64): TChatRow;
begin
  Result := Lookup(AId);
  if Result = nil then begin
    Result := TChatRow.Create;
    Result.Id := AId;
    FAll.Add(AId, Result);
  end;
end;

procedure TTdChats.Touch;
begin
  FDirty := True;
  FTimer.Enabled := True;
end;

procedure TTdChats.Rebuild(Sender: TObject);
var
  I: integer;
  R: TChatRow;
begin
  FTimer.Enabled := False;
  if not FDirty then begin
    Exit;
  end;
  FDirty := False;

  { Полная пересборка вместо инкрементальных вставок: для нескольких
    тысяч указателей сортировка занимает доли миллисекунды, а кода
    и поводов для ошибок — на порядок меньше. }
  FRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    R := FAll.Data[I];
    if R.InList and (R.Order <> 0) then begin
      FRows.Add(R);
    end;
  end;
  FRows.Sort(@CompareRows);
  RebuildArchive;

  if Assigned(FOnChanged) then begin
    FOnChanged(Self);
  end;
end;

procedure TTdChats.SetLoading(AValue: boolean);
begin
  if FLoading = AValue then begin
    Exit;
  end;
  FLoading := AValue;
  if Assigned(FOnLoadingChanged) then begin
    FOnLoadingChanged(Self);
  end;
end;

procedure TTdChats.LoadMore;
begin
  if FLoading or FAllLoaded then begin
    Exit;
  end;
  if (FSession = nil) or (FSession.State <> tasReady) then begin
    Exit;
  end;
  SetLoading(True);
  if FReq = nil then begin
    SetLoading(False);
    Exit;
  end;
  FReq.SendRequest('loadChats',
    '"chat_list":{"@type":"chatListMain"},"limit":' + utf8string(IntToStr(FLoadLimit)),
    @LoadChatsDone);
end;

procedure TTdChats.EnsureAvatar(ARow: TChatRow);
begin
  if ARow = nil then begin
    Exit;
  end;
  { Нечего качать, уже скачано или уже запрошено. }
  if (ARow.PhotoFileId = 0) or (ARow.PhotoPath <> '') or ARow.AvatarRequested then begin
    Exit;
  end;
  ARow.AvatarRequested := True;
  if FByFile.IndexOf(ARow.PhotoFileId) < 0 then begin
    FByFile.Add(ARow.PhotoFileId, ARow);
  end;
  { priority 1 — низший: аватарки не должны мешать загрузке сообщений.
    synchronous=false, результат придёт апдейтом updateFile. }
  if FReq = nil then begin
    ARow.AvatarRequested := False;
    Exit;
  end;
  FReq.SendRequest('downloadFile',
    '"file_id":' + utf8string(IntToStr(ARow.PhotoFileId)) +
    ',"priority":1,"offset":0,"limit":0,"synchronous":false',
    @DownloadDone, ARow.PhotoFileId);
end;

procedure TTdChats.DownloadDone(Sender: TObject; const AResp: TTdResponse);
var
  Idx: integer;
begin
  { Ответ на downloadFile — это объект file. Если файл уже был на диске,
    он придёт прямо здесь, и updateFile может не прийти вовсе. }
  if AResp.Success then begin
    ApplyFile(AResp.Obj);
    Exit;
  end;
  { Ошибка — снимаем пометку, чтобы можно было попробовать снова. }
  Idx := FByFile.IndexOf(integer(AResp.Tag));
  if Idx >= 0 then begin
    FByFile.Data[Idx].AvatarRequested := False;
  end;
end;

procedure TTdChats.ApplyFile(AFile: TJSONObject);
var
  Idx, FileId: integer;
  Local: TJSONObject;
  R: TChatRow;
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
  if R.PhotoPath = Path then begin
    Exit;
  end;
  R.PhotoPath := Path;
  Touch;
end;

procedure TTdChats.LoadMoreArchive;
begin
  if FArchiveLoading or FArchiveAllLoaded or (FReq = nil) then begin
    Exit;
  end;
  if (FSession = nil) or (FSession.State <> tasReady) then begin
    Exit;
  end;
  FArchiveLoading := True;
  FReq.SendRequest('loadChats',
    '"chat_list":{"@type":"chatListArchive"},"limit":' +
    utf8string(IntToStr(FLoadLimit)), @ArchiveDone);
end;

procedure TTdChats.ArchiveDone(Sender: TObject; const AResp: TTdResponse);
begin
  FArchiveLoading := False;
  { 404 — единственный признак того, что архив кончился. }
  if (not AResp.Success) and (AResp.ErrorCode = 404) then begin
    FArchiveAllLoaded := True;
    Touch;
  end;
end;

procedure TTdChats.ApplyUnreadCount(AObj: TJSONObject);
var
  Kind: utf8string;
begin
  if AObj = nil then begin
    Exit;
  end;
  Kind := JGetStr(JGetObj(AObj, 'chat_list'), '@type');
  if Kind = 'chatListArchive' then begin
    FArchive.TotalChats := JGetInt(AObj, 'total_count');
    FArchive.UnreadChats := JGetInt(AObj, 'unread_count');
  end else if Kind = 'chatListMain' then begin
    FMainInfo.TotalChats := JGetInt(AObj, 'total_count');
    FMainInfo.UnreadChats := JGetInt(AObj, 'unread_count');
  end else begin
    Exit;
  end;
  Touch;
end;

function PreviewOf(AList: TFPList): utf8string;
var
  I: integer;
begin
  { Названия верхних чатов через запятую, как в Telegram.
    Обрываем по длине, а не по количеству: названия разной длины. }
  Result := '';
  for I := 0 to AList.Count - 1 do begin
    if Length(Result) > 60 then begin
      Break;
    end;
    if Result <> '' then begin
      Result := Result + ', ';
    end;
    Result := Result + TChatRow(AList[I]).Title;
  end;
end;

procedure TTdChats.RebuildArchive;
var
  I: integer;
  R: TChatRow;
begin
  FArchiveRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    R := FAll.Data[I];
    if R.InArchive and (R.ArchiveOrder <> 0) then begin
      FArchiveRows.Add(R);
    end;
  end;
  FArchiveRows.Sort(@CompareArchive);

  FArchive.KnownChats := FArchiveRows.Count;
  FArchive.Preview := PreviewOf(FArchiveRows);

  FMainInfo.KnownChats := FRows.Count;
  FMainInfo.Preview := PreviewOf(FRows);
end;

procedure TTdChats.LoadChatsDone(Sender: TObject; const AResp: TTdResponse);
begin
  SetLoading(False);
  { 404 — единственный признак того, что список кончился.
    Прочие ошибки временные, повторить можно. }
  if (not AResp.Success) and (AResp.ErrorCode = 404) then begin
    FAllLoaded := True;
  end;
end;

procedure TTdChats.ApplyNotifySettings(ARow: TChatRow; ASettings: TJSONObject);
begin
  if (ARow = nil) or (ASettings = nil) then begin
    Exit;
  end;
  { use_default_mute_for означает «как настроено для всей категории».
    Значение категории приходит отдельным updateScopeNotificationSettings;
    пока считаем такие чаты незаглушёнными — по умолчанию так и есть. }
  if JGetBool(ASettings, 'use_default_mute_for') then begin
    ARow.IsMuted := False;
  end else begin
    ARow.IsMuted := JGetInt(ASettings, 'mute_for') > 0;
  end;
  ARow.NotifyRaw := utf8string(ASettings.AsJSON);
end;

procedure TTdChats.ApplyUser(AUser: TJSONObject);
var
  Id: Int64;
  IsBot, Was: boolean;
  Idx: integer;
begin
  if AUser = nil then begin
    Exit;
  end;
  Id := JGetInt64(AUser, 'id');
  if Id = 0 then begin
    Exit;
  end;
  IsBot := JGetStr(JGetObj(AUser, 'type'), '@type') = 'userTypeBot';

  Idx := FBots.IndexOf(Id);
  if Idx >= 0 then begin
    if FBots.Data[Idx] = IsBot then begin
      Exit;
    end;
    Was := FBots.Data[Idx];
    FBots.Data[Idx] := IsBot;
  end else begin
    Was := False;
    FBots.Add(Id, IsBot);
  end;

  { updateUser приходит на КАЖДОГО известного пользователя, а их
    тысячи. Перерисовку просим только когда значок мог измениться,
    то есть когда речь о боте. }
  if IsBot or Was then begin
    Touch;
  end;
end;

function TTdChats.IsBotChat(ARow: TChatRow): boolean;
var
  Idx: integer;
begin
  Result := False;
  if (ARow = nil) or (ARow.Kind <> ckPrivate) or (ARow.UserId = 0) then begin
    Exit;
  end;
  Idx := FBots.IndexOf(ARow.UserId);
  if Idx >= 0 then begin
    Result := FBots.Data[Idx];
  end;
end;

{ ---------------- действия над чатом ---------------- }

procedure TTdChats.ActionDone(Sender: TObject; const AResp: TTdResponse);
begin
  if AResp.Success then begin
    Exit;
  end;
  if Assigned(FOnActionError) then begin
    FOnActionError(Self, AResp.ErrorCode, AResp.ErrorMessage, '');
  end;
end;

procedure TTdChats.SetMuted(ARow: TChatRow; AMuted: boolean);
const
  { Схема: чат, заглушённый больше чем на 366 дней, считается
    заглушённым навсегда. Отдельной константы в API нет. }
  MUTE_FOREVER = 367 * 24 * 60 * 60;
var
  Data: TJSONData;
  Obj: TJSONObject;
  Body: utf8string;
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;

  Obj := nil;
  Data := nil;
  try
    { Берём существующие настройки и меняем только заглушение —
      остальные поля должны уцелеть. }
    if ARow.NotifyRaw <> '' then begin
      try
        Data := GetJSON(string(ARow.NotifyRaw));
        if (Data <> nil) and (Data.JSONType = jtObject) then begin
          Obj := TJSONObject(Data);
        end;
      except
        FreeAndNil(Data);
      end;
    end;

    if Obj = nil then begin
      Data := TJSONObject.Create;
      Obj := TJSONObject(Data);
    end;

    Obj.Strings['@type'] := 'chatNotificationSettings';
    Obj.Booleans['use_default_mute_for'] := False;
    if AMuted then begin
      Obj.Integers['mute_for'] := MUTE_FOREVER;
    end else begin
      Obj.Integers['mute_for'] := 0;
    end;

    Body := '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
            ',"notification_settings":' + utf8string(Obj.AsJSON);
  finally
    Data.Free;
  end;

  FReq.SendRequest('setChatNotificationSettings', Body, @ActionDone);
end;

procedure TTdChats.MarkAsRead(ARow: TChatRow);
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;

  if ARow.LastMessageId <> 0 then begin
    { force_read = true: чат закрыт, но пометить прочитанным надо.
      source указываем явно — из списка чатов. }
    FReq.SendRequest('viewMessages',
      '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
      ',"message_ids":[' + utf8string(IntToStr(ARow.LastMessageId)) + ']' +
      ',"source":{"@type":"messageSourceChatList"},"force_read":true',
      @ActionDone);
  end;

  { Чат мог быть помечен непрочитанным вручную — снимаем и это,
    иначе точка останется висеть. }
  if ARow.IsMarkedAsUnread then begin
    FReq.SendRequest('toggleChatIsMarkedAsUnread',
      '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
      ',"is_marked_as_unread":false', @ActionDone);
  end;
end;

procedure TTdChats.MarkAsUnread(ARow: TChatRow);
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  FReq.SendRequest('toggleChatIsMarkedAsUnread',
    '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
    ',"is_marked_as_unread":true', @ActionDone);
end;

procedure TTdChats.SetPinned(ARow: TChatRow; APinned: boolean);
var
  Flag: utf8string;
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  if APinned then begin
    Flag := 'true';
  end else begin
    Flag := 'false';
  end;
  { Внимание: у toggleChatIsPinned chat_list идёт ПЕРВЫМ параметром,
    закрепление относится к конкретному списку. }
  FReq.SendRequest('toggleChatIsPinned',
    '"chat_list":{"@type":"chatListMain"},"chat_id":' +
    utf8string(IntToStr(ARow.Id)) + ',"is_pinned":' + Flag, @ActionDone);
end;

procedure TTdChats.SetArchived(ARow: TChatRow; AArchived: boolean);
var
  List: utf8string;
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  if AArchived then begin
    List := 'chatListArchive';
  end else begin
    List := 'chatListMain';
  end;
  FReq.SendRequest('addChatToList',
    '"chat_id":' + utf8string(IntToStr(ARow.Id)) +
    ',"chat_list":{"@type":"' + List + '"}', @ActionDone);
end;

procedure TTdChats.LeaveChat(ARow: TChatRow);
begin
  if (ARow = nil) or (FReq = nil) then begin
    Exit;
  end;
  FReq.SendRequest('leaveChat',
    '"chat_id":' + utf8string(IntToStr(ARow.Id)), @ActionDone);
end;

{ ---------------- разбор апдейтов ---------------- }

procedure TTdChats.ApplyPosition(ARow: TChatRow; APos: TJSONObject);
var
  Ord: Int64;
  Kind: utf8string;
begin
  if (ARow = nil) or (APos = nil) then begin
    Exit;
  end;

  Kind := JGetStr(JGetObj(APos, 'list'), '@type');
  Ord := JGetInt64(APos, 'order');

  { Схема прямо говорит: order = 0 значит убрать из списка. }
  if Kind = 'chatListMain' then begin
    if Ord = 0 then begin
      ARow.InList := False;
      ARow.Order := 0;
      ARow.IsPinned := False;
    end else begin
      ARow.InList := True;
      ARow.Order := Ord;
      ARow.IsPinned := JGetBool(APos, 'is_pinned');
    end;
  end else if Kind = 'chatListArchive' then begin
    if Ord = 0 then begin
      ARow.InArchive := False;
      ARow.ArchiveOrder := 0;
    end else begin
      ARow.InArchive := True;
      ARow.ArchiveOrder := Ord;
    end;
  end;
  { Папки (chatListFolder) пока не поддерживаем. }
end;

procedure TTdChats.ApplyPositions(ARow: TChatRow; APositions: TJSONArray);
var
  I: integer;
  P: TJSONObject;
  SawMain, SawArchive: boolean;
  Kind: utf8string;
begin
  if ARow = nil then begin
    Exit;
  end;
  if APositions = nil then begin
    Exit;
  end;

  SawMain := False;
  SawArchive := False;
  for I := 0 to APositions.Count - 1 do begin
    if APositions.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    P := TJSONObject(APositions.Items[I]);
    Kind := JGetStr(JGetObj(P, 'list'), '@type');
    if Kind = 'chatListMain' then begin
      SawMain := True;
      ApplyPosition(ARow, P);
    end else if Kind = 'chatListArchive' then begin
      SawArchive := True;
      ApplyPosition(ARow, P);
    end;
  end;

  { Массив positions полный: отсутствие списка означает, что чата
    в нём нет вообще. }
  if not SawMain then begin
    ARow.InList := False;
    ARow.Order := 0;
    ARow.IsPinned := False;
  end;
  if not SawArchive then begin
    ARow.InArchive := False;
    ARow.ArchiveOrder := 0;
  end;
end;

procedure TTdChats.ApplyPhoto(ARow: TChatRow; APhoto: TJSONObject);
var
  Small: TJSONObject;
  B64: utf8string;
begin
  if ARow = nil then begin
    Exit;
  end;
  if APhoto = nil then begin
    ARow.PhotoFileId := 0;
    ARow.PhotoPath := '';
    ARow.Minithumb := '';
    ARow.AvatarRequested := False;
    Exit;
  end;

  Small := JGetObj(APhoto, 'small');
  if ARow.PhotoFileId <> JGetInt(Small, 'id') then begin
    { Фото сменилось — прежний запрос уже не про этот файл. }
    ARow.AvatarRequested := False;
  end;
  ARow.PhotoFileId := JGetInt(Small, 'id');
  ARow.PhotoPath := JGetStr(JGetObj(Small, 'local'), 'path');

  { minithumbnail приходит прямо в апдейте: base64 крошечного JPEG.
    Ничего скачивать не надо — картинку можно показать сразу. }
  B64 := JGetStr(JGetObj(APhoto, 'minithumbnail'), 'data');
  if B64 <> '' then begin
    try
      ARow.Minithumb := DecodeStringBase64(string(B64));
    except
      ARow.Minithumb := '';
    end;
  end;
end;

procedure TTdChats.ApplyLastMessage(ARow: TChatRow; AMsg: TJSONObject);
var
  St: utf8string;
begin
  if ARow = nil then begin
    Exit;
  end;
  if AMsg = nil then begin
    ARow.LastText := '';
    ARow.LastDate := 0;
    ARow.LastIsOutgoing := False;
    ARow.LastMessageId := 0;
    ARow.LastSending := mssDelivered;
    Exit;
  end;
  ARow.LastText := MessagePreview(JGetObj(AMsg, 'content'));
  ARow.LastDate := JGetInt64(AMsg, 'date');
  ARow.LastIsOutgoing := JGetBool(AMsg, 'is_outgoing');
  ARow.LastMessageId := JGetInt64(AMsg, 'id');

  { sending_state отсутствует у уже отправленных сообщений. }
  St := JGetStr(JGetObj(AMsg, 'sending_state'), '@type');
  if St = 'messageSendingStatePending' then begin
    ARow.LastSending := mssPending;
  end else if St = 'messageSendingStateFailed' then begin
    ARow.LastSending := mssFailed;
  end else begin
    ARow.LastSending := mssDelivered;
  end;
end;

procedure TTdChats.ApplyChat(AChat: TJSONObject);
var
  R: TChatRow;
begin
  if AChat = nil then begin
    Exit;
  end;
  R := Obtain(JGetInt64(AChat, 'id'));
  R.Title := JGetStr(AChat, 'title');
  R.Kind := KindFromType(JGetObj(AChat, 'type'));
  R.UserId := ChatUserId(JGetObj(AChat, 'type'));
  R.UnreadCount := JGetInt(AChat, 'unread_count');
  R.UnreadMentionCount := JGetInt(AChat, 'unread_mention_count');
  R.IsMarkedAsUnread := JGetBool(AChat, 'is_marked_as_unread');
  R.LastReadOutbox := JGetInt64(AChat, 'last_read_outbox_message_id');
  ApplyNotifySettings(R, JGetObj(AChat, 'notification_settings'));
  ApplyPhoto(R, JGetObj(AChat, 'photo'));
  ApplyLastMessage(R, JGetObj(AChat, 'last_message'));
  ApplyPositions(R, JGetArr(AChat, 'positions'));
end;

procedure TTdChats.TdUpdate(const AJson: utf8string; AData: TJSONObject);
var
  Obj: TJSONObject;
  T: utf8string;
  R: TChatRow;
begin
  { AData уже разобран приёмным потоком (tdrecv.pas) — раньше здесь
    был свой GetJSON за отдельной дешёвой Pos-отсечкой по сырой
    строке; теперь парсинг один на всех подписчиков, отсечка не нужна. }
  if AData = nil then begin
    Exit;
  end;
  Obj := AData;
  T := JGetStr(Obj, '@type');

  if T = 'updateNewChat' then begin
      ApplyChat(JGetObj(Obj, 'chat'));
      Touch;
    end else if T = 'updateChatPosition' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyPosition(R, JGetObj(Obj, 'position'));
        Touch;
      end;
    end else if T = 'updateChatLastMessage' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyLastMessage(R, JGetObj(Obj, 'last_message'));
        ApplyPositions(R, JGetArr(Obj, 'positions'));
        Touch;
      end;
    end else if T = 'updateChatDraftMessage' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyPositions(R, JGetArr(Obj, 'positions'));
        Touch;
      end;
    end else if T = 'updateChatTitle' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        R.Title := JGetStr(Obj, 'title');
        Touch;
      end;
    end else if T = 'updateChatPhoto' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyPhoto(R, JGetObj(Obj, 'photo'));
        Touch;
      end;
    end else if T = 'updateChatNotificationSettings' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        ApplyNotifySettings(R, JGetObj(Obj, 'notification_settings'));
        Touch;
      end;
    end else if T = 'updateUser' then begin
      ApplyUser(JGetObj(Obj, 'user'));
    end else if T = 'updateUnreadChatCount' then begin
      ApplyUnreadCount(Obj);
    end else if T = 'updateFile' then begin
      ApplyFile(JGetObj(Obj, 'file'));
    end else if T = 'updateChatReadOutbox' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        R.LastReadOutbox := JGetInt64(Obj, 'last_read_outbox_message_id');
        Touch;
      end;
    end else if T = 'updateChatReadInbox' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        R.UnreadCount := JGetInt(Obj, 'unread_count');
        Touch;
      end;
    end;
end;

procedure TTdChats.TdStateChanged(AState: TTdAuthState);
begin
  if AState = tasReady then begin
    Clear;
    LoadMore;
    LoadMoreArchive;
  end else if TdIsShuttingState(AState) then begin
    Clear;
    SetLoading(False);
  end;
end;

procedure TTdChats.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Ошибки авторизации модели не касаются. }
end;

end.
