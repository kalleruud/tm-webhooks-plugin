#if DIAGNOSTICS && TMNEXT
void DiagnosticsRunPlayers(DiagnosticsRunRecorder@ recorder)
{
    auto app = cast<CTrackMania>(GetApp());
    if (app is null || app.CurrentPlayground is null) return;
    auto playground = app.CurrentPlayground;
    auto feed = MLFeed::GetRaceData_V4();
    string mapUid = app.RootMap is null ? "" : app.RootMap.IdName;
    for (uint i = 0; i < playground.Players.Length && i < 16; i++) {
        auto player = cast<CSmPlayer>(playground.Players[i]);
        if (player is null) continue;
        try {
        string name = player.User is null ? "" : string(player.User.Name);
        string userKey = DiagnosticsRunIdentity(player.User, i, name);
        Json::Value sample = Json::Object();
        sample["kind"] = "run-sample";
        sample["sampleSequence"] = recorder.sampleSequence;
        sample["observedAt"] = OccurredAtUtc();
        sample["elapsedMs"] = Time::Now - recorder.started;
        sample["playerId"] = recorder.PlayerId(userKey + "#slot:" + i);
        sample["userKey"] = userKey;
        sample["playerIndex"] = i;
        sample["name"] = DiagnosticsRunText(name);
        sample["mapUid"] = mapUid;
        sample["apiType"] = "CSmPlayer/CSmScriptPlayer";
        Json::Value race = Json::Object();
        Json::Value sources = Json::Object();
        auto script = cast<CSmScriptPlayer>(player.ScriptAPI);
        if (script !is null) {
            sample["attemptToken"] = mapUid + ":" + script.StartTime;
            race["startTime"] = script.StartTime;
            race["clan"] = script.CurrentClan;
            race["timeMs"] = script.CurrentRaceTime;
            race["lapTimeMs"] = script.CurrentLapTime;
            race["racing"] = script.CurrentRaceTime >= 0 && script.IsInVehicle;
            race["state"] = int(script.SpawnStatus);
            race["respawns"] = script.CurrentRaceRespawns;
            race["lap"] = script.CurrentLapNumber;
            race["checkpointCount"] = script.RaceWaypointTimes.Length;
            race["nativeCheckpointCount"] = script.RaceWaypointTimes.Length;
            Json::Value times = Json::Array();
            for (uint j = 0; j < script.RaceWaypointTimes.Length && j < 256; j++) times.Add(Json::Value(script.RaceWaypointTimes[j]));
            race["checkpointTimesMs"] = times;
            race["checkpointTimesTruncated"] = script.RaceWaypointTimes.Length > 256;
            sources["race.timeMs"] = "CSmScriptPlayer.CurrentRaceTime";
            sources["race.checkpointCount"] = "CSmScriptPlayer.RaceWaypointTimes.Length";
            sources["race.checkpointTimesMs"] = "CSmScriptPlayer.RaceWaypointTimes";
            Json::Value input = Json::Object();
            input["throttle"] = DiagnosticsRunNumber(script.InputGasPedal);
            input["brake"] = script.InputIsBraking;
            input["steer"] = DiagnosticsRunNumber(script.InputSteer);
            sample["input"] = input;
            sources["input"] = "CSmScriptPlayer.InputGasPedal/InputIsBraking/InputSteer";
            Json::Value vehicle = Json::Object();
            vehicle["stateAvailable"] = script.IsEntityStateAvailable;
            vehicle["inVehicle"] = script.IsInVehicle;
            if (script.IsEntityStateAvailable) {
                vehicle["position"] = DiagnosticsRunVector(script.Position);
                vehicle["velocity"] = DiagnosticsRunVector(script.Velocity);
                vehicle["speed"] = DiagnosticsRunNumber(script.Speed);
                vehicle["displaySpeed"] = script.DisplaySpeed;
                vehicle["engineRpm"] = DiagnosticsRunNumber(script.EngineRpm);
                vehicle["gear"] = script.EngineCurGear;
                vehicle["turboRatio"] = DiagnosticsRunNumber(script.EngineTurboRatio);
                vehicle["wheelContacts"] = script.WheelsContactCount;
                vehicle["wheelsSkidding"] = script.WheelsSkiddingCount;
                vehicle["flyingDurationMs"] = script.FlyingDuration;
                vehicle["skiddingDurationMs"] = script.SkiddingDuration;
                vehicle["distance"] = DiagnosticsRunNumber(script.Distance);
                vehicle["accelCoef"] = DiagnosticsRunNumber(script.AccelCoef);
                vehicle["gravityCoef"] = DiagnosticsRunNumber(script.GravityCoef);
            }
            sample["vehicle"] = vehicle;
            sources["vehicle"] = "CSmScriptPlayer.Position/Velocity/Speed/DisplaySpeed/EngineRpm/EngineCurGear/WheelsContactCount/WheelsSkiddingCount";
        } else {
            sample["coverage"] = "CSmScriptPlayer unavailable; native input/vehicle fields omitted";
            sample["attemptToken"] = mapUid + ":spawn:" + player.SpawnIndex;
        }
        if (feed !is null && player.User !is null) {
            auto data = feed.GetPlayer_V4(player.User.Name);
            if (data !is null) {
                race["timeMs"] = data.CurrentRaceTime;
                race["racing"] = data.PlayerIsRacing;
                race["finished"] = data.IsFinished;
                race["respawns"] = data.NbRespawnsRequested;
                race["checkpointCount"] = data.CpCount;
                if (script !is null) race["checkpointHistoryMatchesCount"] = uint(data.CpCount) == script.RaceWaypointTimes.Length;
                race["checkpointTimeMs"] = data.LastCpTime;
                race["lap"] = data.CurrentLap;
                race["spawnIndex"] = data.SpawnIndex;
                race["theoreticalTimeMs"] = data.LastTheoreticalCpTime;
                race["timeLostToRespawnsMs"] = data.TimeLostToRespawns;
                if (data.IsFinished) race["finishTimeMs"] = data.FinishTime;
                sources["race.timeMs"] = "MLFeed.PlayerData_V4.CurrentRaceTime";
                sources["race.respawns"] = "MLFeed.PlayerData_V4.NbRespawnsRequested";
                sources["race.lap"] = "MLFeed.PlayerData_V4.CurrentLap";
                sources["race.checkpointCount"] = "MLFeed.PlayerData_V4.CpCount";
                sources["race.checkpointTimeMs"] = "MLFeed.PlayerData_V4.LastCpTime";
                sources["race.racing"] = "MLFeed.PlayerData_V4.PlayerIsRacing";
                sources["race.finished"] = "MLFeed.PlayerData_V4.IsFinished";
                sources["race.finishTimeMs"] = "MLFeed.PlayerData_V4.FinishTime";
            }
        }
        if (app.PlaygroundScript !is null) race["gameTimeMs"] = app.PlaygroundScript.Now;
        sample["race"] = race;
        sample["sources"] = sources;
        recorder.Emit(sample);
        } catch { recorder.Error("player-" + i, "CSmPlayer/CSmScriptPlayer getter exception"); }
    }
}

