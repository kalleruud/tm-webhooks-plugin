#if TURBO
class TurboGameAdapter : GameAdapter
{
    string lastMap;
    string diagnosticState;
    string activeSessionKey;
    bool startArmed;
    bool roundCompleted;
    string pendingEndReason;
    string launchModeHint;
    int arcadeRoundCredits = -1;
    bool observedRound;
    bool waitingForEnd;
    bool restartCandidate;
    uint endPendingSince;

    GameObservation@ Observe()
    {
        GameObservation@ observation = GameObservation();
        CGameManiaPlanet@ app = cast<CGameManiaPlanet>(GetApp());
        if (app is null) {
            LogTurboState("app", "Turbo capture waiting for the game application.");
            return observation;
        }
        RememberTurboLaunchMode(app);
        if (app.CurrentPlayground is null) {
            LogTurboState("playground", "Turbo capture waiting for a playground.");
            return observation;
        }
        if (app.Challenge is null) {
            LogTurboState("map", "Turbo capture waiting for a map.");
            return observation;
        }
        if (app.PlaygroundScript is null || app.PlaygroundScript.UIManager is null) {
            LogTurboState("script", "Turbo capture waiting for the playground script.");
            return observation;
        }
        auto playground = app.CurrentPlayground;
        observation.local = playground.GameTerminals.Length > 0;
        if (!observation.local) {
            LogTurboState("local", "Turbo capture paused: no local game terminal was detected.");
            return observation;
        }
        if (lastMap != app.Challenge.IdName) {
            lastMap = app.Challenge.IdName;
            activeSessionKey = "";
            startArmed = false;
            roundCompleted = false;
            pendingEndReason = "";
            observedRound = false;
            waitingForEnd = false;
            restartCandidate = false;
            arcadeRoundCredits = -1;
        }
        @observation.map = ReadTurboMap(app);
        auto uiConfig = app.PlaygroundScript.UIManager.LocalPlayerConfig;
        bool playingSequence = uiConfig !is null &&
            (uiConfig.UISequence == CGamePlaygroundUIConfig::EUISequence::Playing ||
            uiConfig.UISequence == CGamePlaygroundUIConfig::EUISequence::EndRound);
        for (uint i = 0; i < playground.Players.Length; i++) {
            auto tmPlayer = cast<CTrackManiaPlayer>(playground.Players[i]);
            if (tmPlayer is null || tmPlayer.EnableOnlineMode || tmPlayer.AutoPilotEnabled) continue;
            if (tmPlayer.RaceState == CTrackManiaPlayer::ERaceState::BeforeStart) {
                if (activeSessionKey.Length > 0) {
                    if (roundCompleted) pendingEndReason = "completed";
                    else if (pendingEndReason != "aborted") pendingEndReason = "restarted";
                }
                startArmed = true;
                activeSessionKey = "";
                continue;
            }
            if (tmPlayer.RaceState == CTrackManiaPlayer::ERaceState::Eliminated) {
                if (activeSessionKey.Length > 0) pendingEndReason = "aborted";
                continue;
            }
            bool racing = tmPlayer.RaceState == CTrackManiaPlayer::ERaceState::Running ||
                tmPlayer.RaceState == CTrackManiaPlayer::ERaceState::Finished;
            if (!racing || !playingSequence || tmPlayer.RaceStartTime == 0) continue;
            string candidateSessionKey = lastMap + ":" + tmPlayer.RaceStartTime;
            if (activeSessionKey.Length == 0) {
                if (!startArmed) continue;
                activeSessionKey = candidateSessionKey;
                startArmed = false;
                roundCompleted = false;
                pendingEndReason = "";
                arcadeRoundCredits = -1;
                int phase, credits;
                if (ReadArcadeEndState(app, phase, credits)) arcadeRoundCredits = credits;
            }
            if (candidateSessionKey != activeSessionKey) continue;
            PlayerSnapshot@ player = PlayerSnapshot();
            player.playerIndex = observation.players.Length;
            player.name = tmPlayer.Name;
            player.login = tmPlayer.Login;
            observation.players.InsertLast(player);
            PlayerObservation@ state = PlayerObservation();
            @state.player = player;
            state.durationMs = app.PlaygroundScript.Now > tmPlayer.RaceStartTime
                ? app.PlaygroundScript.Now - tmPlayer.RaceStartTime
                : 0;
            state.throttle = tmPlayer.InputGasPedal;
            state.respawnCount = tmPlayer.NbRespawns;
            state.finished = tmPlayer.RaceState == CTrackManiaPlayer::ERaceState::Finished;
            state.lapNumber = tmPlayer.CurLapIndex == 0 ? 1 : tmPlayer.CurLapIndex;
            if (state.finished && state.lapNumber > 1) state.lapNumber--;
            if (observation.map.totalLaps > 0 && state.lapNumber > observation.map.totalLaps) {
                state.lapNumber = observation.map.totalLaps;
            }
            if (tmPlayer.CurRace !is null) {
                state.checkpointIndex = tmPlayer.CurRace.Checkpoints.Length;
                if (tmPlayer.CurCheckpointRaceTime > 0) {
                    state.checkpointDurationMs = tmPlayer.CurCheckpointRaceTime;
                }
            }
            if (tmPlayer.CurLap !is null) state.checkpointLapIndex = tmPlayer.CurLap.Checkpoints.Length;
            if (state.finished && tmPlayer.CurRace !is null && tmPlayer.CurRace.Time >= 0) {
                state.finishDurationMs = tmPlayer.CurRace.Time;
            }
            roundCompleted = roundCompleted || state.finished;
            observation.playerStates.InsertLast(state);
        }
        bool splitScreen = playground.GameTerminals.Length > 1 || observation.players.Length > 1;
        @observation.mode = ReadTurboMode(app, splitScreen, launchModeHint);
        observation.active = observation.local && !observation.playerStates.IsEmpty();
        if (observation.active) {
            observedRound = true;
            waitingForEnd = false;
            observation.sessionKey = activeSessionKey;
            LogTurboState("active", "Turbo capture detected an active local round with " + observation.players.Length + " player(s).");
        } else {
            observation.endReason = pendingEndReason.Length > 0
                ? pendingEndReason
                : (roundCompleted ? "completed" : "unknown");
            // Mode state can lag the player's reset by several frames. The live
            // cancel traces show credits 2->1 and 1->0 after the inactive frame.
            bool standardArcade = observation.mode !is null && observation.mode.name == "arcade";
            if (observedRound && !roundCompleted && standardArcade &&
                (observation.endReason == "restarted" || observation.endReason == "unknown")) {
                int phase, credits;
                observation.endReason = "unknown";
                if (!waitingForEnd) { waitingForEnd = true; restartCandidate = false; endPendingSince = Time::Now; }
                bool haveState = ReadArcadeEndState(app, phase, credits);
                if (haveState) {
                    if (phase == 2 || phase == 3 || (arcadeRoundCredits >= 0 && credits < arcadeRoundCredits)) {
                        observation.endReason = "aborted";
                    } else if (phase == 0 && arcadeRoundCredits >= 0 && credits == arcadeRoundCredits) {
                        restartCandidate = true;
                    }
                }
                if (observation.endReason == "unknown") {
                    if (Time::Now - endPendingSince < 250) {
                        observation.pendingEnd = true;
                        return observation;
                    }
                    if (haveState && restartCandidate && credits == arcadeRoundCredits) observation.endReason = "restarted";
                }
            }
            observedRound = false;
            waitingForEnd = false;
            pendingEndReason = "";
            LogTurboState("players", "Turbo capture armed and waiting for the race timer to start.");
        }
        return observation;
    }

