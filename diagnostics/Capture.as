#if DIAGNOSTICS
// This entire directory is absent from production archives.
class DiagnosticsNode
{
    CMwNod@ node;
    uint depth;
    string path;
    DiagnosticsNode(CMwNod@ value, uint level, const string &in route) { @node = value; depth = level; path = route; }
}

class DiagnosticsCapture
{
    array<DiagnosticsNode@> nodes;
    uint objectIssues;
    uint bytes;
    uint read;
    uint excluded;
    uint unsupported;
    uint failed;
    uint truncated;
    uint objectsRead;
    uint definitionsRead;
    uint packetIndex;
    uint objectIndex;
    uint locallyDropped;
    string endpoint = Setting_DiagnosticsEndpoint;
    string token = Setting_DiagnosticsToken;
    uint maxObjects = Math::Clamp(int(Setting_DiagnosticsObjects), 1, 10000);
    uint maxDepth = Math::Clamp(int(Setting_DiagnosticsDepth), 1, 32);
    uint maxArray = Math::Clamp(int(Setting_DiagnosticsArray), 1, 512);
    uint maxString = Math::Clamp(int(Setting_DiagnosticsString), 64, 16384);
    uint timeout = Math::Clamp(int(Setting_DiagnosticsSeconds), 1, 120) * 1000;
    uint started = Time::Now;
    string startedAt = OccurredAtUtc();
    string id = CreateUuidV4();
    string path;
    string member;
    string reason;
    bool stopped;
    bool captureFailed;
    bool sceneBound;
    CMwNod@ initialPlayground;
    uint frameStarted = Time::Now;
    uint workSteps;
    bool readValues = Setting_DiagnosticsReadValues;
    bool includeAPI = Setting_DiagnosticsIncludeAPI;
    bool tracing = Setting_DiagnosticsTrace;

    bool LimitReached()
    {
        if (g_diagnosticsCancel) { stopped = true; reason = "cancelled"; }
        if (Time::Now - started >= timeout) { stopped = true; reason = "time budget"; }
        if (sceneBound && GetApp().CurrentPlayground !is initialPlayground) { stopped = true; reason = "playground changed"; }
        return stopped;
    }

    bool Checkpoint()
    {
        // Never rely solely on a clock that may not advance within a frame.
        workSteps++;
        if (workSteps >= 32 || Time::Now - frameStarted >= 2) {
            yield();
            workSteps = 0;
            frameStarted = Time::Now;
        }
        return LimitReached();
    }

    void Trace(const string &in phase, const string &in operation = "")
    {
        if (!tracing) return;
        try {
            Json::Value breadcrumb = Json::Object();
            breadcrumb["captureId"] = id;
            breadcrumb["collectorVersion"] = "1.1.0";
            breadcrumb["game"] = DiagnosticsGame();
            breadcrumb["phase"] = phase;
            breadcrumb["member"] = operation;
            breadcrumb["objectsRead"] = objectsRead;
            breadcrumb["capturedFields"] = read;
            breadcrumb["nativeValues"] = readValues;
            IO::File file(IO::FromStorageFolder("diagnostics-last-operation.json"), IO::FileMode::Write);
            file.Write(Json::Write(breadcrumb));
            file.Flush();
            file.Close();
        } catch {
            tracing = false;
            warn("[diagnostics] last-operation breadcrumb could not be written");
        }
    }

    void BeginMember(const string &in name)
    {
        member = name;
        g_diagnosticsStatus = "Reading " + name;
        Trace("getter", name);
    }

    Json::Value Number(double value)
    {
        if (Math::IsNaN(value) || Math::IsInf(value)) return Json::Value(tostring(value));
        return Json::Value(value);
    }

    Json::Value Text(const string &in value)
    {
        if (uint(value.Length) <= maxString) return Json::Value(value);
        truncated++;
        Json::Value result = Json::Object();
        result["status"] = "truncated";
        result["length"] = value.Length;
        // UTF-8 byte truncation can cut a code point. Preserve the valid prefix.
        uint end = maxString;
        while (end > 0 && (value[end] & 0xC0) == 0x80) end--;
        result["value"] = value.SubStr(0, end);
        return result;
    }

