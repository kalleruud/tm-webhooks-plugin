#if DIAGNOSTICS
void DiagnosticsHelpers(DiagnosticsCapture@ capture)
{
    Json::Value record = Json::Object();
    record["kind"] = "helper-summary";
    record["path"] = "helpers";
    record["observedAt"] = OccurredAtUtc();
#if TMNEXT
    // Helper-plugin script objects are not CMwNod instances. Read the subset
    // already used by the plugin, and state this coverage boundary explicitly.
    record["coverage"] = "MLFeed race/player fields used by this plugin, plus viewed throttle; not a reflection dump of helper plugin internals";
    try {
        auto race = MLFeed::GetRaceData_V4();
        if (race !is null) {
            record["checkpointCount"] = race.CPCount;
            record["lapCount"] = race.LapCount;
            auto app = cast<CTrackMania>(GetApp());
            Json::Value players = Json::Array();
            if (app !is null && app.CurrentPlayground !is null) {
                auto playground = app.CurrentPlayground;
                for (uint i = 0; i < playground.Players.Length && i < capture.maxArray; i++) {
                    auto player = cast<CSmPlayer>(playground.Players[i]);
                    if (player is null || player.User is null) continue;
                    auto feed = race.GetPlayer_V4(player.User.Name);
                    if (feed is null) continue;
                    Json::Value state = Json::Object();
                    state["playerIndex"] = i;
                    state["currentRaceTime"] = feed.CurrentRaceTime;
                    state["isRacing"] = feed.PlayerIsRacing;
                    state["spawnStatus"] = int(feed.SpawnStatus);
                    state["spawnIndex"] = feed.SpawnIndex;
                    state["lastCheckpointTime"] = feed.LastCpTime;
                    state["checkpointCount"] = feed.CpCount;
                    state["respawnsRequested"] = feed.NbRespawnsRequested;
                    state["isFinished"] = feed.IsFinished;
                    state["currentLap"] = feed.CurrentLap;
                    players.Add(state);
                }
            }
            record["players"] = players;
        } else record["raceStatus"] = "unavailable";
    } catch { record["raceStatus"] = "getter exception"; }
    try {
        auto vehicle = VehicleState::ViewingPlayerState();
        if (vehicle !is null) record["viewedThrottle"] = capture.Number(vehicle.InputGasPedal);
        else record["vehicleStatus"] = "unavailable";
    } catch { record["vehicleStatus"] = "getter exception"; }
#else
    record["status"] = "not-applicable";
    record["coverage"] = "Turbo uses native game APIs; Next helper plugins are not required";
#endif
    capture.Emit(record);
}
#endif