    bool ReadArcadeEndState(CGameManiaPlanet@ app, int &out phase, int &out credits)
    {
        if (app.PlaygroundScript is null || app.PlaygroundScript.UIManager is null ||
            app.PlaygroundScript.ServerModeName != "TMC_LocalArcade") return false;
        auto ui = app.PlaygroundScript.UIManager.LocalPlayerConfig;
        auto network = cast<CTrackManiaNetwork>(app.Network);
        if (ui is null || network is null || network.TmRaceRules is null || TurboSecretModeType(network.TmRaceRules, "arcade").Length > 0) return false;
        try {
            string dump = app.PlaygroundScript.Dbg_DumpDeclareForVariables(ui, false);
            return dump.Length <= 65536 && ReadTurboUiInteger(dump, "netread", "Net_GamePhase", phase) &&
                ReadTurboUiInteger(dump, "netread", "Net_Credits_Count", credits) && phase >= -1 && phase <= 4 && credits >= 0 && credits <= 2;
        } catch { return false; }
    }

    void LogTurboState(const string &in state, const string &in message)
    {
        if (state == diagnosticState) return;
        diagnosticState = state;
        print("[detect] " + message);
    }

    void RememberTurboLaunchMode(CGameManiaPlanet@ app)
    {
        for (uint i = 0; i < app.ActiveMenus.Length; i++) {
            auto menu = app.ActiveMenus[i];
            if (menu is null) continue;
            string hint = TurboModeHint(menu.IdName);
            if (hint.Length > 0) launchModeHint = hint;
        }
    }
}

