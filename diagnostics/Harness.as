#if DIAGNOSTICS
const string DIAGNOSTICS_VERSION = "1.3.0";
bool g_diagnosticsRecording;
bool g_diagnosticsCancel;
uint g_diagnosticsNextStart = 0;
uint g_diagnosticsRequestCursor = 0;
int g_diagnosticsLastHttpStatus = 0;
string g_diagnosticsSenderError;
string g_diagnosticsStatus = "Disabled.";
uint g_diagnosticsStarted;
uint g_diagnosticsFailed;
uint g_diagnosticsDropped;
array<DiagnosticsPacket@> g_diagnosticsQueue;
array<DiagnosticsRequest@> g_diagnosticsRequests;

class DiagnosticsPacket
{
    string body;
    string endpoint;
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
    return Setting_DiagnosticsEndpoint.StartsWith("http://") || Setting_DiagnosticsEndpoint.StartsWith("https://");
}

bool DiagnosticsEnqueue(const string &in id, uint index, const string &in kind, const string &in data, const string &in endpoint)
{
    if (g_diagnosticsQueue.Length >= 64 || endpoint.Length == 0) { g_diagnosticsDropped++; return false; }
    DiagnosticsPacket@ packet = DiagnosticsPacket();
    // id/game/kind are generated constants; data is already serialized JSON.
    packet.body = "{\"schemaVersion\":\"1.1.0\",\"captureId\":\"" + id + "\",\"game\":\"" + DiagnosticsGame() + "\",\"index\":" + index + ",\"kind\":\"" + kind + "\",\"data\":" + data + "}";
    packet.endpoint = endpoint;
    g_diagnosticsQueue.InsertLast(packet);
    return true;
}

// Called once per game frame from the diagnostics-only Update hook. Never
// yields, sleeps or waits on HTTP completion.
void DiagnosticsTick()
{
    bool wanted = Setting_DiagnosticsEnabled && DiagnosticsConfigured();
    if (!wanted && g_diagnosticsRecording) g_diagnosticsCancel = true;
    if (!g_diagnosticsRecording) {
        if (Setting_DiagnosticsEnabled && !wanted) g_diagnosticsStatus = "Set an http:// or https:// receiver URL.";
        else if (wanted && Time::Now >= g_diagnosticsNextStart) {
            // A recording ends on disable or a segment limit; start the next one
            // while enabled. The delay prevents a tight loop after a failure.
            g_diagnosticsCancel = false;
            g_diagnosticsRecording = true;
            startnew(CoroutineFunc(DiagnosticsRecordRun));
        }
    }
    DiagnosticsPumpHttp();
}

void DiagnosticsPumpHttp()
{
    if (!g_diagnosticsRequests.IsEmpty()) {
        uint index = g_diagnosticsRequestCursor % g_diagnosticsRequests.Length;
        DiagnosticsRequest@ pending = g_diagnosticsRequests[index];
        bool remove = false;
        try {
            if (pending is null || pending.request is null) { remove = true; g_diagnosticsFailed++; }
            else if (pending.request.Finished()) {
                g_diagnosticsLastHttpStatus = pending.request.ResponseCode();
                if (g_diagnosticsLastHttpStatus < 200 || g_diagnosticsLastHttpStatus >= 300) g_diagnosticsFailed++;
                remove = true;
            } else if (Time::Now - pending.started >= 5000) {
                pending.request.Cancel();
                g_diagnosticsFailed++;
                remove = true;
            }
        } catch {
            g_diagnosticsSenderError = "HTTP cleanup failed; request discarded";
            g_diagnosticsFailed++;
            remove = true;
        }
        if (remove) g_diagnosticsRequests.RemoveAt(index);
        g_diagnosticsRequestCursor = remove ? index : index + 1;
    }
    // At most one launch per frame and four in-flight requests. Never block
    // collection on an acknowledgement and never retry.
    if (g_diagnosticsRequests.Length < 4 && !g_diagnosticsQueue.IsEmpty()) {
        DiagnosticsPacket@ packet = g_diagnosticsQueue[0];
        g_diagnosticsQueue.RemoveAt(0);
        try {
            DiagnosticsRequest@ pending = DiagnosticsRequest();
            @pending.request = Net::HttpRequest();
            pending.request.Url = packet.endpoint;
            pending.request.Method = Net::HttpMethod::Post;
            pending.request.Redirect = false;
            pending.request.Headers["Content-Type"] = "application/json; charset=utf-8";
            pending.request.Body = packet.body;
            pending.started = Time::Now;
            pending.request.Start();
            g_diagnosticsRequests.InsertLast(pending);
            g_diagnosticsStarted++;
        } catch {
            g_diagnosticsSenderError = "HTTP start failed; packet discarded";
            g_diagnosticsFailed++;
        }
    }
}

void DiagnosticsRecordRun()
{
    try {
        DiagnosticsRunRecorder recorder;
        recorder.Run();
        g_diagnosticsStatus = "Last recording: " + recorder.packetIndex + " records attempted, " + recorder.dropped + " local drops.";
    } catch { g_diagnosticsStatus = "Recording failed; previously received records remain available."; }
    g_diagnosticsNextStart = Time::Now + 1000;
    g_diagnosticsRecording = false;
}

[SettingsTab name="Diagnostics status"]
void RenderDiagnosticsStatus()
{
    UI::Text("Diagnostics build " + DIAGNOSTICS_VERSION);
    UI::TextWrapped(g_diagnosticsStatus);
    UI::Text("Requests started: " + g_diagnosticsStarted + ", failed: " + g_diagnosticsFailed + ", dropped locally: " + g_diagnosticsDropped);
    UI::Text("Queued: " + g_diagnosticsQueue.Length + ", in-flight: " + g_diagnosticsRequests.Length + ", last HTTP status: " + g_diagnosticsLastHttpStatus);
    if (g_diagnosticsSenderError.Length > 0) UI::TextWrapped("Last sender error: " + g_diagnosticsSenderError);
}
#endif
