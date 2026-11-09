class TrackedPlayer
{
    bool throttled;
    bool finished;
    uint checkpointIndex;
    uint respawnCount;
}

class RoundTracker
{
    WebhookDelivery@ delivery;
    bool running;
    string gameId;
    string sessionKey;
    uint sequence;
    uint lastDurationMs;
    array<PlayerSnapshot@> roster;
    array<TrackedPlayer@> tracked;
    MapSnapshot@ roundMap;

    RoundTracker(WebhookDelivery@ sender) { @delivery = sender; }

    void Update(GameObservation@ observation)
    {
        if (observation is null || !observation.local || !CaptureEnabled()) {
            if (running && (observation is null || !observation.active)) Stop("aborted");
            return;
        }
        if (!observation.active) {
            if (running) Stop(observation.endReason);
            return;
        }
        if (!running || observation.sessionKey != sessionKey) {
            if (running) Stop("restarted");
            Start(observation);
        }
        CapturePlayers(observation.playerStates);
    }

    void Start(GameObservation@ observation)
    {
        running = true;
        gameId = CreateUuidV4();
        sessionKey = observation.sessionKey;
        sequence = 0;
        lastDurationMs = 0;
        // Own the snapshots: adapters may reuse their objects on a later frame.
        // Allocate before start so every event for this attempt shares its UUID.
        roster.Resize(0);
        for (uint i = 0; i < observation.players.Length; i++) {
            PlayerSnapshot@ source = observation.players[i];
            PlayerSnapshot@ player = PlayerSnapshot();
            player.playerIndex = source.playerIndex;
            player.attemptId = CreateUuidV4();
            player.name = source.name;
            player.login = source.login;
            player.localId = source.localId;
            player.accountId = source.accountId;
            roster.InsertLast(player);
        }
        @roundMap = observation.map;
        tracked.Resize(roster.Length);
        for (uint i = 0; i < tracked.Length; i++) @tracked[i] = TrackedPlayer();
        CapturedEvent@ event = NewEvent("start", 0);
        event.players = roster;
        @event.map = observation.map;
        @event.mode = observation.mode;
        Enqueue(event);
    }

    void CapturePlayers(array<PlayerObservation@>@ states)
    {
        for (uint i = 0; i < states.Length; i++) {
            PlayerObservation@ state = states[i];
            if (state is null || state.player is null || state.player.playerIndex >= tracked.Length) continue;
            uint index = state.player.playerIndex;
            lastDurationMs = Math::Max(lastDurationMs, state.durationMs);
            TrackedPlayer@ previous = tracked[index];
            if (!previous.throttled && state.throttle > 0) {
                previous.throttled = true;
                EmitPlayerEvent("first_throttle", state, state.durationMs);
            }
            if (state.checkpointIndex > previous.checkpointIndex) {
                string type = state.finished ? "finish" : (state.checkpointLapIndex == 0 ? "lap" : "checkpoint");
                previous.checkpointIndex = state.checkpointIndex;
                uint eventDurationMs = state.durationMs;
                if (type == "finish" && state.finishDurationMs >= 0) {
                    eventDurationMs = uint(state.finishDurationMs);
                } else if (state.checkpointDurationMs >= 0) {
                    eventDurationMs = uint(state.checkpointDurationMs);
                }
                if (!previous.finished) EmitPlayerEvent(type, state, eventDurationMs);
            }
            while (previous.respawnCount < state.respawnCount) {
                previous.respawnCount++;
                EmitPlayerEvent("respawn", state, state.durationMs);
            }
            previous.finished = previous.finished || state.finished;
        }
    }

    void EmitPlayerEvent(const string &in type, PlayerObservation@ state, uint durationMs)
    {
        CapturedEvent@ event = NewEvent(type, durationMs);
        @event.player = roster[state.player.playerIndex];
        event.checkpointIndex = state.checkpointIndex;
        if (type == "lap") {
            event.checkpointLapIndex = 0;
        } else if (type == "finish" && roundMap !is null) {
            event.checkpointLapIndex = roundMap.checkpointsPerLap + 1;
        } else {
            event.checkpointLapIndex = state.checkpointLapIndex;
        }
        event.lapNumber = state.lapNumber;
        event.theoreticalDurationMs = state.theoreticalDurationMs;
        event.lostMs = state.lostMs;
        Enqueue(event);
    }

    void Stop(const string &in reason)
    {
        if (!running) return;
        CapturedEvent@ event = NewEvent("end", lastDurationMs);
        event.endReason = NormalizeEndReason(reason);
        Enqueue(event);
        running = false;
        roster.Resize(0);
        tracked.Resize(0);
        @roundMap = null;
    }

    CapturedEvent@ NewEvent(const string &in type, uint durationMs)
    {
        CapturedEvent@ event = CapturedEvent();
        event.eventType = type;
        event.eventId = CreateUuidV4();
        event.gameId = gameId;
        event.sequence = sequence++;
        event.occurredAt = OccurredAtUtc();
        event.durationMs = durationMs;
        event.totalPlayers = roster.Length;
        return event;
    }

    void Enqueue(CapturedEvent@ event)
    {
        print("[emit] " + event.sequence + " " + event.eventType + " " + event.durationMs + "ms");
        delivery.Enqueue(event.eventId, event.eventType, event.sequence, SerializeEvent(event));
    }

}

bool CaptureEnabled() { return Setting_EndpointUrl.Length > 0; }

string NormalizeEndReason(const string &in reason)
{
    if (reason == "completed" || reason == "restarted" || reason == "aborted") return reason;
    return "unknown";
}
