#if TURBO
// Read only the verified scalar subset of Dbg_DumpDeclareForVariables.
// Unknown, duplicate, truncated or malformed values fail closed.
bool ReadTurboUiScalar(const string &in dump, const string &in section, const string &in type, const string &in key, string &out value)
{
    bool inSection = false;
    bool found = false;
    auto lines = dump.Split("\n");
    for (uint i = 0; i < lines.Length; i++) {
        string line = lines[i].Trim();
        if (line.StartsWith("netwrite:") || line.StartsWith("netread:") || line.StartsWith("persistent:")) {
            inSection = line.StartsWith(section + ":");
            continue;
        }
        if (!inSection) continue;
        int colon = line.IndexOf(":");
        if (colon < 1) continue;
        string definition = line.SubStr(colon + 1).Trim();
        if (!definition.StartsWith(type + " ")) continue;
        definition = definition.SubStr(type.Length).Trim();
        string prefix = key + " = ";
        if (!definition.StartsWith(prefix)) continue;
        if (found) return false;
        value = definition.SubStr(prefix.Length);
        found = true;
    }
    return found;
}

bool ReadTurboUiInteger(const string &in dump, const string &in section, const string &in key, int &out value)
{
    string raw;
    if (!ReadTurboUiScalar(dump, section, "Integer", key, raw) || raw.Length == 0 || raw.Length > 10) return false;
    uint start = raw.StartsWith("-") ? 1 : 0;
    if (start == raw.Length) return false;
    int64 number = 0;
    for (uint i = start; i < raw.Length; i++) {
        if (raw[i] < 48 || raw[i] > 57) return false;
        number = number * 10 + int(raw[i] - 48);
        if (number > (start == 1 ? int64(2147483648) : int64(2147483647))) return false;
    }
    value = int(start == 1 ? -number : number);
    return true;
}

class TurboArcadeCapture
{
    WebhookDelivery@ delivery;
    CGamePlaygroundScript@ scopeScript;
    CGamePlaygroundUIConfig@ scopeUI;
    string mapUid;
    string sessionId;
    string turnId;
    uint sequence;
    int previousPhase = -2;
    int previousCredits = -1;
    int previousTrigger;
    int scopePlayers = -1;
    bool baseline;
    bool valid;
    bool complete;
    bool overflow;
    uint attemptsAtCreditChange;
    int pendingIndex = -1;
    string submittedName;
    string lastRound;
    array<string> attempts;

    TurboArcadeCapture(WebhookDelivery@ sender) { @delivery = sender; }

    void ClearTurn()
    {
        turnId = "";
        attempts.Resize(0);
        submittedName = "";
        pendingIndex = -1;
        complete = false;
        overflow = false;
        attemptsAtCreditChange = 0;
        lastRound = "";
    }

    void Reset()
    {
        ClearTurn();
        sessionId = "";
        mapUid = "";
        @scopeScript = null;
        @scopeUI = null;
        baseline = false;
        valid = false;
        previousPhase = -2;
        previousCredits = -1;
        scopePlayers = -1;
    }

    void BeginTurn(bool full)
    {
        ClearTurn();
        turnId = CreateUuidV4();
        complete = full;
    }

