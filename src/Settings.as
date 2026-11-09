[Setting name="Endpoint URL" description="Webhook destination. Capture is disabled while empty." category="Webhook"]
string Setting_EndpointUrl = "";

[Setting name="Authentication token" description="Optional bearer token. The value is never logged." category="Webhook" password]
string Setting_AuthenticationToken = "";

[Setting name="Maximum retry count" description="Retries after the initial request." category="Webhook" min=0 max=10]
uint Setting_MaximumRetryCount = 3;

#if TURBO
[Setting name="Enable name-entry probe" description="Development capture for up to ten minutes per mode/map. Sends raw UI variable dumps to the separate diagnostic URL; does not emit score/name events." category="Name diagnostics"]
bool Setting_NameProbeEnabled = false;

[Setting name="Diagnostic URL" description="Use the local receiver /api/diagnostics endpoint. Uses the webhook authentication token. Leave empty to disable." category="Name diagnostics"]
string Setting_NameProbeUrl = "";
#endif

#if TURBO
[Setting name="Capture arcade scores (experimental)" description="Capture confirmed standard arcade names and correlate captured attempts. Standard arcade only; hot-seat capture has its own setting." category="Webhook"]
bool Setting_ArcadeScores = false;
#endif

#if TURBO
[Setting name="Capture hot-seat names and scores (experimental)" description="Stable participant IDs for standard hot seat, confirmed name changes, and completed-attempt scores." category="Webhook"]
bool Setting_HotSeatScores = false;
#endif
