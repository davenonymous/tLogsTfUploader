#pragma semicolon 1
#include <sourcemod>
#include <curl>
#include <smjansson>
#include <colors>

#define LOGS_TF_UPLOAD_URL	"http://logs.tf/upload"

#define VERSION 		"0.0.1"

#define TEAM_RED	0
#define TEAM_BLUE	1


// Cvars.
new Handle:g_hCvarEnabled = INVALID_HANDLE;
new bool:g_bEnabled;

new Handle:g_hCvarApiKey = INVALID_HANDLE;
new String:g_sApiKey[64];

new Handle:g_hCvarTitleFmt = INVALID_HANDLE;
new String:g_sTitleFmt[64];

// These are not ours, but we still want to track it
new Handle:g_hCvarLogsDir = INVALID_HANDLE;
new String:g_sLogsDir[PLATFORM_MAX_PATH];

new Handle:g_hCvarHostname = INVALID_HANDLE;
new String:g_sHostname[PLATFORM_MAX_PATH];


// This variable will hold the "interesting" logfile
new String:g_sActiveLogFile[PLATFORM_MAX_PATH];

// Some live data we want/need to track
new String:g_sCurrentMap[PLATFORM_MAX_PATH];
new String:g_sTeamName[2][MAX_NAME_LENGTH];
new bool:g_bReady[2];

// Response data we get from the logs.tf server
new String:g_sReceived[8192];

// Only trigger an upload if the game started because
// both teams readied up. We need to track that and do so
// in this variable.
new bool:g_bWatchGameOverEvent = false;


public Plugin:myinfo = {
	name 		= "tLogsTfUploader",
	author 		= "Thrawn",
	description = "Uploads match logs to logs.tf",
	version 	= VERSION,
};

