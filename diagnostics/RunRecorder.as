#if DIAGNOSTICS
class DiagnosticsRunRecorder
{
    string id = CreateUuidV4();
    string endpoint = Setting_DiagnosticsEndpoint;
    string token = Setting_DiagnosticsToken;
    string startedAt = OccurredAtUtc();
    uint started = Time::Now;
    uint packetIndex;
    uint sampleSequence;
    uint intervalMs = uint(Math::Clamp(int(Setting_DiagnosticsSampleMs), 50, 2000));
    uint dropped;
    uint bytes;
    uint sendSteps;
    bool limited;
    string limitReason = "stream-budget";
    string lastContext;
    string lastLeaderboard;
    uint contextSentAt;
    uint leaderboardSentAt;
    array<string> playerKeys;
    array<string> playerIds;
    array<CMwNod@> seenEvents;
    string eventMap;
    string launchModeHint;
    array<string> errorSections;
    array<uint> errorTimes;

    string PlayerId(const string &in key)
    {
        for (uint i = 0; i < playerKeys.Length; i++) if (playerKeys[i] == key) return playerIds[i];
        if (playerKeys.Length >= 256) { limited = true; limitReason = "player-identity-limit"; return ""; }
        playerKeys.InsertLast(key);
        playerIds.InsertLast(CreateUuidV4());
        return playerIds[playerIds.Length - 1];
    }

    bool NewEvent(CMwNod@ event)
    {
        for (uint i = 0; i < seenEvents.Length; i++) if (seenEvents[i] is event) return false;
        if (seenEvents.Length >= 128) seenEvents.RemoveAt(0);
        seenEvents.InsertLast(event);
        return true;
    }

    void Emit(Json::Value &in record)
    {
        if (g_diagnosticsCancel || limited) return;
        if (packetIndex >= 32767 || bytes >= 16 * 1024 * 1024) { limited = true; limitReason = packetIndex >= 32767 ? "packet-limit" : "byte-limit"; return; }
        record["recordingId"] = id;
        record["recordSequence"] = packetIndex;
        if (!record.HasKey("observedAt")) record["observedAt"] = OccurredAtUtc();
        if (!record.HasKey("elapsedMs")) record["elapsedMs"] = Time::Now - started;
        string body = Json::Write(record);
        uint index = packetIndex++;
        if (body.Length > 24 * 1024) { dropped++; return; }
        bytes += body.Length;
        if (!DiagnosticsEnqueue(id, index, "record", body, endpoint, token)) dropped++;
        // Small, bounded records; four serializations at most between yields.
        if (++sendSteps >= 4) { sendSteps = 0; yield(); }
    }

    void Changed(Json::Value &in record, bool leaderboard)
    {
        string fingerprint = Json::Write(record);
        string previous = leaderboard ? lastLeaderboard : lastContext;
        uint previousAt = leaderboard ? leaderboardSentAt : contextSentAt;
        if (fingerprint == previous && Time::Now - previousAt < 5000) return;
        if (leaderboard) { lastLeaderboard = fingerprint; leaderboardSentAt = Time::Now; }
        else { lastContext = fingerprint; contextSentAt = Time::Now; }
        Emit(record);
    }

    void Run()
    {
        Json::Value begin = Json::Object();
        begin["kind"] = "run-recording-start";
        begin["collectorVersion"] = "1.2.0";
        begin["game"] = DiagnosticsGame();
        begin["sampleIntervalMs"] = intervalMs;
        begin["sources"] = DiagnosticsRunSources();
        begin["namesIncluded"] = true;
        begin["collisionSemantics"] = "Native events where available; speed/damage impact candidates are inference, not proof of a wall hit.";
        begin["speedUnits"] = "Native API units retained; displaySpeed is separately recorded. No conversion assumed.";
        begin["eventCoverage"] = "Read-only polling; transient events and HTTP packets may be missed. Never consumes native event queues.";
        Emit(begin);
        uint nextSample = Time::Now;
        uint nextContext = Time::Now;
        uint duration = uint(Math::Clamp(int(Setting_DiagnosticsRecordingMinutes), 1, 60)) * 60000;
        while (!g_diagnosticsCancel && !limited && Time::Now - started < duration) {
            try { DiagnosticsRunEvents(this); }
            catch { Error("native-events", "getter exception"); }
            if (g_diagnosticsCancel || limited) break;
            if (Time::Now >= nextSample) {
                nextSample = Time::Now + intervalMs;
                sampleSequence++;
                try { DiagnosticsRunPlayers(this); }
                catch { Error("player-samples", "getter exception"); }
            }
            if (g_diagnosticsCancel || limited) break;
            if (Time::Now >= nextContext) {
                nextContext = Time::Now + 1000;
                try { DiagnosticsRunContext(this); }
                catch { Error("context-or-leaderboard", "getter exception"); }
            }
            g_diagnosticsStatus = "Recording run: " + (Time::Now - started) / 1000 + "s, " + sampleSequence + " samples, " + dropped + " local drops";
            yield();
        }
        Json::Value end = Json::Object();
        end["kind"] = "run-recording-end";
        end["reason"] = g_diagnosticsCancel ? "user-stopped" : (limited ? limitReason : "duration-limit");
        // Stopping a recording retains queued packets and queues its manifest.
        bool wasCancelled = g_diagnosticsCancel;
        g_diagnosticsCancel = false;
        if (!limited) Emit(end);
        g_diagnosticsCancel = wasCancelled;
        Json::Value manifest = Json::Object();
        manifest["startedAt"] = startedAt;
        manifest["endedAt"] = OccurredAtUtc();
        manifest["collectorVersion"] = "1.2.0";
        manifest["captureMode"] = "run-recorder";
        manifest["status"] = limited || dropped > 0 ? "truncated" : "complete";
        manifest["reason"] = end["reason"];
        manifest["attemptedRecords"] = packetIndex;
        manifest["locallyDroppedRecords"] = dropped;
        manifest["sampleCount"] = sampleSequence;
        manifest["durationMs"] = Time::Now - started;
        DiagnosticsEnqueue(id, packetIndex, "manifest", Json::Write(manifest), endpoint, token);
    }

