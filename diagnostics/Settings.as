#if DIAGNOSTICS
[Setting name="Diagnostics endpoint URL" description="Full /diagnostics/v1/chunks URL. Independent of race webhooks. Empty disables uploads." category="Diagnostics"]
string Setting_DiagnosticsEndpoint = "";

[Setting name="Diagnostics authentication token" description="Dedicated receiver bearer token. Never included in dumps." category="Diagnostics" password]
string Setting_DiagnosticsToken = "";

[Setting name="Use run recorder" description="Prioritize repeated player/race/vehicle samples and leaderboard/context snapshots. Disable only for the older broad API exploration probe." category="Diagnostics"]
bool Setting_DiagnosticsRunRecorder = true;

[Setting name="Run sample interval (milliseconds)" description="Target interval; actual per-player timestamps are retained and missed intervals are skipped." category="Diagnostics" min=50 max=2000]
uint Setting_DiagnosticsSampleMs = 100;

[Setting name="Recording limit (minutes)" description="Recording ends on Stop, this duration, or bounded transport limits." category="Diagnostics" min=1 max=60]
uint Setting_DiagnosticsRecordingMinutes = 15;

[Setting name="Read native game values (experimental)" description="Disabled by default while investigating freezes. Metadata-only captures inspect API definitions without invoking generated getters. Native getters may block the game and cannot be interrupted." category="Diagnostics"]
bool Setting_DiagnosticsReadValues = false;

[Setting name="Write last-operation breadcrumb" description="Flushes diagnostics-last-operation.json before native reads and major capture stages. Helps identify a getter that blocks the game; adds disk overhead." category="Diagnostics"]
bool Setting_DiagnosticsTrace = false;

[Setting name="Capture interval (seconds)" description="Minimum time between periodic capture starts. Captures never overlap; missed intervals are skipped." category="Diagnostics" min=1 max=300]
uint Setting_DiagnosticsIntervalSeconds = 5;

[Setting name="Include static API catalogue" description="Stream static definitions as individual records. Usually unnecessary on every periodic capture." category="Diagnostics"]
bool Setting_DiagnosticsIncludeAPI = false;

[Setting name="Maximum objects" category="Diagnostics" min=1 max=10000]
uint Setting_DiagnosticsObjects = 4096;

[Setting name="Maximum traversal depth" category="Diagnostics" min=1 max=32]
uint Setting_DiagnosticsDepth = 12;

[Setting name="Maximum array elements" category="Diagnostics" min=1 max=512]
uint Setting_DiagnosticsArray = 128;

[Setting name="Maximum string bytes" category="Diagnostics" min=64 max=16384]
uint Setting_DiagnosticsString = 512;

[Setting name="Maximum capture time (seconds)" category="Diagnostics" min=1 max=120]
uint Setting_DiagnosticsSeconds = 30;
#endif
