#if DIAGNOSTICS
bool g_diagnosticsBusy;
bool g_diagnosticsRecording;
bool g_diagnosticsCancel;
bool g_diagnosticsPeriodic;
bool g_diagnosticsWorker;
string g_diagnosticsStatus = "Idle. Delivery is best-effort.";
uint g_diagnosticsStarted;
uint g_diagnosticsFailed;
uint g_diagnosticsDropped;
array<DiagnosticsPacket@> g_diagnosticsQueue;
array<DiagnosticsRequest@> g_diagnosticsRequests;

class DiagnosticsPacket
{
    string body;
    string endpoint;
    string token;
}

class DiagnosticsRequest
{
    Net::HttpRequest@ request;
    uint started;
}

string DiagnosticsGame()
{
#if TURBO
    return "turbo";
#else
    return "next";
#endif
}

bool DiagnosticsConfigured()
{
    return (Setting_DiagnosticsEndpoint.StartsWith("http://") || Setting_DiagnosticsEndpoint.StartsWith("https://")) && Setting_DiagnosticsToken.Length > 0;
}

void DiagnosticsEnsureWorker()
{
    if (g_diagnosticsWorker) return;
    g_diagnosticsWorker = true;
    startnew(CoroutineFunc(DiagnosticsWorker));
}

bool DiagnosticsEnqueue(const string &in id, uint index, const string &in kind, const string &in data, const string &in endpoint, const string &in token)
{
    if (g_diagnosticsQueue.Length >= 64 || endpoint.Length == 0 || token.Length == 0) { g_diagnosticsDropped++; return false; }
    DiagnosticsPacket@ packet = DiagnosticsPacket();
    // id/game/kind are generated constants; data is already serialized JSON.
    packet.body = "{\"schemaVersion\":\"1.1.0\",\"captureId\":\"" + id + "\",\"game\":\"" + DiagnosticsGame() + "\",\"index\":" + index + ",\"kind\":\"" + kind + "\",\"data\":" + data + "}";
    packet.endpoint = endpoint;
    packet.token = token;
    g_diagnosticsQueue.InsertLast(packet);
    DiagnosticsEnsureWorker();
    return true;
}

void DiagnosticsWorker()
{
    uint nextCapture = Time::Now;
    while (g_diagnosticsPeriodic || g_diagnosticsBusy || !g_diagnosticsQueue.IsEmpty() || !g_diagnosticsRequests.IsEmpty()) {
        for (int i = int(g_diagnosticsRequests.Length) - 1; i >= 0; i--) {
            auto pending = g_diagnosticsRequests[i];
            bool done = pending.request.Finished();
            if (done || Time::Now - pending.started >= 5000) {
                if (!done) { pending.request.Cancel(); g_diagnosticsFailed++; }
                else if (pending.request.ResponseCode() < 200 || pending.request.ResponseCode() >= 300) g_diagnosticsFailed++;
                g_diagnosticsRequests.RemoveAt(i);
            }
        }
        // Never wait for a response in the collection coroutine. Keep request
        // handles alive here, cap in-flight work and discard on failure/timeout.
        while (g_diagnosticsRequests.Length < 4 && !g_diagnosticsQueue.IsEmpty()) {
            auto packet = g_diagnosticsQueue[0];
            g_diagnosticsQueue.RemoveAt(0);
            try {
                DiagnosticsRequest@ pending = DiagnosticsRequest();
                @pending.request = Net::HttpRequest();
                pending.request.Url = packet.endpoint;
                pending.request.Method = Net::HttpMethod::Post;
                pending.request.Redirect = false;
                pending.request.Headers["Content-Type"] = "application/json; charset=utf-8";
                pending.request.Headers["Authorization"] = "Bearer " + packet.token;
                pending.request.Body = packet.body;
                pending.started = Time::Now;
                pending.request.Start();
                g_diagnosticsRequests.InsertLast(pending);
                g_diagnosticsStarted++;
            } catch { g_diagnosticsFailed++; }
        }
        if (g_diagnosticsPeriodic && !g_diagnosticsBusy && Time::Now >= nextCapture) {
            nextCapture = Time::Now + uint(Math::Clamp(int(Setting_DiagnosticsIntervalSeconds), 1, 300)) * 1000;
            startnew(CoroutineFunc(DiagnosticsCaptureAndUpload));
        }
        sleep(10);
    }
    g_diagnosticsWorker = false;
}

void DiagnosticsStartPeriodic()
{
    if (!DiagnosticsConfigured()) { g_diagnosticsStatus = "Set the dedicated diagnostics endpoint and token first."; return; }
    if (Setting_DiagnosticsRunRecorder) { DiagnosticsStartRunRecording(); return; }
    g_diagnosticsPeriodic = true;
    DiagnosticsEnsureWorker();
}