    Json::Value Link(CMwNod@ node, uint depth)
    {
        if (node is null) return Json::Value();
        Json::Value result = Json::Object();
        for (uint i = 0; i < nodes.Length; i++) {
            if (i % 128 == 0 && Checkpoint()) {
                result["status"] = "truncated";
                result["reason"] = reason;
                truncated++;
                return result;
            }
            if (nodes[i].node is node) { result["ref"] = i; return result; }
        }
        if (depth > maxDepth || nodes.Length >= maxObjects) {
            result["status"] = "truncated";
            result["reason"] = depth > maxDepth ? "depth limit" : "object limit";
            truncated++;
            return result;
        }
        result["ref"] = nodes.Length;
        nodes.InsertLast(DiagnosticsNode(node, depth, path.Length == 0 ? "GetApp" : path + "/" + member + "/" + nodes.Length));
        return result;
    }

    void Field(Json::Value &inout fields, const string &in name, Json::Value@ value)
    {
        // Keep only a small coverage marker in the object summary. Values are
        // serialized once and queued immediately, never accumulated into a dump.
        fields[name] = true;
        Json::Value record = Json::Object();
        record["kind"] = "field";
        record["objectId"] = objectIndex;
        record["member"] = name;
        record["value"] = value;
        Emit(record);
        read++;
    }

    void ArrayElement(const string &in name, uint index, uint length, Json::Value@ value)
    {
        Json::Value record = Json::Object();
        record["kind"] = "array-element";
        record["objectId"] = objectIndex;
        record["member"] = name;
        record["index"] = index;
        record["length"] = length;
        record["value"] = value;
        Emit(record);
    }

    void ArrayField(Json::Value &inout fields, const string &in name, uint captured, uint length)
    {
        Json::Value value = Json::Object();
        value["length"] = length;
        value["capturedElements"] = captured;
        value["status"] = length > captured ? "truncated" : "captured";
        if (length > captured) truncated++;
        Field(fields, name, value);
    }

    void Skipped(const string &in name, const string &in status, const string &in detail)
    {
        Json::Value issue = Json::Object();
        issue["member"] = name;
        issue["status"] = status;
        issue["reason"] = detail;
        objectIssues++;
        issue["kind"] = "coverage-issue";
        issue["objectId"] = objectIndex;
        Emit(issue);
        if (status == "excluded") excluded++;
        else if (status == "failed") failed++;
        else unsupported++;
    }

    void Emit(Json::Value &in record)
    {
        // One small value/definition at a time. No Json::Write(batch), capture
        // spool, or second parse/serialization pass on the game thread.
        if (g_diagnosticsCancel) return;
        if (packetIndex >= 32767) { stopped = true; reason = "packet budget"; return; }
        string serialized = Json::Write(record);
        uint index = packetIndex++;
        if (serialized.Length > 24 * 1024 || bytes + serialized.Length > 16 * 1024 * 1024) {
            locallyDropped++;
            truncated++;
            if (bytes + serialized.Length > 16 * 1024 * 1024) { stopped = true; reason = "stream budget"; }
        } else {
            bytes += serialized.Length;
            if (!DiagnosticsEnqueue(id, index, "record", serialized, endpoint, token)) locallyDropped++;
        }
        // Always hand back the frame after a serialization, even if Time::Now
        // has not advanced. Individual native getters remain non-preemptible.
        yield();
    }

    void SendManifest()
    {
        Json::Value manifest = Manifest();
        DiagnosticsEnqueue(id, packetIndex, "manifest", Json::Write(manifest), endpoint, token);
    }