    void Error(const string &in section, const string &in reason)
    {
        for (uint i = 0; i < errorSections.Length; i++) {
            if (errorSections[i] != section) continue;
            if (Time::Now - errorTimes[i] < 1000) return;
            errorTimes[i] = Time::Now;
            break;
        }
        bool known;
        for (uint i = 0; i < errorSections.Length; i++) if (errorSections[i] == section) known = true;
        if (!known) { errorSections.InsertLast(section); errorTimes.InsertLast(Time::Now); }
        Json::Value record = Json::Object();
        record["kind"] = "run-coverage";
        record["section"] = section;
        record["reason"] = reason;
        Emit(record);
    }
}

Json::Value DiagnosticsRunNumber(float value)
{
    if (Math::IsNaN(value) || Math::IsInf(value)) return Json::Value();
    return Json::Value(value);
}

Json::Value DiagnosticsRunVector(vec3 value)
{
    Json::Value result = Json::Object();
    result["x"] = DiagnosticsRunNumber(value.x);
    result["y"] = DiagnosticsRunNumber(value.y);
    result["z"] = DiagnosticsRunNumber(value.z);
    return result;
}

string DiagnosticsRunText(const string &in value, uint limit = 128)
{
    if (uint(value.Length) <= limit) return value;
    uint end = limit;
    while (end > 0 && (value[end] & 0xC0) == 0x80) end--;
    return value.SubStr(0, end);
}

string DiagnosticsRunIdentity(CGamePlayerInfo@ user, uint slot, const string &in name)
{
    if (user !is null && user.Login.Length > 0) return "login:" + user.Login;
    if (user !is null && user.Id.Value != 0) return "user-id:" + user.Id.Value;
    return "slot:" + slot + ":" + name;
}

Json::Value DiagnosticsRunMap(CGameCtnChallenge@ map)
{
    if (map is null) return Json::Value();
    Json::Value value = Json::Object();
    value["uid"] = map.IdName;
    value["name"] = DiagnosticsRunText(string(map.MapName));
    value["authorName"] = DiagnosticsRunText(string(map.AuthorNickName));
    value["environment"] = map.CollectionName;
    value["mapType"] = string(map.MapType);
    value["isLapRace"] = map.TMObjective_IsLapRace;
    value["authorTimeMs"] = map.TMObjective_AuthorTime;
    value["goldTimeMs"] = map.TMObjective_GoldTime;
    value["silverTimeMs"] = map.TMObjective_SilverTime;
    value["bronzeTimeMs"] = map.TMObjective_BronzeTime;
    return value;
}
#endif
#if DIAGNOSTICS
Json::Value DiagnosticsRunRoster(CGamePlayerInfo@ user, uint slot, const string &in name, DiagnosticsRunRecorder@ recorder)
{
    Json::Value value = Json::Object();
    value["playerIndex"] = slot;
    value["name"] = DiagnosticsRunText(name);
    string key = DiagnosticsRunIdentity(user, slot, name);
    value["userKey"] = key;
    value["playerId"] = recorder.PlayerId(key + "#slot:" + slot);
    if (user !is null) {
        value["login"] = DiagnosticsRunText(user.Login, 64);
        value["userName"] = DiagnosticsRunText(string(user.Name));
        value["gameUserId"] = user.Id.Value;
        value["ladderRank"] = user.LadderRank;
        value["ladderPoints"] = DiagnosticsRunNumber(user.LadderPoints);
        value["echelon"] = int(user.Echelon);
        value["language"] = user.Language;
    }
    value["source"] = "CGamePlayer.User/CGamePlayerInfo";
    return value;
}
#endif
