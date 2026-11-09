#if DIAGNOSTICS
bool g_diagnosticsBusy;
bool g_diagnosticsCancel;
string g_diagnosticsStatus = "Idle. Full dumps may contain sensitive game data.";
const string DIAGNOSTICS_SPOOL = "diagnostics-pending.json";

string DiagnosticsGame()
{
#if TURBO
    return "turbo";
#else
    return "next";
#endif
}

void RenderMenu()
{
    if (UI::MenuItem("Capture full diagnostics dump", "", false, !g_diagnosticsBusy)) startnew(DiagnosticsCaptureAndUpload);
}

[SettingsTab name="Diagnostics status"]
void RenderDiagnosticsSettings()
{
    UI::TextWrapped("DIAGNOSTICS BUILD: traverses exposed game objects. Sensitive member names are excluded, but free-text game values may still contain private data. Review local dumps before sharing them.");
    UI::TextWrapped(g_diagnosticsStatus);
    if (!g_diagnosticsBusy) {
        if (UI::Button("Capture full dump and upload")) startnew(DiagnosticsCaptureAndUpload);
        if (IO::FileExists(IO::FromStorageFolder(DIAGNOSTICS_SPOOL))) {
            if (UI::Button("Retry pending upload")) startnew(DiagnosticsRetryUpload);
            if (UI::Button("Delete pending local dump")) {
                IO::Delete(IO::FromStorageFolder(DIAGNOSTICS_SPOOL));
                g_diagnosticsStatus = "Pending local dump deleted.";
            }
        }
    } else if (UI::Button("Cancel diagnostics job")) g_diagnosticsCancel = true;
}

void DiagnosticsWriteSpool(Json::Value &in capture)
{
    string path = IO::FromStorageFolder(DIAGNOSTICS_SPOOL);
    IO::File file(path + ".tmp", IO::FileMode::Write);
    file.Write(Json::Write(capture));
    file.Close();
    // Keep the previous spool unless the replacement has been written fully.
    if (IO::FileExists(path)) throw("Pending diagnostics capture already exists");
    IO::Move(path + ".tmp", path);
}

void DiagnosticsCaptureAndUpload()
{
    if (g_diagnosticsBusy) return;
    if (IO::FileExists(IO::FromStorageFolder(DIAGNOSTICS_SPOOL))) {
        g_diagnosticsStatus = "Retry or delete the pending dump before starting another capture.";
        return;
    }
    g_diagnosticsBusy = true;
    g_diagnosticsCancel = false;
    try {
        DiagnosticsCapture capture;
        try { capture.Run(); } catch { capture.captureFailed = true; capture.reason = "collector exception"; capture.Flush(); }
        capture.nodes.RemoveRange(0, capture.nodes.Length);
        // A valid capture always has at least one records chunk and a manifest.
        if (capture.chunks.IsEmpty()) capture.chunks.InsertLast("[]");
        Json::Value saved = Json::Object();
        saved["captureId"] = capture.id;
        saved["game"] = DiagnosticsGame();
        Json::Value chunks = Json::Array();
        for (uint i = 0; i < capture.chunks.Length; i++) chunks.Add(Json::Parse(capture.chunks[i]));
        saved["chunks"] = chunks;
        saved["manifest"] = capture.Manifest();
        DiagnosticsWriteSpool(saved);
        if (!g_diagnosticsCancel) DiagnosticsUpload(saved);
        else g_diagnosticsStatus = "Capture cancelled; partial dump saved locally. Retry to upload it.";
    } catch {
        g_diagnosticsStatus = "Diagnostics failed. Check pending local dump; game getters may be unavailable in this state.";
    }
    g_diagnosticsBusy = false;
}

void DiagnosticsRetryUpload()
{
    if (g_diagnosticsBusy) return;
    g_diagnosticsBusy = true;
    g_diagnosticsCancel = false;
    try {
        IO::File file(IO::FromStorageFolder(DIAGNOSTICS_SPOOL), IO::FileMode::Read);
        Json::Value capture = Json::Parse(file.ReadToEnd());
        file.Close();
        DiagnosticsUpload(capture);
    } catch { g_diagnosticsStatus = "Could not read pending dump. Delete it to start a new capture."; }
    g_diagnosticsBusy = false;
}

void DiagnosticsUpload(Json::Value &in capture)
{
    // Bind the entire job to one explicit destination and token. Never borrow
    // webhook settings or mix receivers when settings change during a yield.
    string endpoint = Setting_DiagnosticsEndpoint;
    string token = Setting_DiagnosticsToken;
    if (endpoint.Length == 0 || token.Length == 0) {
        g_diagnosticsStatus = "Dump saved locally. Set the diagnostics endpoint and dedicated token, then retry.";
        return;
    }
    if (!endpoint.StartsWith("http://") && !endpoint.StartsWith("https://")) {
        g_diagnosticsStatus = "Diagnostics endpoint must be an HTTP or HTTPS URL.";
        return;
    }
    uint count = capture["chunks"].Length + 1;
    for (uint i = 0; i < count; i++) {
        Json::Value envelope = Json::Object();
        envelope["schemaVersion"] = "1.0.0";
        envelope["captureId"] = capture["captureId"];
        envelope["game"] = capture["game"];
        envelope["index"] = i;
        envelope["total"] = count;
        envelope["kind"] = i + 1 == count ? "manifest" : "records";
        envelope["data"] = i + 1 == count ? capture["manifest"] : capture["chunks"][i];
        string body = Json::Write(envelope);
        bool accepted;
        for (uint attempt = 0; attempt < 4 && !g_diagnosticsCancel; attempt++) {
            g_diagnosticsStatus = "Uploading chunk " + (i + 1) + "/" + count + ", attempt " + (attempt + 1);
            Net::HttpRequest@ request = Net::HttpRequest();
            request.Url = endpoint;
            request.Method = Net::HttpMethod::Post;
            request.Redirect = false;
            request.Headers["Content-Type"] = "application/json; charset=utf-8";
            request.Headers["Authorization"] = "Bearer " + token;
            request.Body = body;
            request.Start();
            uint started = Time::Now;
            while (!request.Finished() && !g_diagnosticsCancel && Time::Now - started < 15000) yield();
            bool timedOut = !request.Finished();
            if (timedOut) request.Cancel();
            if (g_diagnosticsCancel) break;
            int status = timedOut ? 0 : request.ResponseCode();
            if (status >= 200 && status < 300) { accepted = true; break; }
            if (!(status == 0 || status == 408 || status == 429 || status >= 500)) break;
            uint delay = 1000 * (1 << attempt);
            string retryAfter = request.ResponseHeader("Retry-After");
            if (retryAfter.Length > 0) {
                int seconds = Text::ParseInt(retryAfter);
                if (seconds > 0) delay = uint(Math::Min(seconds, 60)) * 1000;
            }
            uint waitStart = Time::Now;
            while (!g_diagnosticsCancel && Time::Now - waitStart < delay) yield();
        }
        if (!accepted) {
            g_diagnosticsStatus = g_diagnosticsCancel ? "Upload cancelled; dump retained locally." : "Upload failed; dump retained locally. Retry replays idempotent chunks.";
            return;
        }
    }
    IO::Delete(IO::FromStorageFolder(DIAGNOSTICS_SPOOL));
    g_diagnosticsStatus = "Diagnostics capture uploaded successfully.";
}
#endif