public OnPluginStart() {
	// Version cvar.
	CreateConVar("sm_tlogstfuploader_version", VERSION, "tLogsTfUploader", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	// Create a cvar to enable/disable the plugin
	g_hCvarEnabled = CreateConVar("sm_tlogstfuploader_enable", "1", "Enable tLogsTfUploader", FCVAR_PLUGIN, true, 0.0, true, 1.0);
	HookConVarChange(g_hCvarEnabled, Cvar_Changed);

	// Create a cvar for the api key
	g_hCvarApiKey = CreateConVar("sm_tlogstfuploader_apikey", "", "API Key for logs.tf", FCVAR_PLUGIN|FCVAR_PROTECTED);
	HookConVarChange(g_hCvarApiKey, Cvar_Changed);

	// And one for the title format
	g_hCvarTitleFmt = CreateConVar("sm_tlogstfuploader_titleformat", "%h - %r vs %b", "Title Format", FCVAR_PLUGIN);
	HookConVarChange(g_hCvarTitleFmt, Cvar_Changed);

	// We need to look for logs in the appropriate directory
	g_hCvarLogsDir = FindConVar("sv_logsdir");
	if(g_hCvarLogsDir == INVALID_HANDLE) {
		// If it does not exist, something is seriously wrong. Abort!
		SetFailState("Could not find convar sv_logsdir.");
	}

	// We might want to have the servers hostname in our log title
	g_hCvarHostname = FindConVar("hostname");
	HookConVarChange(g_hCvarHostname, Cvar_Changed);

	// We also want to know when it gets changed
	HookConVarChange(g_hCvarLogsDir, Cvar_Changed);

	// We need this to get the team names and their ready state
	HookEvent("tournament_stateupdate", TeamStateEvent);

	// We need this to know when the actual match starts as we 
	// want to log a few extra details.
	HookEvent("teamplay_restart_round", GameRestartEvent);

	// We want to know when the match ends, so we can stop logging
	// and upload it.
	HookEvent("teamplay_game_over", GameOverEvent);		//maxrounds, timelimit
	HookEvent("tf_game_over", GameOverEvent);			//windifference

	RegAdminCmd("sm_triggerupload", Command_TriggerUpload, ADMFLAG_ROOT);
}

// THIS IS FOR DEBUG! REMOVE BEFORE RELEASE!
public Action:Command_TriggerUpload(client,args) {
	// Don't trigger twice
	g_bWatchGameOverEvent = false;

	// Skip a tick, then start a new log
	CreateTimer(0.01, Timer_TriggerNewLog);
}

public OnConfigsExecuted() {
	// Get the values of the cvars we are interested in.
	g_bEnabled = GetConVarBool(g_hCvarEnabled);		

	GetConVarString(g_hCvarTitleFmt, g_sTitleFmt, sizeof(g_sTitleFmt));
	GetConVarString(g_hCvarLogsDir, g_sLogsDir, sizeof(g_sLogsDir));
	GetConVarString(g_hCvarApiKey, g_sApiKey, sizeof(g_sApiKey));
	GetConVarString(g_hCvarHostname, g_sHostname, sizeof(g_sHostname));
}

public Cvar_Changed(Handle:convar, const String:oldValue[], const String:newValue[]) {
	// Reload all values when a cvar changed. This is the lazy way of doing it.
	OnConfigsExecuted();
}

public TeamStateEvent(Handle:event, const String:name[], bool:dontBroadcast) {
	new iTeam = GetClientTeam(GetEventInt(event, "userid"))-2;
	new bool:bNameChange = GetEventBool(event, "namechange");
	new bool:bReadyState = GetEventBool(event, "readystate");
	
	// We're only interested in the RED and BLUE team.
	if(iTeam != TEAM_RED && iTeam != TEAM_BLUE)return;

	if(bNameChange) {
		// Remember Team names, we use this for Log Title creation
		GetEventString(event, "newname", g_sTeamName[iTeam], MAX_NAME_LENGTH);
	} else {
		// Remember team ready states
		g_bReady[iTeam] = bReadyState;
	}
}


public GameRestartEvent(Handle:event, const String:name[], bool:dontBroadcast) {
	// If both teams are ready (this limits the plugin to tournament mode, which 
	// is something we want anyway.)
	if (g_bReady[TEAM_RED] && g_bReady[TEAM_BLUE])	{		
		g_bReady[TEAM_RED] = false;
		g_bReady[TEAM_BLUE] = false;

		// Get the currently active log file
		GetLastChangedLogFile(g_sActiveLogFile, sizeof(g_sActiveLogFile));		
		LogMessage("Active logfile: %s", g_sActiveLogFile);

		// Write a few details to the Log, so the data is not lost in 
		// case the upload fails.
		LogToGame("World triggered \"Teams_Ready\" (red \"%s\") (blue \"%s\") (map \"%s\")", 
			g_sTeamName[TEAM_RED],
			g_sTeamName[TEAM_BLUE],
			g_sCurrentMap);

		// Start watching for a game to end
		g_bWatchGameOverEvent = true;
	}
}

public OnMapStart() {
	// Reset our internal teamname and readystate cache
	strcopy(g_sTeamName[TEAM_RED], MAX_NAME_LENGTH, "RED");
	strcopy(g_sTeamName[TEAM_BLUE], MAX_NAME_LENGTH, "BLU");
	g_bReady[TEAM_RED] = false;
	g_bReady[TEAM_BLUE] = false;

	GetCurrentMap(g_sCurrentMap, sizeof(g_sCurrentMap));		
}

public GameOverEvent(Handle:event, const String:name[], bool:dontBroadcast) {
	if(!g_bWatchGameOverEvent)return;

	// We only check whether the plugin is enabled now, because it is the latest 
	// point at which we need to know, before we do anything substantial. Yes, we 
	// always add the map and team names to the logfile.
	if(!g_bEnabled)return;

	// Don't trigger twice
	g_bWatchGameOverEvent = false;

	// Skip a tick, then start a new log
	CreateTimer(0.01, Timer_TriggerNewLog);
}

public Action:Timer_TriggerNewLog(Handle:hTimer, any:data) {
	// Wait until there is a newer log than ours
	// It may be possible that the map changed before there is a new log.
	// This is very unlikely. But in the rare case that happens, we want
	// the repeating timer to stop on mapchange.
	// P.S.: The map would need to change while the scoreboard is still being
	// shown.
	ServerCommand("log on");

	CreateTimer(1.0, Timer_CheckLogs, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

// Our repeating timer. It compares the currently active log filename with the one 
// we recorded at match start.
public Action:Timer_CheckLogs(Handle:hTimer, any:data) {
	// Get the currently active logfile
	new String:sLastLogFile[PLATFORM_MAX_PATH];
	GetLastChangedLogFile(sLastLogFile, sizeof(sLastLogFile));

	// And compare it to the old one.
	// If it's still the same, wait a little longer.
	if(StrEqual(sLastLogFile, g_sActiveLogFile))return Plugin_Continue;

	// There is a logfile newer than ours, we can upload now
	// The actual upload is asynchronous, that means this function will
	// return rather quickly.
	UploadLog(g_sActiveLogFile);

	// And stop our timer now.
	return Plugin_Stop;
}

public GetLastChangedLogFile(String:sLogFile[], maxlen) {
	new iLatestChange = 0;

	new Handle:hDirectory = OpenDirectory("logs/");
	new String:sFileName[PLATFORM_MAX_PATH];
	new FileType:ftFile = FileType_Unknown;
	while(ReadDirEntry(hDirectory, sFileName, sizeof(sFileName), ftFile)) {
		// Skip sub-directories
		if(ftFile == FileType_Directory)continue;

		// Skip files not ending with .log
		if(strncmp(sFileName[strlen(sFileName)-4], ".log", 4, false) != 0)continue;

		new String:sFilePath[PLATFORM_MAX_PATH];
		Format(sFilePath, sizeof(sFilePath), "logs/%s", sFileName);

		new iTimeStamp = GetFileTime(sFilePath, FileTime_LastChange);

		if(iTimeStamp >= iLatestChange) {
			iLatestChange = iTimeStamp;
			strcopy(sLogFile, maxlen, sFilePath);
		}
	}
	CloseHandle(hDirectory);
}

public GenerateTitle(String:sFmt[], maxlength) {
	if(strlen(sFmt) == 0) {
		strcopy(sFmt, maxlength, "%h - %r vs %b");
	}

	ReplaceString(sFmt, maxlength, "%r", g_sTeamName[TEAM_RED], false);
	ReplaceString(sFmt, maxlength, "%b", g_sTeamName[TEAM_BLUE], false);
	ReplaceString(sFmt, maxlength, "%m", g_sCurrentMap, false);
	ReplaceString(sFmt, maxlength, "%h", g_sHostname, false);
}

public UploadLog(const String:sLogFile[PLATFORM_MAX_PATH]) {
	new Handle:hCurl = curl_easy_init();
	if(hCurl == INVALID_HANDLE)return;

	new CURL_Default_opt[][2] = {
		{_:CURLOPT_NOSIGNAL,1},
		{_:CURLOPT_NOPROGRESS,1},
		{_:CURLOPT_TIMEOUT,90},
		{_:CURLOPT_CONNECTTIMEOUT,60},
		{_:CURLOPT_VERBOSE,0}
	};
	curl_easy_setopt_int_array(hCurl, CURL_Default_opt, sizeof(CURL_Default_opt));

	// Create a HTTP POST call
	new Handle:hForm = curl_httppost();

	// Set the logfile to be uploaded
	curl_formadd(hForm, CURLFORM_COPYNAME, "logfile", CURLFORM_FILE, sLogFile, CURLFORM_END);

	// Get the current map and set the form field
	curl_formadd(hForm, CURLFORM_COPYNAME, "map", CURLFORM_COPYCONTENTS, g_sCurrentMap, CURLFORM_END);

	// Pass the API key.
	curl_formadd(hForm, CURLFORM_COPYNAME, "key", CURLFORM_COPYCONTENTS, g_sApiKey, CURLFORM_END);

	// Generate and set the title field
	new String:sTitle[128];
	strcopy(sTitle, sizeof(sTitle), g_sTitleFmt);
	GenerateTitle(sTitle, sizeof(sTitle));	
	curl_formadd(hForm, CURLFORM_COPYNAME, "title", CURLFORM_COPYCONTENTS, sTitle, CURLFORM_END);

	// Add the form to the curl request
	curl_easy_setopt_handle(hCurl, CURLOPT_HTTPPOST, hForm);	

	// Provide our own function to deal with the retrieved data.
	// We don't want/need a temporary file for a few bytes of json.
	curl_easy_setopt_function(hCurl, CURLOPT_WRITEFUNCTION, ReceiveResponse);

	// Set the url to connect to
	curl_easy_setopt_string(hCurl, CURLOPT_URL, LOGS_TF_UPLOAD_URL);

	// Clear the receive buffer
	strcopy(g_sReceived, sizeof(g_sReceived), "");

	// Log the actual upload start
	LogMessage("Uploading log '%s' with title '%s'", sLogFile, sTitle);

	// And finally do a threaded call
	curl_easy_perform_thread(hCurl, UploadComplete, hForm);	
}

public UploadComplete(Handle:hCurl, CURLcode:code, any:hForm) {
	if(code != CURLE_OK) {
		new String:sCurlError[256];
		curl_easy_strerror(code, sCurlError, sizeof(sCurlError));
		LogError("Curl reported: %s (%i)", sCurlError, code);
	} else {		
		ProcessResponse(g_sReceived);
	}	

	CloseHandle(hForm);
	CloseHandle(hCurl);
}

public ProcessResponse(const String:sJson[]) {
	new bool:bSuccess = false;
	new String:sError[128];
	new iLogId = 0;
	
	// There is an include for JSON that does not require an extension,
	// but it seems to be broken. Anyhow: this would be most of the code
	// required to use it. 
	/*	
	#include <json>
	if(!LibraryExists("jansson")) {
		new JSON:hJson = json_decode(g_sReceived);
		if(hJson == JSON_INVALID) {
			LogMessage("Invalid JSON says the include!");
			return;
		}

		json_get_cell(hJson, "success", bSuccess);

		if(bSuccess) {			
			json_get_cell(hJson, "log_id", iLogId);
		} else {
			json_get_string(hJson, "error", sError, sizeof(sError));	
		}

		json_destroy(hJson);
	} else {
		// The SMJansson way, see below
	}
	*/

	new Handle:hJson = json_load(g_sReceived);
	bSuccess = json_object_get_bool(hJson, "success");

	if(bSuccess) {
		iLogId = json_object_get_int(hJson, "log_id");
	} else {
		json_object_get_string(hJson, "error", sError, sizeof(sError));
	}

	CloseHandle(hJson);

	if(bSuccess) {
		LogMessage("Successfully uploaded log (id %i).", iLogId);
		CPrintToChatAll("Log is available at: {olive}http://logs.tf/%i", iLogId);
	} else {
		LogError("Logs.tf reports: %s", sError);
	}
}

// This is called every time we get some pieces of response data
public ReceiveResponse(Handle:hndl, const String:buffer[], const bytes, const nmemb) {
	StrCat(g_sReceived, sizeof(g_sReceived), buffer);

	return bytes*nmemb;
}