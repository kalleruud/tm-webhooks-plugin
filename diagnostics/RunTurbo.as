#if DIAGNOSTICS && TURBO
void DiagnosticsRunPlayers(DiagnosticsRunRecorder@ recorder)
{
    auto app = cast<CGameManiaPlanet>(GetApp());
    if (app is null || app.CurrentPlayground is null) return;
    auto playground = app.CurrentPlayground;
    string mapUid = app.Challenge is null ? "" : app.Challenge.IdName;
    for (uint i = 0; i < playground.Players.Length && i < 16; i++) {
        auto player = cast<CTrackManiaPlayer>(playground.Players[i]);
        if (player is null) continue;
        try {
        Json::Value sample = Json::Object();
        sample["kind"] = "run-sample";
        sample["sampleSequence"] = recorder.sampleSequence;
        sample["observedAt"] = OccurredAtUtc();
        sample["elapsedMs"] = Time::Now - recorder.started;
        string userKey = DiagnosticsRunIdentity(player.User, i, string(player.Name));
        sample["userKey"] = userKey;
        sample["playerId"] = recorder.PlayerId(userKey + "#slot:" + i);
        sample["playerIndex"] = i;
        sample["name"] = DiagnosticsRunText(string(player.Name));
        sample["mapUid"] = mapUid;
        sample["attemptToken"] = mapUid + ":" + player.RaceStartTime;
        sample["apiType"] = "CTrackManiaPlayer";
        Json::Value race = Json::Object();
        race["state"] = int(player.RaceState);
        race["racing"] = player.IsSpawned && player.RaceStartTime > 0 && (player.RaceState == CTrackManiaPlayer::ERaceState::Running || player.RaceState == CTrackManiaPlayer::ERaceState::Finished);
        race["finished"] = false;
        race["spawned"] = player.IsSpawned;
        race["clan"] = player.CurrentClan;
        race["startTime"] = player.RaceStartTime;
        if (app.PlaygroundScript !is null) {
            race["gameTimeMs"] = app.PlaygroundScript.Now;
            if (player.RaceStartTime > 0) race["timeMs"] = int64(app.PlaygroundScript.Now) - int64(player.RaceStartTime);
        }
        race["respawns"] = player.NbRespawns;
        race["lap"] = player.CurLapIndex;
        race["checkpointTimeMs"] = player.CurCheckpointRaceTime;
        race["checkpointLapTimeMs"] = player.CurCheckpointLapTime;
        race["continuousRank"] = player.CurRaceContinuousRank;
        if (player.CurRace !is null) {
            race["checkpointCount"] = player.CurRace.Checkpoints.Length;
            Json::Value times = Json::Array();
            for (uint j = 0; j < player.CurRace.Checkpoints.Length && j < 256; j++) times.Add(Json::Value(player.CurRace.Checkpoints[j]));
            race["checkpointTimesMs"] = times;
            race["checkpointTimesTruncated"] = player.CurRace.Checkpoints.Length > 256;
            race["resultTimeRaw"] = player.CurRace.Time;
            if (player.RaceState == CTrackManiaPlayer::ERaceState::Finished && player.CurRace.Time >= 0) {
                race["finished"] = true;
                race["finishTimeMs"] = player.CurRace.Time;
            }
        }
        sample["race"] = race;
        Json::Value input = Json::Object();
        input["throttle"] = DiagnosticsRunNumber(player.InputGasPedal);
        input["brake"] = player.InputIsBraking;
        input["steer"] = DiagnosticsRunNumber(player.InputSteer);
        sample["input"] = input;
        Json::Value vehicle = Json::Object();
        vehicle["position"] = DiagnosticsRunVector(player.Position);
        vehicle["speed"] = DiagnosticsRunNumber(player.Speed);
        vehicle["displaySpeed"] = player.DisplaySpeed;
        vehicle["engineRpm"] = DiagnosticsRunNumber(player.EngineRpm);
        vehicle["gear"] = player.EngineCurGear;
        vehicle["turboRatio"] = DiagnosticsRunNumber(player.EngineTurboRatio);
        vehicle["wheelContacts"] = player.WheelsContactCount;
        vehicle["wheelsSkidding"] = player.WheelsSkiddingCount;
        vehicle["damageHull"] = DiagnosticsRunNumber(player.DamageHullRatio);
        vehicle["damageWindows"] = DiagnosticsRunNumber(player.DamageWindowRatio);
        vehicle["flyingDurationMs"] = player.FlyingDuration;
        vehicle["skiddingDurationMs"] = player.SkiddingDuration;
        vehicle["distance"] = DiagnosticsRunNumber(player.Distance);
        vehicle["accelCoef"] = DiagnosticsRunNumber(player.AccelCoef);
        vehicle["gravityCoef"] = DiagnosticsRunNumber(player.GravityCoef);
        sample["vehicle"] = vehicle;
        Json::Value sources = Json::Object();
        sources["race.timeMs"] = "CGamePlaygroundScript.Now - CTrackManiaPlayer.RaceStartTime";
        sources["race.checkpointCount"] = "CTrackManiaPlayer.CurRace.Checkpoints.Length";
        sources["race.checkpointTimesMs"] = "CTrackManiaPlayer.CurRace.Checkpoints";
        sources["race.finishTimeMs"] = "CTrackManiaPlayer.CurRace.Time";
        sources["input"] = "CTrackManiaPlayer.InputGasPedal/InputIsBraking/InputSteer";
        sources["vehicle"] = "CTrackManiaPlayer.Position/Speed/DisplaySpeed/EngineRpm/EngineCurGear/WheelsContactCount/WheelsSkiddingCount/DamageHullRatio/DamageWindowRatio";
        sample["sources"] = sources;
        sample["autoPilot"] = player.AutoPilotEnabled;
        sample["onlineMode"] = player.EnableOnlineMode;
        recorder.Emit(sample);
        } catch { recorder.Error("player-" + i, "CTrackManiaPlayer getter exception"); }
    }
}

