{ Telegram API keys built into the server (tdcore.LoadConfig): the server
  signs in with them until its own are set in conf.dat.

  This is the PUBLIC copy — empty: a server built from the open repository
  asks for api_id and api_hash from my.telegram.org. A release build takes
  ../fptg-server-premium/apikeys.inc (the folder is not in git): the
  include path of the server projects (IncludeFiles in the .lpi) finds it
  before this one. It has the same text, only with real values. }
const
  BUILTIN_API_ID: integer = 0;
  BUILTIN_API_HASH: string = '';
