unit servicetext;

{$mode objfpc}{$H+}{$codepage utf8}

{ Service messages: group created, members joining and leaving, a pin, a
  title or photo change and so on — per the MessageContent list of
  td_api.tl at commit d1085f9. Such a message is drawn not as a bubble but
  as a line in the middle of the history; in the chat list preview — with
  the same text without the name of who did it.

  Service is everything NOT in USER_CONTENT: new kinds from future TDLib
  versions land here by themselves, with a text from the type name. }

interface

uses
  SysUtils, fpjson;

type
  { A user name by id — for "X added Y". nil — names are unknown. }
  TServiceNameOf = function(AUserId: Int64): utf8string;

function IsServiceContent(const AType: utf8string): boolean;

{ Text of a service message. AActor — who did it ('' — without a name, for
  the preview: "Pinned a message"). AIsChannel — a message in a channel
  (the channel itself acts there, and the words differ). '' — not a
  service one. }
function ServiceMessageText(AContent: TJSONObject; const AActor: utf8string;
  AIsChannel: boolean; ANameOf: TServiceNameOf): utf8string;

implementation

uses
  tdreq;

const
  { Content drawn as an ordinary message. }
  USER_CONTENT: array[0..24] of string = (
    'messageText', 'messageRichMessage', 'messageAnimation', 'messageAudio',
    'messageDocument', 'messagePaidMedia', 'messagePhoto', 'messageSticker',
    'messageVideo', 'messageVideoNote', 'messageVoiceNote', 'messageLiveLocation',
    'messageLocation', 'messageVenue', 'messageContact', 'messageAnimatedEmoji',
    'messageDice', 'messageGame', 'messagePoll', 'messageStakeDice', 'messageStory',
    'messageChecklist', 'messageInvoice', 'messageCall', 'messageGroupCall');

  QUOTE_OPEN = #$C2#$AB;    { « }
  QUOTE_CLOSE = #$C2#$BB;   { » }

function IsServiceContent(const AType: utf8string): boolean;
var
  I: integer;
begin
  Result := AType <> '';
  for I := Low(USER_CONTENT) to High(USER_CONTENT) do begin
    if USER_CONTENT[I] = AType then begin
      Exit(False);
    end;
  end;
end;

function Quoted(const AText: utf8string): utf8string;
begin
  Result := QUOTE_OPEN + AText + QUOTE_CLOSE;
end;

