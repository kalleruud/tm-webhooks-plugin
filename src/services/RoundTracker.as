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
    array<AttemptSnapshot@> attempts;
    array<string> sourceParticipants;
    array<TrackedPlayer@> tracked;
    MapSnapshot@ roundMap;

    RoundTracker(WebhookDelivery@ sender) { @delivery = sender; }

    void Update(GameObservation@ observation)
    {
        if (observation is null || !observation.local || !CaptureEnabled()) {
            if (running && (observation is null || !observation.active)) Stop("aborted");
            return;
        }
        // Turbo may need a few frames for its mode to publish an end reason.
        // Keep the frozen round without replaying stale player observations.
        if (observation.pendingEnd && running) return;
        if (!observation.active) {
            if (running) Stop(observation.endReason);
            return;
        }
        if (!running || observation.sessionKey != sessionKey) {
            if (running) Stop("restarted");
            Start(observation);
        }
        CapturePlayers(observation);
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
        attempts.Resize(0);
        sourceParticipants.Resize(0);
        for (uint i = 0; i < observation.players.Length; i++) {
            PlayerSnapshot@ source = observation.players[i];
            PlayerSnapshot@ player = PlayerSnapshot();
            player.playerIndex = source.playerIndex;
            AttemptSnapshot@ attempt = AttemptSnapshot();
            attempt.playerIndex = source.playerIndex;
            attempt.attemptId = CreateUuidV4();
            auto context = observation.attempts[i];
            attempt.participantId = context.participantId;
            sourceParticipants.InsertLast(context.participantId);
            // A shared engine racer cannot identify unverified human handovers.
            if (context.sessionId.Length == 0 && observation.sharedRacer) {
                attempt.participantId = CreateUuidV4();
            }
            attempt.sessionId = context.sessionId;
            attempt.turnId = context.turnId;
            attempts.InsertLast(attempt);
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
        event.attempts = attempts;
        @event.map = observation.map;
        @event.mode = observation.mode;
        Enqueue(event);
    }

    void CapturePlayers(GameObservation@ observation)
    {
        auto states = observation.playerStates;
        for (uint i = 0; i < states.Length; i++) {
            PlayerObservation@ state = states[i];
            if (state is null || state.player is null || state.player.playerIndex >= observation.attempts.Length) continue;
            string participant = observation.attempts[state.player.playerIndex].participantId;
            int matched = -1;
            for (uint p = 0; p < sourceParticipants.Length; p++) {
                if (sourceParticipants[p] == participant) { matched = int(p); break; }
            }
            // A compacted roster index is not evidence of the same participant.
            // New/unmatched racers wait for the next captured round.
            if (matched < 0) continue;
            uint index = uint(matched);
            lastDurationMs = Math::Max(lastDurationMs, state.durationMs);
            TrackedPlayer@ previous = tracked[index];
            if (!previous.throttled && state.throttle > 0) {
                previous.throttled = true;
                EmitPlayerEvent("first_throttle", state, state.durationMs, index);
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
                if (!previous.finished) EmitPlayerEvent(type, state, eventDurationMs, index);
            }
            while (previous.respawnCount < state.respawnCount) {
                previous.respawnCount++;
                EmitPlayerEvent("respawn", state, state.durationMs, index);
            }
            previous.finished = previous.finished || state.finished;
        }
    }

    void EmitPlayerEvent(const string &in type, PlayerObservation@ state, uint durationMs, uint index)
    {
        CapturedEvent@ event = NewEvent(type, durationMs);
        @event.player = roster[index];
        @event.attempt = attempts[index];
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
        attempts.Resize(0);
        sourceParticipants.Resize(0);
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
