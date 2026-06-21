RoundTracker@ g_tracker;
GameAdapter@ g_adapter;
WebhookDelivery@ g_delivery;
int g_configurationState = -1;

void Main()
{
#if TMNEXT
    EnsureTrackmaniaNextDependencies();
#endif
    @g_delivery = WebhookDelivery();
    @g_tracker = RoundTracker(g_delivery);
    @g_adapter = CreateGameAdapter();
    print("[init] " + AdapterGameName());
    startnew(CoroutineFunc(DeliveryLoop));
}

#if TMNEXT
void EnsureTrackmaniaNextDependencies()
{
    // Probe required helper APIs during startup so TMNEXT fails fast if the
    // shared package was installed without its required helper plugins.
    MLFeed::GetRaceData_V4();
    VehicleState::ViewingPlayerState();
}
#endif

void DeliveryLoop() { g_delivery.Run(); }

void Update(float dt)
{
    LogConfigurationState();
    if (g_adapter is null || g_tracker is null) return;
    g_tracker.Update(g_adapter.Observe());
}

void LogConfigurationState()
{
    int state = Setting_EndpointUrl.Length == 0 ? 0 : 1;
    if (state == g_configurationState) return;
    g_configurationState = state;
    if (state == 0) {
        warn("[config] capture disabled: endpoint URL is empty");
    } else {
        print("[config] capture enabled with Openplanet authentication; waiting for a supported local round");
    }
}

void OnDestroyed()
{
    if (g_tracker !is null) g_tracker.Stop("unknown");
}
