unit tdattachbots;

{$mode objfpc}{$H+}

{ Attachment menu bots ("Wallet" = @wallet and the like): paperclip menu
  items after the built-in ones. The whole list arrives as an
  updateAttachmentMenuBots update (td_api.tl at commit d1085f9:
  attachmentMenuBot — bot_user_id, supports_*_chats,
  show_in_attachment_menu, name, ...); there is no "get the list" method,
  so the model keeps the latest. A bot opens as a Mini App — openWebApp
  with an empty url (as td_api.tl prescribes for an attachment menu bot).
  Icons (default_icon) are not downloaded: the menu uses the common bot
  icon. }

interface

uses
  Classes, SysUtils, fpjson,
  tdauth, tdsession;

type
  TAttachBot = record
    UserId: Int64;
    Name: utf8string;
    SelfChat: boolean;
    UserChats: boolean;
    BotChats: boolean;
    GroupChats: boolean;
    ChannelChats: boolean;
  end;

  TTdAttachBots = class(TComponent, ITdUpdateListener, ITdStateListener)
  private
    FSession: ITdSession;
    FBots: array of TAttachBot;
    function GetCount: integer;
    function GetBot(AIndex: integer): TAttachBot;
  public
    constructor Create(AOwner: TComponent; const ASession: ITdSession); reintroduce;
    destructor Destroy; override;

    { ITdUpdateListener }
    procedure TdUpdate(const AJson: utf8string; AData: TJSONObject);
    { ITdStateListener }
    procedure TdStateChanged(AState: TTdAuthState);
    procedure TdError(ACode: integer; const AMessage, AContext: utf8string);

    property Count: integer read GetCount;
    property Bots[AIndex: integer]: TAttachBot read GetBot; default;
  end;

implementation

uses
  tdreq;

constructor TTdAttachBots.Create(AOwner: TComponent; const ASession: ITdSession);
begin
  inherited Create(AOwner);
  FSession := ASession;
  if FSession <> nil then begin
    FSession.Subscribe(Self);
  end;
end;

destructor TTdAttachBots.Destroy;
begin
  TdSessionUnsubscribe(FSession, Self);
  FSession := nil;
  inherited Destroy;
end;

function TTdAttachBots.GetCount: integer;
begin
  Result := Length(FBots);
end;

function TTdAttachBots.GetBot(AIndex: integer): TAttachBot;
begin
  Result := FBots[AIndex];
end;

procedure TTdAttachBots.TdUpdate(const AJson: utf8string; AData: TJSONObject);
var
  Arr: TJSONArray;
  B: TJSONObject;
  I, N: integer;
begin
  if (AData = nil) or (JGetStr(AData, '@type') <> 'updateAttachmentMenuBots') then begin
    Exit;
  end;
  Arr := JGetArr(AData, 'bots');
  SetLength(FBots, 0);
  if Arr = nil then begin
    Exit;
  end;
  N := 0;
  for I := 0 to Arr.Count - 1 do begin
    if not (Arr.Items[I] is TJSONObject) then begin
      Continue;
    end;
    B := TJSONObject(Arr.Items[I]);
    { Only those the user keeps in the attachment menu. }
    if not (JGetBool(B, 'is_added') and JGetBool(B, 'show_in_attachment_menu')) then begin
      Continue;
    end;
    SetLength(FBots, N + 1);
    FBots[N].UserId := JGetInt64(B, 'bot_user_id');
    FBots[N].Name := JGetStr(B, 'name');
    FBots[N].SelfChat := JGetBool(B, 'supports_self_chat');
    FBots[N].UserChats := JGetBool(B, 'supports_user_chats');
    FBots[N].BotChats := JGetBool(B, 'supports_bot_chats');
    FBots[N].GroupChats := JGetBool(B, 'supports_group_chats');
    FBots[N].ChannelChats := JGetBool(B, 'supports_channel_chats');
    Inc(N);
  end;
end;

procedure TTdAttachBots.TdStateChanged(AState: TTdAuthState);
begin
  if TdIsShuttingState(AState) then begin
    SetLength(FBots, 0);
  end;
end;

procedure TTdAttachBots.TdError(ACode: integer; const AMessage, AContext: utf8string);
begin
  { Authorization errors do not concern this model. }
end;

end.