Json::Value DiagnosticsRunTurboScore(CTmRaceRulesScore@ score, uint index)
{
    Json::Value row = Json::Object();
    row["listIndex"] = index;
    if (score.User !is null) {
        row["name"] = DiagnosticsRunText(string(score.User.Name), 64);
        row["login"] = DiagnosticsRunText(score.User.Login, 64);
        row["userKey"] = DiagnosticsRunIdentity(score.User, index, string(score.User.Name));
    }
    row["points"] = score.Points;
    row["team"] = score.TeamNum;
    row["rankSortValue"] = score.LadderRankSortValue;
    if (score.BestRace !is null) row["bestRaceTimeMs"] = score.BestRace.Time;
    if (score.PrevRace !is null) row["previousRaceTimeMs"] = score.PrevRace.Time;
    if (score.BestLap !is null) row["bestLapTimeMs"] = score.BestLap.Time;
    auto tmScore = cast<CTrackManiaScore>(score);
    if (tmScore !is null) {
        row["bestTimeRaw"] = tmScore.BestTime;
        row["lastRaceTimeRaw"] = tmScore.LastRaceTime;
        row["bestStuntsScore"] = tmScore.BestStuntsScore;
        row["score"] = tmScore.Score;
    }
    return row;
}

void DiagnosticsRunContext(DiagnosticsRunRecorder@ recorder)
{
    auto app = cast<CGameManiaPlanet>(GetApp());
    if (app is null) return;
    Json::Value context = Json::Object();
    context["kind"] = "run-context";
    context["map"] = DiagnosticsRunMap(app.Challenge);
    context["playerCount"] = app.CurrentPlayground is null ? 0 : app.CurrentPlayground.Players.Length;
    context["localTerminalCount"] = app.CurrentPlayground is null ? 0 : app.CurrentPlayground.GameTerminals.Length;
    context["sampledPlayerCap"] = 16;
    Json::Value roster = Json::Array();
    if (app.CurrentPlayground !is null) {
        for (uint i = 0; i < app.CurrentPlayground.Players.Length && i < 16; i++) {
            auto player = app.CurrentPlayground.Players[i];
            if (player !is null) roster.Add(DiagnosticsRunRoster(player.User, i, string(player.Name), recorder));
        }
    }
    context["players"] = roster;
    for (uint i = 0; i < app.ActiveMenus.Length && i < 16; i++) {
        auto menu = app.ActiveMenus[i];
        if (menu is null) continue;
        string hint = TurboModeHint(menu.IdName);
        if (hint.Length > 0) recorder.launchModeHint = hint;
    }
    if (app.PlaygroundScript !is null) {
        bool split = app.CurrentPlayground !is null && app.CurrentPlayground.GameTerminals.Length > 1;
        context["mode"] = SerializeMode(ReadTurboMode(app, split, recorder.launchModeHint));
        context["scriptIdName"] = app.PlaygroundScript.IdName;
        context["playerModelName"] = DiagnosticsRunText(string(app.PlaygroundScript.MapPlayerModelName));
        context["serverModeName"] = DiagnosticsRunText(string(app.PlaygroundScript.ServerModeName));
        context["modeStatus"] = DiagnosticsRunText(string(app.PlaygroundScript.ModeStatusMessage));
        if (app.PlaygroundScript.UIManager !is null && app.PlaygroundScript.UIManager.LocalPlayerConfig !is null)
            context["uiSequence"] = int(app.PlaygroundScript.UIManager.LocalPlayerConfig.UISequence);
    }
    auto modeNetwork = cast<CTrackManiaNetwork>(app.Network);
    if (modeNetwork !is null && modeNetwork.TmRaceRules !is null) {
        auto modeRules = modeNetwork.TmRaceRules;
        Json::Value flags = Json::Object();
        flags["UiRounds"] = modeRules.UiRounds;
        flags["UiLaps"] = modeRules.UiLaps;
        flags["UiStuntsMode"] = modeRules.UiStuntsMode;
        flags["EnableCollisions"] = modeRules.EnableCollisions;
        flags["EnableScaleCar"] = modeRules.EnableScaleCar;
        flags["EnableCheckpointBonus"] = modeRules.EnableCheckpointBonus;
        flags["EnableUniqueCamera"] = modeRules.EnableUniqueCamera;
        flags["EnableBonusEvents"] = modeRules.EnableBonusEvents;
        flags["NbLaps"] = modeRules.NbLaps;
        flags["MapNbLaps"] = modeRules.MapNbLaps;
        flags["UseClans"] = modeRules.UseClans;
        context["nativeModeFlags"] = flags;
        context["modeFlagsSource"] = "CTrackManiaRaceRules";
    }
    recorder.Changed(context, false);
    auto network = cast<CTrackManiaNetwork>(app.Network);
    CTrackManiaRaceRules@ rules;
    if (network !is null) @rules = network.TmRaceRules;
    Json::Value board = Json::Object();
    board["kind"] = "run-leaderboard";
    board["orderSemantics"] = "API list order; not assumed finishing rank";
    Json::Value rows = Json::Array();
    if (rules !is null && rules.Scores.Length > 0) {
        board["source"] = "CTrackManiaRaceRules.Scores";
        board["sourceCount"] = rules.Scores.Length;
        board["truncated"] = rules.Scores.Length > 32;
        for (uint i = 0; i < rules.Scores.Length && i < 32; i++) if (rules.Scores[i] !is null) rows.Add(DiagnosticsRunTurboScore(rules.Scores[i], i));
    } else if (app.CurrentPlayground !is null) {
        board["source"] = "CGamePlayground.Players/CTrackManiaPlayer.Score";
        board["sourceCount"] = app.CurrentPlayground.Players.Length;
        board["truncated"] = app.CurrentPlayground.Players.Length > 32;
        for (uint i = 0; i < app.CurrentPlayground.Players.Length && i < 32; i++) {
            auto player = cast<CTrackManiaPlayer>(app.CurrentPlayground.Players[i]);
            if (player !is null && player.Score !is null) {
                Json::Value row = DiagnosticsRunTurboScore(player.Score, i);
                if (!row.HasKey("name")) row["name"] = DiagnosticsRunText(string(player.Name), 64);
                rows.Add(row);
            }
        }
    } else board["source"] = "unavailable";
    board["rows"] = rows;
    recorder.Changed(board, true);
}

