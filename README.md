tLogsTfUploader
=================

SourceMod Plugin to upload match logs to <http://logs.tf>


Requirements
=================
* cURL extension, get it from <http://forums.alliedmods.net/showthread.php?t=152216>
* SMJansson extension, get it from <http://forums.alliedmods.net/showthread.php?t=184604>
* Both need to be installed or the plugin won't load


Configuration
=================
Convars
-----------------
* `sm_tlogstfuploader_enable` _Enable/Disable the log upload_
* `sm_tlogstfuploader_apikey` _Use this to set your api key_
* `sm_tlogstfuploader_titleformat` _Use this to set the log title formatting_

Title formatting rules
----------------------
* `%m` _Mapname_
* `%h` _Server name (uses cvar `hostname`)_
* `%r` _Name of the RED team_
* `%b` _Name of the BLU team_

The default is `%h - %r vs %b`, which resolves to something
like this: `My Tiny Dev Server - Hello vs World`