Json::Value DiagnosticsRunNextScore(CSmArenaScore@ score, uint index)
{
    Json::Value row = Json::Object();
    row["listIndex"] = index;
    if (score.User !is null) {
        row["name"] = DiagnosticsRunText(string(score.User.Name), 64);
        row["login"] = DiagnosticsRunText(score.User.Login, 64);
        row["userKey"] = DiagnosticsRunIdentity(score.User, index, string(score.User.Name));
    }
    row["points"] = score.Points;
    row["roundPoints"] = score.RoundPoints;
    row["team"] = score.TeamNum;
    row["rankSortValue"] = score.LadderRankSortValue;
    row["respawnsRequested"] = score.NbRespawnsRequested;
    Json::Value best = Json::Array();
    for (uint j = 0; j < score.BestRaceTimes.Length && j < 8; j++) best.Add(Json::Value(score.BestRaceTimes[j]));
    row["bestRaceTimesMs"] = best;
    row["bestRaceTimesCount"] = score.BestRaceTimes.Length;
    Json::Value previous = Json::Array();
    for (uint j = 0; j < score.PrevRaceTimes.Length && j < 8; j++) previous.Add(Json::Value(score.PrevRaceTimes[j]));
    row["previousRaceTimesMs"] = previous;
    row["previousRaceTimesCount"] = score.PrevRaceTimes.Length;
    return row;
}

