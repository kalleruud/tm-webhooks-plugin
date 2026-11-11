#if DIAGNOSTICS
[Setting name="Diagnostics endpoint URL" description="Full /diagnostics/v1/chunks URL. Independent of race webhooks. Empty disables uploads." category="Diagnostics"]
string Setting_DiagnosticsEndpoint = "";

[Setting name="Diagnostics authentication token" description="Dedicated receiver bearer token. Never included in dumps." category="Diagnostics" password]
string Setting_DiagnosticsToken = "";

[Setting name="Read native game values (experimental)" description="Disabled by default while investigating freezes. Metadata-only captures inspect API definitions without invoking generated getters. Native getters may block the game and cannot be interrupted." category="Diagnostics"]
bool Setting_DiagnosticsReadValues = false;

[Setting name="Write last-operation breadcrumb" description="Flushes diagnostics-last-operation.json before native reads and major capture stages. Helps identify a getter that blocks the game; adds disk overhead." category="Diagnostics"]
bool Setting_DiagnosticsTrace = true;

[Setting name="Maximum objects" category="Diagnostics" min=1 max=10000]
uint Setting_DiagnosticsObjects = 4096;

[Setting name="Maximum traversal depth" category="Diagnostics" min=1 max=32]
uint Setting_DiagnosticsDepth = 12;

[Setting name="Maximum array elements" category="Diagnostics" min=1 max=512]
uint Setting_DiagnosticsArray = 128;

[Setting name="Maximum string bytes" category="Diagnostics" min=64 max=16384]
uint Setting_DiagnosticsString = 4096;

[Setting name="Maximum capture time (seconds)" category="Diagnostics" min=1 max=120]
uint Setting_DiagnosticsSeconds = 30;
#endif
