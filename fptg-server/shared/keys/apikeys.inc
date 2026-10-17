{ Ключи Telegram API, вшитые в сборку сервера (tdcore.LoadConfig): ими
  сервер входит, пока в conf.dat свои не заданы.

  Это ПУБЛИЧНАЯ копия — пустая: собранный из открытого репозитория
  сервер просит api_id и api_hash с my.telegram.org. Релизная сборка
  берёт ../fptg-server-premium/apikeys.inc (папка не в git): путь
  включений проектов сервера (IncludeFiles в .lpi) ищет её раньше этой.
  Там тот же текст, только с настоящими значениями. }
const
  BUILTIN_API_ID: integer = 0;
  BUILTIN_API_HASH: string = '';
