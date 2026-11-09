void PutNonEmptyString(Json::Value@ json, const string &in key, const string &in value)
{
    if (value.Length > 0) json[key] = value;
}

Json::Value@ SerializePlayer(PlayerSnapshot@ player)
{
    Json::Value@ json = Json::Object();
    json["playerIndex"] = player.playerIndex;
    PutNonEmptyString(json, "attemptId", player.attemptId);
    PutNonEmptyString(json, "sessionId", player.sessionId);
    PutNonEmptyString(json, "turnId", player.turnId);
    PutNonEmptyString(json, "participantId", player.participantId);
    PutNonEmptyString(json, "name", player.name);
    PutNonEmptyString(json, "login", player.login);
    PutNonEmptyString(json, "localId", player.localId);
    PutNonEmptyString(json, "accountId", player.accountId);
    return json;
}

Json::Value@ SerializeMap(MapSnapshot@ map)
{
    if (map is null) return Json::Value();

    Json::Value@ json = Json::Object();
    json["name"] = map.name;
    json["uid"] = map.uid;
    json["author"] = map.author;
    json["environment"] = map.environment;
    json["type"] = map.mapType;
    json["isLaps"] = map.isLaps;
    if (map.isLaps && map.totalLaps > 0) json["totalLaps"] = map.totalLaps;
    json["checkpointsPerLap"] = map.checkpointsPerLap;
    Json::Value@ medals = Json::Object();
    medals["author"] = map.authorTime;
    medals["gold"] = map.goldTime;
    medals["silver"] = map.silverTime;
    medals["bronze"] = map.bronzeTime;
    json["medalTimesMs"] = medals;
    return json;
}

Json::Value@ SerializeMode(ModeSnapshot@ mode)
{
    if (mode is null) return Json::Value();

    Json::Value@ json = Json::Object();
    json["name"] = mode.name;
    PutNonEmptyString(json, "type", mode.modeType);
    return json;
}

string SerializeEvent(CapturedEvent@ event)
{
    Json::Value@ json = Json::Object();
    PutNonEmptyString(json, "schemaVersion", SCHEMA_VERSION);
    PutNonEmptyString(json, "type", event.eventType);
    PutNonEmptyString(json, "eventId", event.eventId);
    json["sequence"] = event.sequence;
    PutNonEmptyString(json, "occurredAt", event.occurredAt);
    if (event.eventType != "score" && event.eventType != "player_name") {
        json["durationMs"] = event.durationMs;
        Json::Value@ game = Json::Object();
        PutNonEmptyString(game, "gameId", event.gameId);
        game["totalPlayers"] = event.totalPlayers;
        json["game"] = game;
    }
    Json::Value@ source = Json::Object();
    PutNonEmptyString(source, "pluginName", PLUGIN_NAME);
    PutNonEmptyString(source, "pluginVersion", Meta::ExecutingPlugin().Version);
    PutNonEmptyString(source, "game", AdapterGameName());
    json["source"] = source;

    if (event.eventType == "player_name") {
        json["sessionId"] = event.sessionId;
        json["participantId"] = event.participantId;
        json["name"] = event.player.name;
    } else if (event.eventType == "score") {
        json["sessionId"] = event.sessionId;
        json["mapUid"] = event.mapUid;
        json["mode"] = event.scoreMode;
        if (event.scoreMode == "arcade") {
            json["turnId"] = event.turnId;
            Json::Value@ player = Json::Object();
            player["name"] = event.player.name;
            json["player"] = player;
            Json::Value@ attempts = Json::Array();
            for (uint i = 0; i < event.attemptIds.Length; i++) attempts.Add(event.attemptIds[i]);
            json["attemptIds"] = attempts;
            json["captureComplete"] = event.captureComplete;
        } else if (event.scoreMode == "hot-seat") {
            json["participantId"] = event.participantId;
            json["attemptId"] = event.player.attemptId;
            if (event.player.name.Length > 0) {
                Json::Value@ player = Json::Object();
                player["name"] = event.player.name;
                json["player"] = player;
            }
            Json::Value@ result = Json::Object();
            result["status"] = "finished";
            result["timeMs"] = event.timeMs;
            json["result"] = result;
        }
    } else if (event.eventType == "start") {
        Json::Value@ players = Json::Array();
        for (uint i = 0; i < event.players.Length; i++) players.Add(SerializePlayer(event.players[i]));
        json["players"] = players;
        json["map"] = SerializeMap(event.map);
        json["mode"] = SerializeMode(event.mode);
    } else if (event.eventType == "end") {
        PutNonEmptyString(json, "endReason", event.endReason);
    } else {
        json["player"] = SerializePlayer(event.player);
        if (event.eventType != "first_throttle") {
            Json::Value@ checkpoint = Json::Object();
            checkpoint["checkpointIndex"] = event.checkpointIndex;
            checkpoint["checkpointLapIndex"] = event.checkpointLapIndex;
            checkpoint["lapNumber"] = event.lapNumber;
            if (event.theoreticalDurationMs >= 0) checkpoint["theoreticalDurationMs"] = event.theoreticalDurationMs;
            if (event.lostMs >= 0) checkpoint["lostMs"] = event.lostMs;
            json["checkpoint"] = checkpoint;
        }
    }
    return Json::Write(json);
}
