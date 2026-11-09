#if TURBO
TurboNameProbe@ g_nameProbe;
TurboArcadeCapture@ g_arcadeCapture;
TurboHotSeatCapture@ g_hotSeatCapture;
#endif
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
#if TURBO
    @g_nameProbe = TurboNameProbe();
    @g_arcadeCapture = TurboArcadeCapture(g_delivery);
    @g_hotSeatCapture = TurboHotSeatCapture(g_delivery);
    startnew(CoroutineFunc(NameProbeLoop));
#endif
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

#if TURBO
void NameProbeLoop() { g_nameProbe.Run(); }
#endif

void DeliveryLoop() { g_delivery.Run(); }

void Update(float dt)
{
    LogConfigurationState();
#if TURBO
    if (g_nameProbe !is null) {
        try { g_nameProbe.Update(); }
        catch {
            Setting_NameProbeEnabled = false;
            warn("[name-probe] Runtime probe failed and was disabled; race capture continues.");
        }
    }
#endif
    if (g_adapter is null || g_tracker is null) return;
    auto observation = g_adapter.Observe();
#if TURBO
    try { g_arcadeCapture.BeforeRound(observation); }
    catch {
        g_arcadeCapture.Reset();
        Setting_ArcadeScores = false;
        warn("[arcade] Runtime name capture failed and was disabled.");
    }
    try { g_hotSeatCapture.BeforeRound(observation); }
    catch {
        g_hotSeatCapture.Reset();
        Setting_HotSeatScores = false;
        warn("[hot-seat] Runtime name capture failed and was disabled.");
    }
#endif
    g_tracker.Update(observation);
#if TURBO
    g_arcadeCapture.AfterRound(g_tracker);
    g_hotSeatCapture.AfterRound(g_tracker, observation);
#endif
}

void LogConfigurationState()
{
    int state = Setting_EndpointUrl.Length == 0 ? 0 : (Setting_AuthenticationToken.Length == 0 ? 1 : 2);
    if (state == g_configurationState) return;
    g_configurationState = state;
    if (state == 0) {
        warn("[config] capture disabled: endpoint URL is empty");
    } else if (state == 1) {
        print("[config] capture enabled without authentication; waiting for a supported local round");
    } else {
        print("[config] capture enabled; waiting for a supported local round");
    }
}

void OnDestroyed()
{
    if (g_tracker !is null) g_tracker.Stop("unknown");
}
