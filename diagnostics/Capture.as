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
    array<string> chunks;
    Json::Value batch = Json::Array();
    Json::Value issues = Json::Array();
    uint batchBytes;
    uint bytes;
    uint read;
    uint excluded;
    uint unsupported;
    uint failed;
    uint truncated;
    uint objectsRead;
    uint definitionsRead;
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

    bool LimitReached()
    {
        if (g_diagnosticsCancel) { stopped = true; reason = "cancelled"; }
        if (Time::Now - started >= timeout) { stopped = true; reason = "time budget"; }
        if (sceneBound && GetApp().CurrentPlayground !is initialPlayground) { stopped = true; reason = "playground changed"; }
        return stopped;
    }

    bool Checkpoint()
    {
        if (Time::Now - frameStarted >= 2) { yield(); frameStarted = Time::Now; }
        return LimitReached();
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
        fields[name] = value;
        read++;
    }

    void ArrayField(Json::Value &inout fields, const string &in name, Json::Value &in values, uint length)
    {
        Json::Value value = Json::Object();
        value["length"] = length;
        value["values"] = values;
        value["status"] = length > maxArray ? "truncated" : "captured";
        if (length > maxArray) truncated++;
        Field(fields, name, value);
    }

    void Skipped(const string &in name, const string &in status, const string &in detail)
    {
        Json::Value issue = Json::Object();
        issue["member"] = name;
        issue["status"] = status;
        issue["reason"] = detail;
        issues.Add(issue);
        if (status == "excluded") excluded++;
        else if (status == "failed") failed++;
        else unsupported++;
    }

    void Emit(Json::Value &in record)
    {
        string serialized = Json::Write(record);
        // Keep every wire envelope below the receiver's 1 MiB bound.
        if (serialized.Length > 256 * 1024) {
            record = Json::Object();
            record["kind"] = "omitted-record";
            record["path"] = path;
            record["status"] = "truncated";
            record["reason"] = "record exceeds 256 KiB";
            serialized = Json::Write(record);
            truncated++;
        }
        if (bytes + serialized.Length > 16 * 1024 * 1024) { stopped = true; reason = "byte budget"; return; }
        if (batchBytes + serialized.Length > 384 * 1024) Flush();
        batch.Add(record);
        batchBytes += serialized.Length + 1;
        bytes += serialized.Length + 1;
    }

    void Flush()
    {
        if (batch.Length == 0) return;
        chunks.InsertLast(Json::Write(batch));
        batch = Json::Array();
        batchBytes = 0;
    }

    void Run()
    {
        auto app = GetApp();
        if (app is null) { stopped = true; reason = "app unavailable"; return; }
        @initialPlayground = app.CurrentPlayground;
        sceneBound = true;
        DiagnosticsHelpers(this);
        Link(app, 0);
        path = "GetApp";
        member = "CurrentPlayground";
        Link(app.CurrentPlayground, 1);
        for (uint index = 0; index < nodes.Length && !LimitReached(); index++) {
            if (app.CurrentPlayground !is initialPlayground) { stopped = true; reason = "playground changed"; break; }
            auto item = nodes[index];
            path = item.path;
            issues = Json::Array();
            Json::Value fields = Json::Object();
            Json::Value inventory = Json::Array();
            auto type = Reflection::TypeOf(item.node);
            string runtimeType = type is null ? "unknown" : type.Name;
            while (type !is null && !LimitReached()) {
                bool supported = DiagnosticsReadType(this, item.node, type.Name, fields, item.depth);
                auto members = type.Members;
                for (uint i = 0; i < members.Length; i++) {
                    Json::Value entry = Json::Object();
                    entry["type"] = type.Name;
                    entry["name"] = members[i].Name;
                    entry["id"] = members[i].ID;
                    string key = type.Name + "." + members[i].Name;
                    entry["status"] = fields.HasKey(key) ? "captured" : "not-captured";
                    inventory.Add(entry);
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
            record["fields"] = fields;
            record["issues"] = issues;
            record["runtimeMembers"] = inventory;
            Emit(record);
            objectsRead++;
            g_diagnosticsStatus = "Capturing: " + objectsRead + " objects, " + read + " fields";
            // A bounded object is read without yielding, then traversal yields.
            yield();
        }
        nodes.RemoveRange(0, nodes.Length);
        sceneBound = false;
        EmitDefinitions();
        Flush();
    }

    void EmitDefinitions()
    {
        IO::FileSource source("diagnostics/generated/" + DiagnosticsGame() + "-api.json");
        Json::Value definitions = Json::Parse(source.ReadToEnd());
        for (uint i = 0; i < definitions.Length && !Checkpoint(); i++) {
            Json::Value record = Json::Object();
            record["kind"] = "api-definition";
            record["path"] = "api/" + string(definitions[i]["name"]);
            record["definition"] = definitions[i];
            path = string(record["path"]);
            Emit(record);
            definitionsRead++;
        }
    }

    Json::Value Manifest()
    {
        Json::Value result = Json::Object();
        result["startedAt"] = startedAt;
        result["endedAt"] = OccurredAtUtc();
        result["status"] = captureFailed ? "failed" : (g_diagnosticsCancel ? "cancelled" : (stopped || truncated > 0 ? "truncated" : "complete"));
        result["reason"] = reason;
        result["pluginVersion"] = Meta::ExecutingPlugin().Version;
        result["runtimeVersion"] = Meta::OpenplanetVersion();
        result["runtimeCommit"] = Meta::OpenplanetVersionGitCommit();
        result["collectorVersion"] = "1.0.1";
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