void DiagnosticsStop()
{
    g_diagnosticsPeriodic = false;
    g_diagnosticsCancel = true;
    if (g_diagnosticsRecording) { g_diagnosticsStatus = "Stopping recording; queued records will drain independently."; return; }
    g_diagnosticsDropped += g_diagnosticsQueue.Length;
    g_diagnosticsQueue.RemoveRange(0, g_diagnosticsQueue.Length);
    for (uint i = 0; i < g_diagnosticsRequests.Length; i++) g_diagnosticsRequests[i].request.Cancel();
    g_diagnosticsRequests.RemoveRange(0, g_diagnosticsRequests.Length);
    g_diagnosticsStatus = "Stopped. Already received records remain on the receiver.";
}

void RenderMenu()
{
    if (UI::MenuItem(Setting_DiagnosticsRunRecorder ? "Start run recording" : "Start periodic API exploration", "", false, !g_diagnosticsPeriodic && !g_diagnosticsBusy)) DiagnosticsStartPeriodic();
    if (UI::MenuItem("Stop diagnostics", "", false, g_diagnosticsPeriodic || g_diagnosticsBusy)) DiagnosticsStop();
}

[SettingsTab name="Diagnostics status"]
void RenderDiagnosticsSettings()
{
    UI::TextWrapped("Best-effort streaming: collection does not wait for HTTP acknowledgements. Records can be dropped; no retries or local dump spool.");
    UI::TextWrapped(Setting_DiagnosticsRunRecorder ? "Run recorder: names/logins, leaderboard rows, map/mode, race clocks and car/input telemetry. This mode reads focused game APIs regardless of the broad-probe metadata-only setting." : (Setting_DiagnosticsReadValues ? "Broad native value reads enabled (experimental)." : "Metadata-only API exploration."));
    UI::TextWrapped(g_diagnosticsStatus);
    UI::Text("Requests started: " + g_diagnosticsStarted + ", failed: " + g_diagnosticsFailed + ", dropped locally: " + g_diagnosticsDropped);
    if (!g_diagnosticsBusy && !g_diagnosticsPeriodic && UI::Button(Setting_DiagnosticsRunRecorder ? "Start run recording" : "Start periodic API exploration")) DiagnosticsStartPeriodic();
    if (!g_diagnosticsBusy && !g_diagnosticsPeriodic && UI::Button("Send one broad API probe")) startnew(CoroutineFunc(DiagnosticsCaptureAndUpload));
    if ((g_diagnosticsPeriodic || g_diagnosticsBusy) && UI::Button("Stop diagnostics")) DiagnosticsStop();
}

void DiagnosticsCaptureAndUpload()
{
    if (g_diagnosticsBusy) return;
    if (!DiagnosticsConfigured()) { g_diagnosticsStatus = "Set the dedicated diagnostics endpoint and token first."; return; }
    g_diagnosticsBusy = true;
    g_diagnosticsCancel = false;
    DiagnosticsEnsureWorker();
    try {
        DiagnosticsCapture capture;
        try { capture.Run(); } catch { capture.captureFailed = true; capture.reason = "collector exception"; }
        capture.nodes.RemoveRange(0, capture.nodes.Length);
        if (!g_diagnosticsCancel) capture.SendManifest();
        g_diagnosticsStatus = "Capture finished; " + capture.packetIndex + " records attempted. Delivery is best-effort.";
    } catch { g_diagnosticsStatus = "Capture failed; records already sent remain on the receiver."; }
    g_diagnosticsBusy = false;
}
#endif

#if DIAGNOSTICS
void DiagnosticsStartRunRecording()
{
    if (g_diagnosticsBusy || g_diagnosticsRecording) return;
    if (!DiagnosticsConfigured()) { g_diagnosticsStatus = "Set the dedicated diagnostics endpoint and token first."; return; }
    g_diagnosticsPeriodic = false;
    g_diagnosticsCancel = false;
    g_diagnosticsBusy = true;
    g_diagnosticsRecording = true;
    DiagnosticsEnsureWorker();
    startnew(CoroutineFunc(DiagnosticsRecordRun));
}

void DiagnosticsRecordRun()
{
    try {
        DiagnosticsRunRecorder recorder;
        recorder.Run();
        g_diagnosticsStatus = "Recording finished: " + recorder.packetIndex + " records attempted, " + recorder.dropped + " local drops. Pending HTTP packets drain without acknowledgement waits.";
    } catch { g_diagnosticsStatus = "Run recording failed; previously received records remain available."; }
    g_diagnosticsRecording = false;
    g_diagnosticsBusy = false;
}
#endif