void DiagnosticsRunEvents(DiagnosticsRunRecorder@ recorder)
{
    auto app = cast<CGameManiaPlanet>(GetApp());
    if (app is null) return;
    string mapUid = app.Challenge is null ? "" : app.Challenge.IdName;
    if (recorder.eventMap != mapUid) { recorder.eventMap = mapUid; recorder.seenEvents.RemoveRange(0, recorder.seenEvents.Length); }
    auto network = cast<CTrackManiaNetwork>(app.Network);
    if (network is null || network.TmRaceRules is null) return;
    auto rules = network.TmRaceRules;
    for (uint i = 0; i < rules.PendingEvents.Length && i < 64; i++) {
        auto event = rules.PendingEvents[i];
        if (event is null) continue;
        string name;
        if (event.Type == CTmRaceRulesEvent::EType::StartLine) name = "start_line";
        else if (event.Type == CTmRaceRulesEvent::EType::WayPoint) name = "waypoint";
        else if (event.Type == CTmRaceRulesEvent::EType::Respawn) name = "respawn";
        else if (event.Type == CTmRaceRulesEvent::EType::GiveUp) name = "give_up";
        else if (event.Type == CTmRaceRulesEvent::EType::Stunt) name = "stunt";
        else continue;
        if (!recorder.NewEvent(event)) continue;
        Json::Value record = Json::Object();
        record["kind"] = "run-native-event";
        record["event"] = name;
        record["source"] = "CTrackManiaRaceRules.PendingEvents/CTmRaceRulesEvent";
        record["type"] = int(event.Type);
        record["raceTimeMs"] = event.RaceTime;
        record["mapUid"] = mapUid;
        if (event.Player !is null) {
            record["userKey"] = DiagnosticsRunIdentity(event.Player.User, 0, string(event.Player.Name));
            record["name"] = DiagnosticsRunText(string(event.Player.Name));
        }
        if (name == "waypoint") {
            record["checkpointInRace"] = event.CheckpointInRace;
            record["checkpointInLap"] = event.CheckpointInLap;
            record["isEndLap"] = event.IsEndLap;
            record["isFinish"] = event.IsEndRace;
            record["lapTimeMs"] = event.LapTime;
        }
        if (name == "respawn") record["respawns"] = event.NbRespawns;
        if (name == "stunt") {
            record["speed"] = DiagnosticsRunNumber(event.Speed);
            record["damages"] = DiagnosticsRunNumber(event.Damages);
            record["figure"] = int(event.StuntFigure);
        }
        recorder.Emit(record);
    }
}
#endif
