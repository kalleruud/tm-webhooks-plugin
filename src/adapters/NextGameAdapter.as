#if TMNEXT
class NextGameAdapter : GameAdapter
{
    string lastMap;
    bool roundActive;
    bool roundCompleted;
    bool replacementSpawnPending;
    uint activeSpawnIndex;
    uint observationIndex;
    uint replacementObservedAt;
    uint replacementSpawnIndex;

    GameObservation@ Observe()
    {
        observationIndex++;
        GameObservation@ observation = GameObservation();
        CTrackMania@ app = cast<CTrackMania>(GetApp());
        if (app is null || app.CurrentPlayground is null || app.RootMap is null) {
            EndInterruptedRound(observation);
            return observation;
        }
        auto playground = app.CurrentPlayground;
        observation.local = app.Network !is null && app.Network.PlaygroundClientScriptAPI !is null &&
            app.Network.PlaygroundClientScriptAPI.IsServerOrSolo;
        @observation.map = ReadNextMap(app);
        if (lastMap != app.RootMap.IdName) {
            bool mapChangedDuringRound = lastMap.Length > 0 && roundActive;
            lastMap = app.RootMap.IdName;
            ResetRound();
            if (mapChangedDuringRound) {
                observation.local = true;
                observation.endReason = "aborted";
                return observation;
            }
        }
        bool playerDriving;
        for (uint i = 0; i < playground.GameTerminals.Length; i++) {
            auto terminal = playground.GameTerminals[i];
            if (terminal.UISequence_Current != SGamePlaygroundUIConfig::EUISequence::Playing) continue;
            if (terminal.GUIPlayer is null || terminal.ControlledPlayer is null) continue;
            if (terminal.GUIPlayer.User.Id.Value != terminal.ControlledPlayer.User.Id.Value) continue;
            playerDriving = true;
            break;
        }
        auto race = MLFeed::GetRaceData_V4();
        bool replacementCandidateObserved;
        bool replacementSpawnReady;
        for (uint i = 0; i < playground.Players.Length; i++) {
            auto smPlayer = cast<CSmPlayer>(playground.Players[i]);
            if (smPlayer is null) continue;
            auto feedPlayer = race.GetPlayer_V4(smPlayer.User.Name);
            if (feedPlayer is null) continue;
            int raceTime = feedPlayer.CurrentRaceTime;
            bool readyToStart = feedPlayer.PlayerIsRacing &&
                feedPlayer.SpawnStatus == MLFeed::SpawnStatus::Spawned && raceTime >= 0;
            if (roundActive && readyToStart && feedPlayer.SpawnIndex != activeSpawnIndex) {
                replacementCandidateObserved = true;
                if (ConfirmReplacementSpawn(feedPlayer.SpawnIndex, playerDriving)) {
                    replacementSpawnReady = true;
                }
                continue;
            }
            if (!roundActive && playerDriving && readyToStart) {
                activeSpawnIndex = feedPlayer.SpawnIndex;
                roundActive = true;
                roundCompleted = false;
                replacementSpawnPending = false;
            }
            if (!roundActive || !feedPlayer.PlayerIsRacing || feedPlayer.SpawnIndex != activeSpawnIndex) continue;
            PlayerSnapshot@ player = PlayerSnapshot();
            player.playerIndex = observation.players.Length;
            player.name = smPlayer.User.Name;
            player.login = feedPlayer.Login;
            if (feedPlayer.Login.Length > 0) player.localId = "" + feedPlayer.LoginMwId.Value;
            player.accountId = feedPlayer.WebServicesUserId;
            observation.players.InsertLast(player);
            PlayerObservation@ state = PlayerObservation();
            @state.player = player;
            state.durationMs = uint(raceTime);
            state.throttle = ReadNextPlayerThrottle(app, smPlayer);
            state.checkpointDurationMs = Math::Max(0, feedPlayer.LastCpTime);
            state.checkpointIndex = Math::Max(0, feedPlayer.CpCount);
            state.checkpointLapIndex = race.CPCount == 0 ? state.checkpointIndex : state.checkpointIndex % race.CPCount;
            state.respawnCount = feedPlayer.NbRespawnsRequested;
            state.finished = feedPlayer.IsFinished;
            state.lapNumber = feedPlayer.CurrentLap == 0 ? 1 : feedPlayer.CurrentLap;
            if (state.finished && state.lapNumber > 1) state.lapNumber--;
            if (observation.map.totalLaps > 0 && state.lapNumber > observation.map.totalLaps) {
                state.lapNumber = observation.map.totalLaps;
            }
            if (state.finished) state.finishDurationMs = Math::Max(0, feedPlayer.FinishTime);
            state.theoreticalDurationMs = feedPlayer.LastTheoreticalCpTime;
            state.lostMs = feedPlayer.TimeLostToRespawns;
            roundCompleted = roundCompleted || state.finished;
            observation.playerStates.InsertLast(state);
        }
        if (!replacementCandidateObserved && !observation.playerStates.IsEmpty()) {
            replacementSpawnPending = false;
        }
        bool splitScreen = playground.GameTerminals.Length > 1 || observation.players.Length > 1;
        @observation.mode = ReadNextMode(app, splitScreen);
        observation.active = observation.local && !observation.playerStates.IsEmpty();
        if (observation.active) {
            observation.sessionKey = app.RootMap.IdName + ":" + activeSpawnIndex;
        } else if (roundActive && !roundCompleted && !replacementSpawnReady) {
            observation.active = true;
            observation.sessionKey = app.RootMap.IdName + ":" + activeSpawnIndex;
        } else {
            if (roundActive) observation.local = true;
            observation.endReason = roundCompleted
                ? "completed"
                : (replacementSpawnReady ? "restarted" : "aborted");
            ResetRound();
        }
        return observation;
    }