{ "X did …" with or without a name: without a name the verb's first letter is a capital. }
function Act(const AActor, AVerb: utf8string): utf8string;
begin
  if AActor <> '' then begin
    Result := AActor + ' ' + AVerb;
  end else if AVerb <> '' then begin
    Result := UpperCase(Copy(AVerb, 1, 1)) + Copy(AVerb, 2, MaxInt);
  end else begin
    Result := '';
  end;
end;

function NameOf(ANameOf: TServiceNameOf; AId: Int64): utf8string;
begin
  Result := '';
  if Assigned(ANameOf) then begin
    Result := ANameOf(AId);
  end;
end;

{ Names separated by commas; if even one is unknown — "N members". }
function Names(ANameOf: TServiceNameOf; AIds: TJSONArray): utf8string;
var
  I: integer;
  N: utf8string;
begin
  Result := '';
  if AIds = nil then begin
    Exit;
  end;
  for I := 0 to AIds.Count - 1 do begin
    N := NameOf(ANameOf, AIds.Items[I].AsInt64);
    if N = '' then begin
      if AIds.Count = 1 then begin
        Exit('a member');
      end;
      Exit(utf8string(IntToStr(AIds.Count)) + ' members');
    end;
    if Result <> '' then begin
      Result := Result + ', ';
    end;
    Result := Result + N;
  end;
end;

function Duration(ASeconds: integer): utf8string;
begin
  if ASeconds >= 86400 * 30 then begin
    Result := utf8string(IntToStr(ASeconds div (86400 * 30))) + ' month(s)';
  end else if ASeconds >= 86400 * 7 then begin
    Result := utf8string(IntToStr(ASeconds div (86400 * 7))) + ' week(s)';
  end else if ASeconds >= 86400 then begin
    Result := utf8string(IntToStr(ASeconds div 86400)) + ' day(s)';
  end else if ASeconds >= 3600 then begin
    Result := utf8string(IntToStr(ASeconds div 3600)) + ' hour(s)';
  end else begin
    Result := utf8string(IntToStr(ASeconds div 60)) + ' minute(s)';
  end;
end;

{ A new kind without its own text: "messageChatSetSomething" -> "Chat set
  something». }
function Humanize(const AType: utf8string): utf8string;
var
  S: string;
  I: integer;
begin
  S := string(AType);
  if Pos('message', S) = 1 then begin
    Delete(S, 1, Length('message'));
  end;
  Result := '';
  for I := 1 to Length(S) do begin
    if (S[I] in ['A'..'Z']) and (Result <> '') then begin
      Result := Result + ' ' + utf8string(LowerCase(S[I]));
    end else begin
      Result := Result + utf8string(S[I]);
    end;
  end;
end;

function ServiceMessageText(AContent: TJSONObject; const AActor: utf8string;
  AIsChannel: boolean; ANameOf: TServiceNameOf): utf8string;
var
  T, Who: utf8string;
  Ids: TJSONArray;
  Id: Int64;
  Secs: integer;
begin
  Result := '';
  if AContent = nil then begin
    Exit;
  end;
  T := JGetStr(AContent, '@type');
  if not IsServiceContent(T) then begin
    Exit;
  end;

  if T = 'messageBasicGroupChatCreate' then begin
    Result := Act(AActor, 'created the group ' + Quoted(JGetStr(AContent, 'title')));
  end else if T = 'messageSupergroupChatCreate' then begin
    if AIsChannel then begin
      Result := 'Channel ' + Quoted(JGetStr(AContent, 'title')) + ' created';
    end else begin
      Result := Act(AActor, 'created the group ' + Quoted(JGetStr(AContent, 'title')));
    end;
  end else if T = 'messageChatChangeTitle' then begin
    if AIsChannel then begin
      Result := 'Channel name changed to ' + Quoted(JGetStr(AContent, 'title'));
    end else begin
      Result := Act(AActor, 'changed the group name to ' + Quoted(JGetStr(AContent, 'title')));
    end;
  end else if T = 'messageChatChangePhoto' then begin
    if AIsChannel then begin
      Result := 'Channel photo updated';
    end else begin
      Result := Act(AActor, 'changed the group photo');
    end;
  end else if T = 'messageChatDeletePhoto' then begin
    if AIsChannel then begin
      Result := 'Channel photo removed';
    end else begin
      Result := Act(AActor, 'removed the group photo');
    end;
  end else if T = 'messageChatAddMembers' then begin
    Ids := JGetArr(AContent, 'member_user_ids');
    Who := Names(ANameOf, Ids);
    if (Ids <> nil) and (Ids.Count = 1) and (Who = AActor) and (AActor <> '') then begin
      Result := Act(AActor, 'joined the group');
    end else begin
      Result := Act(AActor, 'added ' + Who);
    end;
  end else if T = 'messageChatJoinByLink' then begin
    Result := Act(AActor, 'joined the group via invite link');
  end else if T = 'messageChatJoinByRequest' then begin
    Result := Act(AActor, 'was accepted into the group');
  end else if T = 'messageChatDeleteMember' then begin
    Id := JGetInt64(AContent, 'user_id');
    Who := NameOf(ANameOf, Id);
    if (Who = '') or (Who = AActor) then begin
      Result := Act(AActor, 'left the group');
    end else begin
      Result := Act(AActor, 'removed ' + Who);
    end;
  end else if T = 'messageChatUpgradeTo' then begin
    Result := 'The group was upgraded to a supergroup';
  end else if T = 'messageChatUpgradeFrom' then begin
    Result := 'The group ' + Quoted(JGetStr(AContent, 'title')) + ' was upgraded to a supergroup';
  end else if T = 'messageChatOwnerLeft' then begin
    Result := Act(AActor, 'left the group');
  end else if T = 'messageChatOwnerChanged' then begin
    Who := NameOf(ANameOf, JGetInt64(AContent, 'new_owner_user_id'));
    if Who = '' then begin
      Result := 'The group has a new owner';
    end else begin
      Result := Who + ' is the new owner of the group';
    end;
  end else if T = 'messagePinMessage' then begin
    Result := Act(AActor, 'pinned a message');
  end else if T = 'messageScreenshotTaken' then begin
    Result := Act(AActor, 'took a screenshot');
  end else if T = 'messageChatSetBackground' then begin
    Result := Act(AActor, 'changed the chat background');
  end else if T = 'messageChatSetTheme' then begin
    Result := Act(AActor, 'changed the chat theme');
  end else if T = 'messageChatSetMessageAutoDeleteTime' then begin
    Secs := JGetInt(AContent, 'message_auto_delete_time');
    if Secs = 0 then begin
      Result := Act(AActor, 'disabled the auto-delete timer');
    end else begin
      Result := Act(AActor, 'set messages to auto-delete in ' + Duration(Secs));
    end;
  end else if T = 'messageChatBoost' then begin
    Result := Act(AActor, 'boosted the chat');
  end else if T = 'messageForumTopicCreated' then begin
    Result := Act(AActor, 'created the topic ' + Quoted(JGetStr(AContent, 'name')));
  end else if T = 'messageForumTopicEdited' then begin
    Result := Act(AActor, 'changed the topic');
  end else if T = 'messageForumTopicIsClosedToggled' then begin
    if JGetBool(AContent, 'is_closed') then begin
      Result := Act(AActor, 'closed the topic');
    end else begin
      Result := Act(AActor, 'reopened the topic');
    end;
  end else if T = 'messageForumTopicIsHiddenToggled' then begin
    if JGetBool(AContent, 'is_hidden') then begin
      Result := Act(AActor, 'hid the topic');
    end else begin
      Result := Act(AActor, 'unhid the topic');
    end;
  end else if T = 'messageVideoChatScheduled' then begin
    Result := 'Video chat scheduled';
  end else if T = 'messageVideoChatStarted' then begin
    Result := Act(AActor, 'started a video chat');
  end else if T = 'messageVideoChatEnded' then begin
    Result := 'Video chat ended';
  end else if T = 'messageInviteVideoChatParticipants' then begin
    Result := Act(AActor, 'invited ' + Names(ANameOf, JGetArr(AContent, 'user_ids')) +
      ' to the video chat');
  end else if T = 'messageCustomServiceAction' then begin
    Result := JGetStr(AContent, 'text');
  end else if T = 'messageGameScore' then begin
    Result := Act(AActor, 'scored ' + utf8string(IntToStr(JGetInt(AContent, 'score'))));
  end else if (T = 'messagePaymentSuccessful') or (T = 'messagePaymentSuccessfulBot') then begin
    Result := 'Payment completed';
  end else if T = 'messagePaymentRefunded' then begin
    Result := 'Payment refunded';
  end else if T = 'messageGiftedPremium' then begin
    Result := Act(AActor, 'gifted Telegram Premium');
  end else if T = 'messageGiftedStars' then begin
    Result := Act(AActor, 'gifted Telegram Stars');
  end else if (T = 'messageGift') or (T = 'messageUpgradedGift') then begin
    Result := Act(AActor, 'sent a gift');
  end else if T = 'messageContactRegistered' then begin
    Result := Act(AActor, 'joined Telegram');
  end else if T = 'messageUsersShared' then begin
    Result := 'Users shared with the bot';
  end else if T = 'messageChatShared' then begin
    Result := 'Chat shared with the bot';
  end else if T = 'messageBotWriteAccessAllowed' then begin
    Result := 'You allowed this bot to message you';
  end else if T = 'messageWebAppDataSent' then begin
    Result := 'Data from the ' + Quoted(JGetStr(AContent, 'button_text')) +
      ' button was sent to the bot';
  end else if T = 'messageProximityAlertTriggered' then begin
    Result := 'Proximity alert';
  end else if T = 'messageExpiredPhoto' then begin
    Result := 'Photo has expired';
  end else if T = 'messageExpiredVideo' then begin
    Result := 'Video has expired';
  end else if T = 'messageExpiredVideoNote' then begin
    Result := 'Video message has expired';
  end else if T = 'messageExpiredVoiceNote' then begin
    Result := 'Voice message has expired';
  end else if T = 'messageSuggestProfilePhoto' then begin
    Result := Act(AActor, 'suggested a profile photo');
  end else if T = 'messageUnsupported' then begin
    Result := 'This message is not supported yet';
  end else begin
    Result := Humanize(T);
  end;
end;

end.
