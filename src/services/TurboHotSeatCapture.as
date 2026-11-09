#if TURBO
class HotSeatParticipant
{
    string id;
    string name;
}

class TurboHotSeatCapture
{
    WebhookDelivery@ delivery;
    CGamePlaygroundScript@ scopeScript;
    CGamePlaygroundUIConfig@ scopeUI;
    string mapUid;
    string sessionId;
    uint sequence;
    int generation = -1;
    int slot = -1;
    int previousSlot = -1;
    int previousTrigger;
    int previousHandover;
    bool baseline;
    bool valid;
    string scoredAttempt;
    array<HotSeatParticipant@> participants;

    TurboHotSeatCapture(WebhookDelivery@ sender) { @delivery = sender; }

    void Reset()
    {
        @scopeScript = null;
        @scopeUI = null;
        sessionId = "";
        mapUid = "";
        generation = -1;
        participants.Resize(0);
        slot = -1;
        previousSlot = -1;
        baseline = false;
        valid = false;
        scoredAttempt = "";
    }

    void BeforeRound(GameObservation@ observation)
    {
        valid = false;
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (observation is null || !observation.local || observation.mode is null || observation.mode.name != "hot-seat" ||
            !Setting_HotSeatScores || !CaptureEnabled() || app is null || app.Challenge is null ||
            app.Challenge.IdName.Length == 0 || app.CurrentPlayground is null ||
            app.CurrentPlayground.GameTerminals.Length != 1 || app.PlaygroundScript is null ||
            app.PlaygroundScript.ServerModeName != "TMC_HotSeat" || app.PlaygroundScript.UIManager is null) {
            Reset();
            return;
        }
        auto network = cast<CTrackManiaNetwork>(app.Network);
        if (network is null || network.TmRaceRules is null || TurboSecretModeType(network.TmRaceRules, "hot-seat").Length > 0) {
            Reset();
            return;
        }
        auto ui = app.PlaygroundScript.UIManager.LocalPlayerConfig;
        if (ui is null) { baseline = false; return; }
        string dump = app.PlaygroundScript.Dbg_DumpDeclareForVariables(ui, false);
        int phase, count, rosterGeneration, currentSlot, trigger, handover, enginePlayers;
        if (dump.Length > 65536 || !ReadTurboUiInteger(dump, "netread", "Net_GamePhase", phase) || phase < -1 || phase > 4) {
            baseline = false;
            return;
        }
        // The mode returns here on game restart/roster selection. Do not retain
        // human identities just because the shared engine player still exists.
        if (phase == -1 || phase == 4) { Reset(); return; }
        if (!ReadTurboUiInteger(dump, "netread", "Net_NbPlayers", enginePlayers) || enginePlayers != 1 ||
            !ReadTurboUiInteger(dump, "netread", "Net_NbPlayer", count) || count < 2 || count > 16 ||
            !ReadTurboUiInteger(dump, "netread", "Net_GamePhaseUIUpdate", rosterGeneration) || rosterGeneration < 0 ||
            !ReadTurboUiInteger(dump, "netread", "Net_CurPlayerIndex", currentSlot) || currentSlot < 0 || currentSlot >= count ||
            !ReadTurboUiInteger(dump, "netwrite", "LibTMC_ScoresTable_NewNameTrigger", trigger) || trigger < 0 ||
            !ReadTurboUiInteger(dump, "netread", "Net_CurPlayerUpdate", handover) || handover < 0) {
            baseline = false;
            return;
        }
        if (scopeScript !is app.PlaygroundScript || scopeUI !is ui || mapUid != app.Challenge.IdName ||
            generation != rosterGeneration || participants.Length != uint(count)) {
            Reset();
            @scopeScript = app.PlaygroundScript;
            @scopeUI = ui;
            mapUid = app.Challenge.IdName;
            generation = rosterGeneration;
            sessionId = CreateUuidV4();
            sequence = 0;
            participants.Resize(count);
            for (uint i = 0; i < participants.Length; i++) {
                @participants[i] = HotSeatParticipant();
                participants[i].id = CreateUuidV4();
            }
        }
        slot = currentSlot;
        valid = true;
        // Ignore stale initial names and ambiguous confirmation/slot switches.
        // The script confirms the name for the current slot before starting it.
        if (baseline && currentSlot == previousSlot && handover == previousHandover && trigger > 0 && trigger != previousTrigger && (phase == 0 || phase == 1)) {
            string name;
            if (ReadTurboUiText(dump, "netwrite", "LibTMC_ScoresTable_NewName", name) && name.Length > 0 && name != participants[slot].name) {
                participants[slot].name = name;
                CapturedEvent@ event = NewEvent("player_name", participants[slot].id);
                @event.player = PlayerSnapshot();
                event.player.name = name;
                Enqueue(event);
            }
        }
        previousSlot = currentSlot;
        previousHandover = handover;
        previousTrigger = trigger;
        baseline = true;
        if (observation !is null && observation.mode !is null && observation.mode.name == "hot-seat") {
            for (uint i = 0; i < observation.players.Length; i++) {
                observation.players[i].sessionId = sessionId;
                observation.players[i].participantId = participants[slot].id;
            }
        }
    }

    void AfterRound(RoundTracker@ round, GameObservation@ observation)
    {
        if (!valid || slot < 0 || !round.running || observation is null || !observation.active || round.sessionKey != observation.sessionKey) return;
        for (uint i = 0; i < observation.playerStates.Length; i++) {
            auto state = observation.playerStates[i];
            if (state is null || state.player is null || !state.finished || state.finishDurationMs < 0 || state.player.playerIndex >= round.roster.Length) continue;
            auto snapshot = round.roster[state.player.playerIndex];
            if (snapshot.sessionId != sessionId || snapshot.attemptId == scoredAttempt) continue;
            HotSeatParticipant@ owner;
            for (uint p = 0; p < participants.Length; p++) {
                if (participants[p].id == snapshot.participantId) { @owner = participants[p]; break; }
            }
            if (owner is null) continue;
            // The frozen attempt identity, not engine name/login or finish time,
            // owns this result. Do not relabel earlier serialized payloads.
            CapturedEvent@ event = NewEvent("score", owner.id);
            event.scoreMode = "hot-seat";
            event.mapUid = mapUid;
            event.timeMs = state.finishDurationMs;
            @event.player = PlayerSnapshot();
            event.player.attemptId = snapshot.attemptId;
            event.player.name = owner.name;
            scoredAttempt = snapshot.attemptId;
            Enqueue(event);
        }
    }

    CapturedEvent@ NewEvent(const string &in type, const string &in participantId)
    {
        CapturedEvent@ event = CapturedEvent();
        event.eventType = type;
        event.eventId = CreateUuidV4();
        event.occurredAt = OccurredAtUtc();
        event.sequence = sequence++;
        event.sessionId = sessionId;
        event.participantId = participantId;
        return event;
    }

    void Enqueue(CapturedEvent@ event)
    {
        delivery.Enqueue(event.eventId, event.eventType, event.sequence, SerializeEvent(event));
        print("[hot-seat] " + event.eventType + " participant=" + event.participantId + " sessionSequence=" + event.sequence);
    }
}
#endif
