#if TURBO
// Opt-in development telemetry, deliberately separate from race webhooks.
// The dump format/bindings must be verified in-game before using them for scores.
class TurboNameProbe
{
    array<string> pending;
    string previous;
    uint nextSample;
    uint startedAt;
    uint sequence;
    uint dropped;
    bool enabled;
    string captureId;

    void Update()
    {
        if (!Setting_NameProbeEnabled || Setting_NameProbeUrl.Length == 0) {
            enabled = false;
            pending.Resize(0);
            return;
        }
        if (!enabled) {
            enabled = true;
            startedAt = Time::Now;
            nextSample = Time::Now;
            sequence = 0;
            dropped = 0;
            captureId = CreateUuidV4();
            previous = "";
            print("[name-probe] Started ten-minute diagnostic capture " + captureId);
        }
        if (Time::Now - startedAt >= 600000) {
            Setting_NameProbeEnabled = false;
            print("[name-probe] Ten-minute limit reached; enable again for another test.");
            return;
        }
        if (Time::Now < nextSample) return;
        nextSample = Time::Now + 250;
        Json::Value@ state = Observe();
        string fingerprint = Json::Write(state);
        if (fingerprint == previous) return;
        previous = fingerprint;
        Json::Value@ message = Json::Object();
        message["type"] = "turbo_name_probe";
        message["probeVersion"] = 1;
        message["pluginVersion"] = Meta::ExecutingPlugin().Version;
        message["captureId"] = captureId;
        message["sequence"] = sequence++;
        message["occurredAt"] = OccurredAtUtc();
        message["droppedSamples"] = dropped;
        message["state"] = state;
        if (pending.Length >= 32) {
            // Keep the latest state; sequence gaps make loss explicit.
            pending.RemoveAt(0);
            dropped++;
            message["droppedSamples"] = dropped;
        }
        pending.InsertLast(Json::Write(message));
    }

    Json::Value@ Observe()
    {
        Json::Value@ state = Json::Object();
        auto app = cast<CGameManiaPlanet>(GetApp());
        if (app is null) return state;
        if (app.Challenge !is null) state["mapUid"] = app.Challenge.IdName;
        auto script = app.PlaygroundScript;
        if (script !is null) {
            state["mode"] = script.ServerModeName;
            Json::Value@ dumps = Json::Object();
            // Probe both shared and local UI state, also outside active races.
            AddDump(dumps, "rules", script, script);
            if (script.UIManager !is null) {
                AddDump(dumps, "uiAll", script, script.UIManager.UIAll);
                AddDump(dumps, "localUI", script, script.UIManager.LocalPlayerConfig);
                uint pageCount = 0;
                for (uint i = 0; i < script.UIManager.UILayers.Length && pageCount < 4; i++) {
                    auto layer = script.UIManager.UILayers[i];
                    if (layer is null || layer.LocalPage is null) continue;
                    string page = layer.ManialinkPageUtf8;
                    if (!page.Contains("LibTMC_ScoresTable") && !page.Contains("Net_CurPlayerIndex")) continue;
                    string key = "nameLayer" + i;
                    AddDump(dumps, key, script, layer.LocalPage);
                    state[key + "Visible"] = layer.IsVisible;
                    pageCount++;
                }
                if (script.UIManager.LocalPlayerConfig !is null) {
                    state["uiSequence"] = uint(script.UIManager.LocalPlayerConfig.UISequence);
                }
            }
            state["declaredVariables"] = dumps;
        }
        Json::Value@ scores = Json::Array();
        auto network = cast<CTrackManiaNetwork>(app.Network);
        if (network !is null) {
            // Same public bindings used by chrizonix's TurboCup recorder.
            for (uint i = 0; i < network.PlayerInfos.Length && i < 16; i++) {
                auto player = cast<CTrackManiaPlayerInfo>(network.PlayerInfos[i]);
                if (player is null) continue;
                Json::Value@ score = Json::Object();
                score["index"] = i;
                score["name"] = player.Name;
                if (player.RaceScore !is null) {
                    score["bestTime"] = player.RaceScore.BestTime;
                    score["lastRaceTime"] = player.RaceScore.LastRaceTime;
                }
                scores.Add(score);
            }
        }
        state["networkScores"] = scores;
        Json::Value@ racers = Json::Array();
        if (app.CurrentPlayground !is null) {
            for (uint i = 0; i < app.CurrentPlayground.Players.Length && i < 4; i++) {
                auto player = cast<CTrackManiaPlayer>(app.CurrentPlayground.Players[i]);
                if (player is null) continue;
                Json::Value@ racer = Json::Object();
                racer["index"] = i;
                racer["raceState"] = uint(player.RaceState);
                racer["raceStartTime"] = player.RaceStartTime;
                if (player.RaceState == CTrackManiaPlayer::ERaceState::Finished && player.CurRace !is null) {
                    racer["finishTime"] = player.CurRace.Time;
                }
                racers.Add(racer);
            }
        }
        state["racePlayers"] = racers;
        return state;
    }

    void AddDump(Json::Value@ dumps, const string &in key, CGamePlaygroundScript@ script, CMwNod@ node)
    {
        if (node is null) return;
        // Preserve the raw format, including truncation evidence. No parser yet.
        string text = script.Dbg_DumpDeclareForVariables(node, false);
        Json::Value@ dump = Json::Object();
        dump["length"] = text.Length;
        dump["truncated"] = text.Length > 16384;
        dump["text"] = text.SubStr(0, Math::Min(text.Length, uint(16384)));
        dumps[key] = dump;
    }

    void Run()
    {
        while (true) {
            if (!Setting_NameProbeEnabled || Setting_NameProbeUrl.Length == 0 || pending.IsEmpty()) {
                sleep(100);
                continue;
            }
            string body = pending[0];
            pending.RemoveAt(0);
            auto request = Net::HttpRequest();
            request.Url = Setting_NameProbeUrl;
            request.Method = Net::HttpMethod::Post;
            request.Headers["Content-Type"] = "application/json; charset=utf-8";
            if (Setting_AuthenticationToken.Length > 0) {
                request.Headers["Authorization"] = "Bearer " + Setting_AuthenticationToken;
            }
            request.Body = body;
            request.Start();
            uint started = Time::Now;
            while (!request.Finished() && Time::Now - started < 5000) yield();
            if (!request.Finished()) request.Cancel();
            if (!request.Finished() || request.ResponseCode() < 200 || request.ResponseCode() >= 300) {
                dropped++;
                warn("[name-probe] Diagnostic delivery failed; sample not retried.");
            }
            sleep(100);
        }
    }
}
#endif
