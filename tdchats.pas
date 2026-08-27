unit tdchats;

{$mode objfpc}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, base64, fgl, ExtCtrls, fpjson, jsonparser,
  tdauth, tdcore, tdreq;

type
  TChatKind = (ckUnknown, ckPrivate, ckBasicGroup, ckSupergroup, ckChannel, ckSecret);

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
    Kind:               TChatKind;
    Title:              utf8string;
    LastText:           utf8string;
    LastDate:           Int64;
    LastIsOutgoing:     boolean;
    UnreadCount:        integer;
    UnreadMentionCount: integer;
    IsMarkedAsUnread:   boolean;
    PhotoFileId:        integer;      { small.id, 0 — фото нет }
    PhotoPath:          utf8string;   { локальный путь, если уже скачан }
    Minithumb:          RawByteString;{ сырой JPEG из minithumbnail }
    AvatarRequested:    boolean;      { downloadFile уже отправлен }
  end;

  TChatMap = specialize TFPGMap<Int64, TChatRow>;
  TFileMap = specialize TFPGMap<integer, TChatRow>;

  TTdChatsEvent = procedure(Sender: TObject) of object;

  { TTdChats

    Список не постраничный: TDLib присылает чаты апдейтами, а loadChats
    лишь просит подгрузить ещё и отвечает 404, когда всё загружено.
    Поэтому модель — наблюдатель, а не источник запросов данных. }

  TTdChats = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FAll:   TChatMap;     { все известные чаты по id }
    FByFile: TFileMap;    { file_id аватарки -> чат }
    FRows:  TFPList;      { отображаемые, отсортированные }
    FTimer: TTimer;
    FDirty: boolean;
    FLoading: boolean;
    FAllLoaded: boolean;
    FLoadLimit: integer;
    FOnChanged: TTdChatsEvent;
    FOnLoadingChanged: TTdChatsEvent;

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
    procedure DownloadDone(Sender: TObject; const AResp: TTdResponse);
    procedure ApplyFile(AFile: TJSONObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Clear;
    { Запросить настоящую аватарку. Зовётся фреймом только для видимых
      строк — качать все подряд незачем. Повторные вызовы безвредны. }
    procedure EnsureAvatar(ARow: TChatRow);

    { Попросить TDLib подгрузить следующую порцию. Сами чаты придут
      апдейтами, а не в ответе на этот запрос. }
    procedure LoadMore;

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property Count: integer read GetCount;
    property Rows[AIndex: integer]: TChatRow read GetRow; default;
    property Loading: boolean read FLoading;
    property AllLoaded: boolean read FAllLoaded;
    property LoadLimit: integer read FLoadLimit write FLoadLimit;

    property OnChanged: TTdChatsEvent read FOnChanged write FOnChanged;
    property OnLoadingChanged: TTdChatsEvent read FOnLoadingChanged write FOnLoadingChanged;
  end;

{ Синглтон. Имя отличается от имени юнита сознательно. }
function TdChatList: TTdChats;

function ChatKindToStr(AKind: TChatKind): string;
{ Короткое превью содержимого сообщения для второй строки элемента. }
function MessagePreview(AContent: TJSONObject): utf8string;

implementation

const
  COALESCE_MS = 50;

var
  GChats: TTdChats = nil;

function TdChatList: TTdChats;
begin
  if GChats = nil then begin
    GChats := TTdChats.Create(nil);
  end;
  Result := GChats;
end;

function ChatKindToStr(AKind: TChatKind): string;
begin
  case AKind of
    ckPrivate:    Result := 'личный';
    ckBasicGroup: Result := 'группа';
    ckSupergroup: Result := 'супергруппа';
    ckChannel:    Result := 'канал';
    ckSecret:     Result := 'секретный';
  else
    Result := 'неизвестно';
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
    Result := CaptionOr('Фото');
  end else if T = 'messageVideo' then begin
    Result := CaptionOr('Видео');
  end else if T = 'messageAnimation' then begin
    Result := CaptionOr('GIF');
  end else if T = 'messageDocument' then begin
    Result := CaptionOr('Файл');
  end else if T = 'messageAudio' then begin
    Result := CaptionOr('Аудио');
  end else if T = 'messageVoiceNote' then begin
    Result := CaptionOr('Голосовое сообщение');
  end else if T = 'messageVideoNote' then begin
    Result := 'Видеосообщение';
  end else if T = 'messageSticker' then begin
    Result := 'Стикер';
  end else if T = 'messageAnimatedEmoji' then begin
    Result := JGetStr(AContent, 'emoji');
  end else if T = 'messageLocation' then begin
    Result := 'Геопозиция';
  end else if T = 'messageContact' then begin
    Result := 'Контакт';
  end else if T = 'messagePoll' then begin
    Result := 'Опрос';
  end else if T = 'messageCall' then begin
    Result := 'Звонок';
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

{ ---------------- TTdChats ---------------- }

constructor TTdChats.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAll := TChatMap.Create;
  FAll.Sorted := True;
  FByFile := TFileMap.Create;
  FByFile.Sorted := True;
  FRows := TFPList.Create;
  FLoadLimit := 30;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := COALESCE_MS;
  FTimer.OnTimer := @Rebuild;
  FTimer.Enabled := False;

  TdApp.Subscribe(Self);
end;

destructor TTdChats.Destroy;
begin
  FTimer.Enabled := False;
  TdUnsubscribe(Self);
  Clear;
  FRows.Free;
  FByFile.Free;
  FAll.Free;
  inherited Destroy;
end;

procedure TTdChats.Clear;
var
  I: integer;
begin
  FRows.Clear;
  for I := 0 to FAll.Count - 1 do begin
    FAll.Data[I].Free;
  end;
  FAll.Clear;
  FByFile.Clear;
  FAllLoaded := False;
  FDirty := False;
  FTimer.Enabled := False;
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
  if TdApp.State <> tasReady then begin
    Exit;
  end;
  SetLoading(True);
  TdRequests.SendRequest('loadChats',
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
  TdRequests.SendRequest('downloadFile',
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

procedure TTdChats.LoadChatsDone(Sender: TObject; const AResp: TTdResponse);
begin
  SetLoading(False);
  { 404 — единственный признак того, что список кончился.
    Прочие ошибки временные, повторить можно. }
  if (not AResp.Success) and (AResp.ErrorCode = 404) then begin
    FAllLoaded := True;
  end;
end;

{ ---------------- разбор апдейтов ---------------- }

procedure TTdChats.ApplyPosition(ARow: TChatRow; APos: TJSONObject);
var
  Ord: Int64;
begin
  if (ARow = nil) or (APos = nil) then begin
    Exit;
  end;
  { Интересует только основной список. }
  if JGetStr(JGetObj(APos, 'list'), '@type') <> 'chatListMain' then begin
    Exit;
  end;

  Ord := JGetInt64(APos, 'order');
  if Ord = 0 then begin
    { Схема прямо говорит: order = 0 значит убрать из списка. }
    ARow.InList := False;
    ARow.Order := 0;
    ARow.IsPinned := False;
  end else begin
    ARow.InList := True;
    ARow.Order := Ord;
    ARow.IsPinned := JGetBool(APos, 'is_pinned');
  end;
end;

procedure TTdChats.ApplyPositions(ARow: TChatRow; APositions: TJSONArray);
var
  I: integer;
  P: TJSONObject;
  SawMain: boolean;
begin
  if ARow = nil then begin
    Exit;
  end;
  if APositions = nil then begin
    Exit;
  end;

  SawMain := False;
  for I := 0 to APositions.Count - 1 do begin
    if APositions.Items[I].JSONType <> jtObject then begin
      Continue;
    end;
    P := TJSONObject(APositions.Items[I]);
    if JGetStr(JGetObj(P, 'list'), '@type') = 'chatListMain' then begin
      SawMain := True;
      ApplyPosition(ARow, P);
    end;
  end;

  { Массив positions полный. Если основного списка в нём нет —
    значит чата в нём нет вообще. }
  if not SawMain then begin
    ARow.InList := False;
    ARow.Order := 0;
    ARow.IsPinned := False;
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
begin
  if ARow = nil then begin
    Exit;
  end;
  if AMsg = nil then begin
    ARow.LastText := '';
    ARow.LastDate := 0;
    ARow.LastIsOutgoing := False;
    Exit;
  end;
  ARow.LastText := MessagePreview(JGetObj(AMsg, 'content'));
  ARow.LastDate := JGetInt64(AMsg, 'date');
  ARow.LastIsOutgoing := JGetBool(AMsg, 'is_outgoing');
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
  R.UnreadCount := JGetInt(AChat, 'unread_count');
  R.UnreadMentionCount := JGetInt(AChat, 'unread_mention_count');
  R.IsMarkedAsUnread := JGetBool(AChat, 'is_marked_as_unread');
  ApplyPhoto(R, JGetObj(AChat, 'photo'));
  ApplyLastMessage(R, JGetObj(AChat, 'last_message'));
  ApplyPositions(R, JGetArr(AChat, 'positions'));
end;

procedure TTdChats.TdUpdate(const AJson: utf8string);
var
  S: string;
  Data: TJSONData;
  Obj: TJSONObject;
  T: utf8string;
  R: TChatRow;
begin
  S := string(AJson);

  { Дешёвая отсечка до разбора. Апдейтов приходят тысячи, а нас
    касается меньше десятка видов.
    (Если понадобится, парсинг можно поднять в tdcore и делать один
    раз на всех подписчиков — сейчас каждый парсит сам.) }
  if (Pos('"updateNewChat"', S) = 0) and
     (Pos('"updateChatPosition"', S) = 0) and
     (Pos('"updateChatLastMessage"', S) = 0) and
     (Pos('"updateChatDraftMessage"', S) = 0) and
     (Pos('"updateChatTitle"', S) = 0) and
     (Pos('"updateChatPhoto"', S) = 0) and
     (Pos('"updateChatReadInbox"', S) = 0) and
     (Pos('"updateFile"', S) = 0) then begin
    Exit;
  end;

  Data := nil;
  try
    try
      Data := GetJSON(S);
    except
      Exit;
    end;
    if (Data = nil) or (Data.JSONType <> jtObject) then begin
      Exit;
    end;
    Obj := TJSONObject(Data);
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
    end else if T = 'updateFile' then begin
      ApplyFile(JGetObj(Obj, 'file'));
    end else if T = 'updateChatReadInbox' then begin
      R := Lookup(JGetInt64(Obj, 'chat_id'));
      if R <> nil then begin
        R.UnreadCount := JGetInt(Obj, 'unread_count');
        Touch;
      end;
    end;
  finally
    Data.Free;
  end;
end;

procedure TTdChats.TdStateChanged(AState: TTdAuthState);
begin
  if AState = tasReady then begin
    Clear;
    LoadMore;
  end else if TdIsShuttingState(AState) then begin
    Clear;
    SetLoading(False);
  end;
end;

procedure TTdChats.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Ошибки авторизации модели не касаются. }
end;

initialization

finalization
  FreeAndNil(GChats);

end.