MapSnapshot@ ReadTurboMap(CGameManiaPlanet@ app)
{
    MapSnapshot@ map = MapSnapshot();
    auto challenge = app.Challenge;
    map.name = challenge.MapName;
    map.uid = challenge.IdName;
    map.author = challenge.AuthorNickName;
    map.environment = challenge.CollectionName;
    map.mapType = challenge.MapType;
    map.isLaps = challenge.TMObjective_IsLapRace;
    map.totalLaps = challenge.TMObjective_NbLaps;
    map.authorTime = challenge.TMObjective_AuthorTime;
    map.goldTime = challenge.TMObjective_GoldTime;
    map.silverTime = challenge.TMObjective_SilverTime;
    map.bronzeTime = challenge.TMObjective_BronzeTime;
    auto network = cast<CTrackManiaNetwork>(app.Network);
    if (network !is null && network.TmRaceRules !is null) {
        map.checkpointsPerLap = network.TmRaceRules.MapCheckpointPos.Length;
        if (map.totalLaps == 0) map.totalLaps = network.TmRaceRules.MapNbLaps;
    }
    return map;
}

ModeSnapshot@ ReadTurboMode(
    CGameManiaPlanet@ app,
    bool splitScreen,
    const string &in launchModeHint
)
{
    ModeSnapshot@ mode = ModeSnapshot();
    string localMode = TurboLocalModeName(app, splitScreen, launchModeHint);

    auto network = cast<CTrackManiaNetwork>(app.Network);
    CTrackManiaRaceRules@ rules;
    if (network !is null) @rules = network.TmRaceRules;
    string secretType = TurboSecretModeType(rules, localMode);
    if (secretType.Length > 0) {
        mode.name = "secret";
        mode.modeType = secretType;
    } else {
        mode.name = localMode;
    }
    return mode;
}

string TurboLocalModeName(
    CGameManiaPlanet@ app,
    bool splitScreen,
    const string &in launchModeHint
)
{
    if (splitScreen) return "split-screen";

    string runtimeModeHint = TurboRuntimeModeHint(app);
    if (runtimeModeHint.Length > 0) return runtimeModeHint;
    if (launchModeHint.Length > 0) return launchModeHint;
    if (app.CurrentCampaign !is null) return "campaign";
    return "unknown";
}

string TurboRuntimeModeHint(CGameManiaPlanet@ app)
{
    string hint = TurboModeHint(app.PlaygroundScript.ServerModeName);
    if (hint.Length > 0) return hint;

    hint = TurboModeHint(app.PlaygroundScript.IdName);
    if (hint.Length > 0) return hint;

    auto network = cast<CTrackManiaNetwork>(app.Network);
    if (network !is null && network.TmRaceRules !is null && network.TmRaceRules.Script !is null) {
        hint = TurboModeHint(network.TmRaceRules.Script.IdName);
    }
    return hint;
}

string TurboModeHint(const string &in value)
{
    string normalized = value.ToLower();
    if (normalized.Contains("hotseat") || normalized.Contains("hot-seat") || normalized.Contains("hot_seat")) {
        return "hot-seat";
    }
    if (normalized.Contains("splitscreen") || normalized.Contains("split-screen") || normalized.Contains("split_screen")) {
        return "split-screen";
    }
    if (normalized.Contains("arcade")) return "arcade";
    if (normalized.Contains("campaign")) return "campaign";
    return "";
}

string TurboSecretModeType(CTrackManiaRaceRules@ rules, const string &in localMode)
{
    if (rules is null) return "";
    if (localMode != "split-screen" && localMode != "arcade" && localMode != "hot-seat") return "";

    string variant;
    if (rules.EnableBonusEvents) {
        variant = "bonus";
    } else if (rules.UiStuntsMode) {
        variant = "stunt";
    } else if (rules.EnableCheckpointBonus) {
        variant = "smash";
    } else if (rules.EnableUniqueCamera) {
        variant = "mono-screen";
    } else if (localMode == "split-screen" && rules.EnableCollisions) {
        variant = "classic";
    } else {
        return "";
    }

    string type = localMode + "-" + variant;
    if (localMode == "split-screen") type += rules.EnableScaleCar ? "-fun" : "-pro";
    return type;
}
#endif
