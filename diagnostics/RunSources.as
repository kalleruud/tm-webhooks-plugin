#if DIAGNOSTICS
Json::Value DiagnosticsRunSources()
{
    Json::Value sources = Json::Object();
#if TURBO
    sources["input.throttle"] = "CTrackManiaPlayer.InputGasPedal";
    sources["input.brake"] = "CTrackManiaPlayer.InputIsBraking";
    sources["input.steer"] = "CTrackManiaPlayer.InputSteer";
    sources["vehicle.position"] = "CTrackManiaPlayer.Position";
    sources["vehicle.speed"] = "CTrackManiaPlayer.Speed";
    sources["vehicle.displaySpeed"] = "CTrackManiaPlayer.DisplaySpeed";
    sources["vehicle.engineRpm"] = "CTrackManiaPlayer.EngineRpm";
    sources["vehicle.gear"] = "CTrackManiaPlayer.EngineCurGear";
    sources["vehicle.turboRatio"] = "CTrackManiaPlayer.EngineTurboRatio";
    sources["vehicle.wheelContacts"] = "CTrackManiaPlayer.WheelsContactCount";
    sources["vehicle.wheelsSkidding"] = "CTrackManiaPlayer.WheelsSkiddingCount";
    sources["vehicle.flyingDurationMs"] = "CTrackManiaPlayer.FlyingDuration";
    sources["vehicle.skiddingDurationMs"] = "CTrackManiaPlayer.SkiddingDuration";
    sources["vehicle.distance"] = "CTrackManiaPlayer.Distance";
    sources["vehicle.accelCoef"] = "CTrackManiaPlayer.AccelCoef";
    sources["vehicle.gravityCoef"] = "CTrackManiaPlayer.GravityCoef";
    sources["race.clan"] = "CTrackManiaPlayer.CurrentClan";
    sources["vehicle.damageHull"] = "CTrackManiaPlayer.DamageHullRatio";
    sources["vehicle.damageWindows"] = "CTrackManiaPlayer.DamageWindowRatio";
    sources["race.respawns"] = "CTrackManiaPlayer.NbRespawns";
    sources["race.lap"] = "CTrackManiaPlayer.CurLapIndex";
    sources["race.checkpointTimeMs"] = "CTrackManiaPlayer.CurCheckpointRaceTime";
    sources["race.checkpointLapTimeMs"] = "CTrackManiaPlayer.CurCheckpointLapTime";
    sources["race.continuousRank"] = "CTrackManiaPlayer.CurRaceContinuousRank";
    sources["race.state"] = "CTrackManiaPlayer.RaceState";
    sources["race.racing"] = "CTrackManiaPlayer.RaceState == Running or Finished";
    sources["race.finished"] = "CTrackManiaPlayer.RaceState == Finished";
#else
    sources["input.throttle"] = "CSmScriptPlayer.InputGasPedal";
    sources["input.brake"] = "CSmScriptPlayer.InputIsBraking";
    sources["input.steer"] = "CSmScriptPlayer.InputSteer";
    sources["vehicle.position"] = "CSmScriptPlayer.Position";
    sources["vehicle.speed"] = "CSmScriptPlayer.Speed";
    sources["vehicle.displaySpeed"] = "CSmScriptPlayer.DisplaySpeed";
    sources["vehicle.engineRpm"] = "CSmScriptPlayer.EngineRpm";
    sources["vehicle.gear"] = "CSmScriptPlayer.EngineCurGear";
    sources["vehicle.turboRatio"] = "CSmScriptPlayer.EngineTurboRatio";
    sources["vehicle.wheelContacts"] = "CSmScriptPlayer.WheelsContactCount";
    sources["vehicle.wheelsSkidding"] = "CSmScriptPlayer.WheelsSkiddingCount";
    sources["vehicle.flyingDurationMs"] = "CSmScriptPlayer.FlyingDuration";
    sources["vehicle.skiddingDurationMs"] = "CSmScriptPlayer.SkiddingDuration";
    sources["vehicle.distance"] = "CSmScriptPlayer.Distance";
    sources["vehicle.accelCoef"] = "CSmScriptPlayer.AccelCoef";
    sources["vehicle.gravityCoef"] = "CSmScriptPlayer.GravityCoef";
    sources["race.clan"] = "CSmScriptPlayer.CurrentClan";
    sources["vehicle.velocity"] = "CSmScriptPlayer.Velocity";
    sources["race.respawns"] = "CSmScriptPlayer.CurrentRaceRespawns";
    sources["race.lap"] = "CSmScriptPlayer.CurrentLapNumber";
    sources["race.timeMs"] = "CSmScriptPlayer.CurrentRaceTime";
    sources["race.lapTimeMs"] = "CSmScriptPlayer.CurrentLapTime";
    sources["race.state"] = "CSmScriptPlayer.SpawnStatus";
    sources["race.racing"] = "CSmScriptPlayer.CurrentRaceTime >= 0 and IsInVehicle";
#endif
    return sources;
}
#endif
