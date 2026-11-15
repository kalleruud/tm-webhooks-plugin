#if DIAGNOSTICS
[Setting name="Record runs" description="Continuously record player, race, vehicle and leaderboard data to the diagnostics receiver while enabled." category="Diagnostics"]
bool Setting_DiagnosticsEnabled = false;

[Setting name="Receiver URL" description="Full diagnostics receiver URL ending in /diagnostics/v1/chunks. Unauthenticated; intended for a local receiver." category="Diagnostics"]
string Setting_DiagnosticsEndpoint = "http://127.0.0.1:8787/diagnostics/v1/chunks";
#endif