void DiagnosticsRunContext(DiagnosticsRunRecorder@ recorder)
{
    auto app = cast<CTrackMania>(GetApp());
    if (app is null) return;
    Json::Value context = Json::Object();
    context["kind"] = "run-context";
    context["map"] = DiagnosticsRunMap(app.RootMap);
    context["playerCount"] = app.CurrentPlayground is null ? 0 : app.CurrentPlayground.Players.Length;
    context["localTerminalCount"] = app.CurrentPlayground is null ? 0 : app.CurrentPlayground.GameTerminals.Length;
    context["sampledPlayerCap"] = 16;
    Json::Value roster = Json::Array();
    if (app.CurrentPlayground !is null) {
        for (uint i = 0; i < app.CurrentPlayground.Players.Length && i < 16; i++) {
            auto player = app.CurrentPlayground.Players[i];
            if (player is null) continue;
            string name = player.User is null ? "" : string(player.User.Name);
            roster.Add(DiagnosticsRunRoster(player.User, i, name, recorder));
        }
    }
    context["players"] = roster;
    if (app.PlaygroundScript !is null) {
        bool split = app.CurrentPlayground !is null && app.CurrentPlayground.GameTerminals.Length > 1;
        context["mode"] = SerializeMode(ReadNextMode(app, split));
        context["scriptIdName"] = app.PlaygroundScript.IdName;
        context["playerModelName"] = DiagnosticsRunText(string(app.PlaygroundScript.MapPlayerModelName));
        context["serverModeName"] = DiagnosticsRunText(string(app.PlaygroundScript.ServerModeName));
        context["modeStatus"] = DiagnosticsRunText(string(app.PlaygroundScript.ModeStatusMessage));
    }
    if (app.Network !is null && app.Network.PlaygroundClientScriptAPI !is null) {
        auto ui = app.Network.PlaygroundClientScriptAPI.UI;
        if (ui !is null) context["uiSequence"] = int(ui.UISequence);
        context["localOrServer"] = app.Network.PlaygroundClientScriptAPI.IsServerOrSolo;
    }
    auto modeRules = cast<CSmArenaRulesMode>(app.PlaygroundScript);
    if (modeRules !is null) {
        Json::Value flags = Json::Object();
        flags["UseClans"] = modeRules.UseClans;
        flags["UseForcedClans"] = modeRules.UseForcedClans;
        flags["UiScoresPointsLimit"] = modeRules.UiScoresPointsLimit;
        flags["Scores_SortCriteria"] = int(modeRules.Scores_SortCriteria);
        flags["PlayersNbTotal"] = modeRules.PlayersNbTotal;
        context["nativeModeFlags"] = flags;
        context["modeFlagsSource"] = "CSmArenaRulesMode";
    }
    auto feed = MLFeed::GetRaceData_V4();
    if (feed !is null) { context["lapCount"] = feed.LapCount; context["checkpointsPerLap"] = feed.CPCount; }
    recorder.Changed(context, false);
    Json::Value board = Json::Object();
    board["kind"] = "run-leaderboard";
    board["orderSemantics"] = "API list order; not assumed finishing rank";
    Json::Value rows = Json::Array();
    auto rules = cast<CSmArenaRulesMode>(app.PlaygroundScript);
    if (rules !is null) {
        board["source"] = "CSmArenaRulesMode.Scores";
        board["sourceCount"] = rules.Scores.Length;
        board["truncated"] = rules.Scores.Length > 32;
        for (uint i = 0; i < rules.Scores.Length && i < 32; i++) if (rules.Scores[i] !is null) rows.Add(DiagnosticsRunNextScore(rules.Scores[i], i));
    } else if (app.CurrentPlayground !is null) {
        board["source"] = "CGamePlayground.Players/CSmPlayer.Score";
        board["sourceCount"] = app.CurrentPlayground.Players.Length;
        board["truncated"] = app.CurrentPlayground.Players.Length > 32;
        for (uint i = 0; i < app.CurrentPlayground.Players.Length && i < 32; i++) {
            auto player = cast<CSmPlayer>(app.CurrentPlayground.Players[i]);
            if (player !is null && player.Score !is null) {
                Json::Value row = DiagnosticsRunNextScore(player.Score, i);
                if (!row.HasKey("name") && player.User !is null) row["name"] = DiagnosticsRunText(string(player.User.Name), 64);
                rows.Add(row);
            }
        }
    } else board["source"] = "unavailable";
    board["rows"] = rows;
    recorder.Changed(board, true);
}