    void BeforeRound(GameObservation@ observation)
    {
        valid = false;
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (!Setting_ArcadeScores || !CaptureEnabled() || app is null || app.CurrentPlayground is null || app.Challenge is null ||
            app.PlaygroundScript is null || app.PlaygroundScript.UIManager is null ||
            app.Challenge.IdName.Length == 0 || app.CurrentPlayground.GameTerminals.Length != 1 || app.PlaygroundScript.ServerModeName != "TMC_LocalArcade") {
            Reset();
            return;
        }
        auto network = cast<CTrackManiaNetwork>(app.Network);
        if (network is null || network.TmRaceRules is null || TurboSecretModeType(network.TmRaceRules, "arcade").Length > 0) {
            Reset();
            return;
        }
        auto ui = app.PlaygroundScript.UIManager.LocalPlayerConfig;
        if (ui is null) {
            ClearTurn();
            baseline = false;
            return;
        }
        if (scopeScript !is app.PlaygroundScript || scopeUI !is ui || mapUid != app.Challenge.IdName) {
            Reset();
            @scopeScript = app.PlaygroundScript;
            @scopeUI = ui;
            mapUid = app.Challenge.IdName;
            sessionId = CreateUuidV4();
            sequence = 0;
        }
        string dump = app.PlaygroundScript.Dbg_DumpDeclareForVariables(ui, false);
        int phase, credits, trigger, index, players;
        if (dump.Length > 65536 || !ReadTurboUiInteger(dump, "netread", "Net_NbPlayers", players) || players < 1 || players > 2 || !ReadTurboUiInteger(dump, "netread", "Net_GamePhase", phase) ||
            !ReadTurboUiInteger(dump, "netread", "Net_Credits_Count", credits) ||
            !ReadTurboUiInteger(dump, "netwrite", "LibTMC_ScoresTable_NewNameTrigger", trigger) ||
            !ReadTurboUiInteger(dump, "netread", "LibTMC_ScoresTable_NewScoreIndex", index) ||
            phase < -1 || phase > 4 || credits < 0 || credits > 2 || trigger < 0 || index < -1 || index > 9) {
            // Do not retain another turn's attempts across a gap in lifecycle data.
            ClearTurn();
            baseline = false;
            return;
        }
        if (scopePlayers >= 0 && players != scopePlayers) {
            ClearTurn();
            baseline = false;
            sessionId = CreateUuidV4();
            sequence = 0;
            previousPhase = -2;
            previousCredits = -1;
        }
        scopePlayers = players;
        valid = true;
        bool replaced = baseline && ((previousPhase == -1 && phase >= 0) ||
            (credits > previousCredits && credits == 2 && phase <= 1));
        if (replaced) BeginTurn(previousPhase == -1 && phase == 0 && credits == 2);
        else if (turnId.Length == 0 && phase >= 0) BeginTurn(false);

        if (!replaced && baseline && credits < previousCredits) {
            if (previousCredits - credits != 1 || attempts.Length <= attemptsAtCreditChange) complete = false;
            attemptsAtCreditChange = attempts.Length;
        }
        if (baseline && previousPhase != 3 && phase == 3 && attempts.Length <= attemptsAtCreditChange) complete = false;
        if (index >= 0 && turnId.Length > 0) pendingIndex = index;
        if (baseline && trigger != previousTrigger && trigger > 0 && pendingIndex >= 0 && turnId.Length > 0) {
            submittedName = "";
            string raw;
            if ((phase == 3 || phase == -1) && ReadTurboUiScalar(dump, "netwrite", "Text", "LibTMC_ScoresTable_NewName", raw)) {
                try {
                    Json::Value@ name = Json::Parse(raw);
                    if (name.GetType() == Json::Type::String) submittedName = string(name);
                } catch { submittedName = ""; }
            }
        }
        previousTrigger = trigger;
        previousPhase = phase;
        previousCredits = credits;
        baseline = true;
        // Commit is observed separately from the transient ScoreWritten boolean.
        // WriteName clears the insertion index; a timeout never advances trigger.
        if (submittedName.Length > 0 && index == -1 && (phase == 3 || phase == -1) && !overflow) EmitScore();
        if (phase == -1 && submittedName.Length == 0) ClearTurn();
        if (turnId.Length > 0 && observation !is null && observation.mode !is null && observation.mode.name == "arcade") {
            for (uint i = 0; i < observation.players.Length; i++) {
                observation.players[i].sessionId = sessionId;
                observation.players[i].turnId = turnId;
            }
        }
    }

    void AfterRound(RoundTracker@ round)
    {
        if (!valid || turnId.Length == 0 || !round.running || round.gameId == lastRound) return;
        lastRound = round.gameId;
        for (uint i = 0; i < round.roster.Length; i++) {
            auto player = round.roster[i];
            if (player.sessionId != sessionId || player.turnId != turnId) { complete = false; continue; }
            if (attempts.Length >= 256) {
                if (!overflow) warn("[arcade] Turn exceeded 256 captured attempts; score suppressed.");
                overflow = true;
                continue;
            }
            attempts.InsertLast(player.attemptId);
        }
    }

    void EmitScore()
    {
        CapturedEvent@ event = CapturedEvent();
        event.eventType = "score";
        event.eventId = CreateUuidV4();
        event.occurredAt = OccurredAtUtc();
        event.sequence = sequence++;
        event.sessionId = sessionId;
        event.turnId = turnId;
        event.mapUid = mapUid;
        event.attemptIds = attempts;
        event.captureComplete = complete;
        @event.player = PlayerSnapshot();
        event.player.name = submittedName;
        delivery.Enqueue(event.eventId, event.eventType, event.sequence, SerializeEvent(event));
        print("[arcade] Confirmed score name=" + submittedName + " capturedAttempts=" + attempts.Length);
        ClearTurn();
    }
}
#endif