    bool ConfirmReplacementSpawn(uint candidateSpawnIndex, bool playerDriving)
    {
        if (!replacementSpawnPending || replacementSpawnIndex != candidateSpawnIndex) {
            replacementSpawnPending = true;
            replacementSpawnIndex = candidateSpawnIndex;
            replacementObservedAt = observationIndex;
            return false;
        }
        return playerDriving && replacementObservedAt < observationIndex;
    }

    void EndInterruptedRound(GameObservation@ observation)
    {
        if (!roundActive) return;
        observation.local = true;
        observation.endReason = "aborted";
        ResetRound();
    }

    void ResetRound()
    {
        roundActive = false;
        roundCompleted = false;
        replacementSpawnPending = false;
    }
}

float ReadNextPlayerThrottle(CTrackMania@ app, CSmPlayer@ player)
{
    if (app.GameScene !is null) {
        auto vehicle = VehicleState::GetVis(app.GameScene, player);
        if (vehicle !is null && vehicle.AsyncState !is null) return vehicle.AsyncState.InputGasPedal;
    }
    if (app.CurrentPlayground.GameTerminals.Length != 1) return 0;
    auto viewedVehicle = VehicleState::ViewingPlayerState();
    return viewedVehicle is null ? 0 : viewedVehicle.InputGasPedal;
}

MapSnapshot@ ReadNextMap(CTrackMania@ app)
{
    MapSnapshot@ map = MapSnapshot();
    map.name = app.RootMap.MapName;
    map.uid = app.RootMap.IdName;
    map.author = app.RootMap.AuthorNickName;
    map.environment = app.RootMap.CollectionName;
    map.mapType = app.RootMap.MapType;
    map.level = MapDifficultyLevel(uint(app.RootMap.Difficulty));
    map.isLaps = app.RootMap.TMObjective_IsLapRace;
    map.authorTime = app.RootMap.TMObjective_AuthorTime;
    map.goldTime = app.RootMap.TMObjective_GoldTime;
    map.silverTime = app.RootMap.TMObjective_SilverTime;
    map.bronzeTime = app.RootMap.TMObjective_BronzeTime;
    auto race = MLFeed::GetRaceData_V4();
    map.totalLaps = race.LapCount;
    map.checkpointsPerLap = race.CPCount;
    return map;
}

ModeSnapshot@ ReadNextMode(CTrackMania@ app, bool splitScreen)
{
    ModeSnapshot@ mode = ModeSnapshot();
    mode.name = NextModeName(app, splitScreen);
    if (mode.name == "campaign") return mode;

    auto network = cast<CTrackManiaNetwork>(app.Network);
    if (network is null) return mode;
    auto serverInfo = cast<CTrackManiaNetworkServerInfo>(network.ServerInfo);
    if (serverInfo is null) return mode;

    mode.modeType = NextModeType(app, serverInfo, splitScreen);
    return mode;
}

string NextModeName(CTrackMania@ app, bool splitScreen)
{
    if (splitScreen) return "split-screen";
    if (NextServerModeName(app).Contains("tm_campaign_")) return "campaign";
    return "solo";
}

string NextServerModeName(CTrackMania@ app)
{
    if (app.PlaygroundScript is null) return "";
    return string(app.PlaygroundScript.ServerModeName).ToLower();
}

string NextModeType(CTrackMania@ app, CTrackManiaNetworkServerInfo@ serverInfo, bool splitScreen)
{
    string scriptMode = NextScriptModeType(NextModeIdentifiers(app, serverInfo));
    if (scriptMode.Length > 0) return scriptMode;
    return NextLegacyModeType(serverInfo.CurGameMode_Script, splitScreen);
}

string NextModeIdentifiers(CTrackMania@ app, CTrackManiaNetworkServerInfo@ serverInfo)
{
    return (NextServerModeName(app) + " " + string(serverInfo.CurGameModeStr) + " " +
        string(serverInfo.CurScriptRelName)).ToLower();
}

string NextScriptModeType(const string &in scriptName)
{
    if (scriptName.Contains("tm_royaltimeattack_")) return "royal-time-attack";
    if (scriptName.Contains("tm_timeattack_")) return "time-attack";
    if (scriptName.Contains("tm_platform_")) return "platform";
    if (scriptName.Contains("tm_rounds_")) return "rounds";
    if (scriptName.Contains("tm_laps_")) return "laps";
    if (scriptName.Contains("tm_cup_")) return "cup";
    return "";
}

string NextLegacyModeType(CTrackManiaNetworkServerInfo::EGameMode_Script gameMode, bool splitScreen)
{
    if (gameMode == CTrackManiaNetworkServerInfo::EGameMode_Script::TimeAttack) return "time-attack";
    if (gameMode == CTrackManiaNetworkServerInfo::EGameMode_Script::Rounds) return "rounds";
    if (gameMode == CTrackManiaNetworkServerInfo::EGameMode_Script::Laps) return "laps";
    if (gameMode == CTrackManiaNetworkServerInfo::EGameMode_Script::Cup) return "cup";
    if (splitScreen) return "unknown";
    if (gameMode == CTrackManiaNetworkServerInfo::EGameMode_Script::Team) return "team";
    if (gameMode == CTrackManiaNetworkServerInfo::EGameMode_Script::Stunts) return "stunts";
    return "";
}
#endif