    void Run()
    {
        auto app = GetApp();
        if (app is null) { stopped = true; reason = "app unavailable"; return; }
        Trace("starting");
        if (readValues) {
            Trace("getter", "CGameCtnApp.CurrentPlayground");
            @initialPlayground = app.CurrentPlayground;
            sceneBound = true;
            Trace("helpers");
            DiagnosticsHelpers(this);
        }
        Link(app, 0);
        path = "GetApp";
        member = "CurrentPlayground";
        if (readValues) Link(app.CurrentPlayground, 1);
        for (uint index = 0; index < nodes.Length && !LimitReached(); index++) {
            if (sceneBound && app.CurrentPlayground !is initialPlayground) { stopped = true; reason = "playground changed"; break; }
            objectIndex = index;
            auto item = nodes[index];
            path = item.path;
            objectIssues = 0;
            Json::Value fields = Json::Object();
            uint runtimeMemberCount;
            Trace("reflection-type");
            auto type = Reflection::TypeOf(item.node);
            string runtimeType = type is null ? "unknown" : type.Name;
            while (type !is null && !LimitReached()) {
                bool supported = !readValues || DiagnosticsReadType(this, item.node, type.Name, fields, item.depth);
                if (!readValues) Skipped(type.Name, "excluded", "native value reads disabled; metadata-only capture");
                Trace("reflection-members", type.Name);
                auto members = type.Members;
                for (uint i = 0; i < members.Length; i++) {
                    if (Checkpoint()) break;
                    Json::Value entry = Json::Object();
                    entry["type"] = type.Name;
                    entry["name"] = members[i].Name;
                    entry["id"] = members[i].ID;
                    string key = type.Name + "." + members[i].Name;
                    entry["status"] = fields.HasKey(key) ? "captured" : "not-captured";
                    runtimeMemberCount++;
                    entry["kind"] = "runtime-member";
                    entry["objectId"] = index;
                    Emit(entry);
                }
                if (!supported) Skipped(type.Name, "unsupported", "runtime class absent from generated API inventory");
                @type = type.BaseType;
            }
            Json::Value record = Json::Object();
            record["kind"] = "object";
            record["id"] = index;
            record["path"] = path;
            record["type"] = runtimeType;
            record["observedAt"] = OccurredAtUtc();
            record["capturedMembers"] = fields.GetKeys().Length;
            record["issuesCount"] = objectIssues;
            record["runtimeMemberCount"] = runtimeMemberCount;
            Trace("serializing-object");
            Emit(record);
            objectsRead++;
            g_diagnosticsStatus = "Capturing: " + objectsRead + " objects, " + read + " fields";
            // Also yield at object boundaries, independently of getter checkpoints.
            yield();
        }
        nodes.RemoveRange(0, nodes.Length);
        sceneBound = false;
        if (includeAPI && !LimitReached()) EmitDefinitions();
    }

    void EmitDefinitions()
    {
        Trace("loading-api-definitions");
        yield();
        IO::FileSource source("diagnostics/generated/" + DiagnosticsGame() + "-api.json");
        Json::Value definitions = Json::Parse(source.ReadToEnd());
        yield();
        for (uint i = 0; i < definitions.Length && !Checkpoint(); i++) {
            Trace("api-definition", string(definitions[i]["name"]));
            Json::Value definition = definitions[i];
            Json::Value record = Json::Object();
            record["kind"] = "api-definition";
            record["name"] = definition["name"];
            record["base"] = definition["base"];
            record["url"] = definition["url"];
            Emit(record);
            for (uint j = 0; j < definition["members"].Length && !Checkpoint(); j++) {
                Json::Value field = Json::Object();
                field["kind"] = "api-member";
                field["type"] = definition["name"];
                field["member"] = definition["members"][j];
                Emit(field);
            }
            for (uint j = 0; j < definition["methods"].Length && !Checkpoint(); j++) {
                Json::Value method = Json::Object();
                method["kind"] = "api-method";
                method["type"] = definition["name"];
                method["signature"] = Text(string(definition["methods"][j]));
                Emit(method);
            }
            definitionsRead++;
        }
    }

    Json::Value Manifest()
    {
        Json::Value result = Json::Object();
        result["startedAt"] = startedAt;
        result["endedAt"] = OccurredAtUtc();
        result["status"] = captureFailed ? "failed" : (g_diagnosticsCancel ? "cancelled" : (stopped || truncated > 0 || locallyDropped > 0 ? "truncated" : "complete"));
        result["reason"] = reason;
        result["pluginVersion"] = Meta::ExecutingPlugin().Version;
        result["runtimeVersion"] = Meta::OpenplanetVersion();
        result["runtimeCommit"] = Meta::OpenplanetVersionGitCommit();
        result["collectorVersion"] = "1.1.0";
        result["captureMode"] = readValues ? "native-values" : "metadata-only";
        result["includeStaticAPI"] = includeAPI;
        result["game"] = AdapterGameName();
        result["inventoryHash"] = DiagnosticsInventoryHash();
        result["objects"] = objectsRead;
        result["apiDefinitions"] = definitionsRead;
        result["capturedFields"] = read;
        result["excludedFields"] = excluded;
        result["unsupportedFields"] = unsupported;
        result["failedFields"] = failed;
        result["truncations"] = truncated;
        result["payloadBytes"] = bytes;
        result["attemptedRecords"] = packetIndex;
        result["locallyDroppedRecords"] = locallyDropped;
        result["delivery"] = "best-effort; no retries or acknowledgement waits";
        result["maxObjects"] = maxObjects;
        result["maxDepth"] = maxDepth;
        result["maxArray"] = maxArray;
        result["maxString"] = maxString;
        result["timeoutMs"] = timeout;
        result["snapshot"] = "multi-frame; per-object timestamps";
        return result;
    }
}
#endif