void DiagnosticsRunEvents(DiagnosticsRunRecorder@ recorder)
{
    auto app = cast<CTrackMania>(GetApp());
    if (app is null) return;
    string mapUid = app.RootMap is null ? "" : app.RootMap.IdName;
    if (recorder.eventMap != mapUid) { recorder.eventMap = mapUid; recorder.seenEvents.RemoveRange(0, recorder.seenEvents.Length); }
    auto rules = cast<CSmArenaRulesMode>(app.PlaygroundScript);
    if (rules is null) return;
    for (uint i = 0; i < rules.PendingEvents.Length && i < 64; i++) {
        auto event = rules.PendingEvents[i];
        if (event is null) continue;
        string name;
        if (event.Type == CSmArenaRulesEvent::EType::OnPlayerTriggersWaypoint) name = "waypoint";
        else if (event.Type == CSmArenaRulesEvent::EType::OnPlayerRequestRespawn) name = "respawn_request";
        else if (event.Type == CSmArenaRulesEvent::EType::OnVehicleCollision) name = "vehicle_collision";
        else if (event.Type == CSmArenaRulesEvent::EType::OnVehicleVsVehicleCollision) name = "vehicle_vehicle_collision";
        else if (event.Type == CSmArenaRulesEvent::EType::OnStuntFigure) name = "stunt";
        else continue;
        if (!recorder.NewEvent(event)) continue;
        Json::Value record = Json::Object();
        record["kind"] = "run-native-event";
        record["event"] = name;
        record["source"] = "CSmArenaRulesMode.PendingEvents/CSmArenaRulesEvent";
        record["type"] = int(event.Type);
        record["mapUid"] = mapUid;
        if (event.Player !is null) {
            record["userKey"] = DiagnosticsRunIdentity(event.Player.User, 0, string(event.Player.Name));
            record["name"] = DiagnosticsRunText(string(event.Player.Name));
        }
        if (name == "waypoint") {
            record["raceTimeMs"] = event.WaypointTime;
            record["lapTimeMs"] = event.WaypointLapTime;
            record["isFinish"] = event.IsFinish;
            record["isNewLap"] = event.IsNewLap;
        }
        if (name == "vehicle_collision" || name == "vehicle_vehicle_collision") {
            record["damageRaw"] = event.Damage;
            record["targetClassification"] = "not exposed by this recorder; a wall hit is not assumed";
        }
        recorder.Emit(record);
    }
}
#endif
