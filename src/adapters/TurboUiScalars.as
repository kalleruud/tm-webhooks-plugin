#if TURBO
// Read only the verified scalar subset of Dbg_DumpDeclareForVariables.
// Unknown, duplicate, truncated or malformed values fail closed.
bool ReadTurboUiScalar(const string &in dump, const string &in section, const string &in type, const string &in key, string &out value)
{
    bool inSection = false;
    bool found = false;
    auto lines = dump.Split("\n");
    for (uint i = 0; i < lines.Length; i++) {
        string line = lines[i].Trim();
        if (line.StartsWith("netwrite:") || line.StartsWith("netread:") || line.StartsWith("persistent:")) {
            inSection = line.StartsWith(section + ":");
            continue;
        }
        if (!inSection) continue;
        int colon = line.IndexOf(":");
        if (colon < 1) continue;
        string definition = line.SubStr(colon + 1).Trim();
        if (!definition.StartsWith(type + " ")) continue;
        definition = definition.SubStr(type.Length).Trim();
        string prefix = key + " = ";
        if (!definition.StartsWith(prefix)) continue;
        if (found) return false;
        value = definition.SubStr(prefix.Length);
        found = true;
    }
    return found;
}

bool ReadTurboUiInteger(const string &in dump, const string &in section, const string &in key, int &out value)
{
    string raw;
    if (!ReadTurboUiScalar(dump, section, "Integer", key, raw) || raw.Length == 0 || raw.Length > 10) return false;
    uint start = raw.StartsWith("-") ? 1 : 0;
    if (start == raw.Length) return false;
    int64 number = 0;
    for (uint i = start; i < raw.Length; i++) {
        if (raw[i] < 48 || raw[i] > 57) return false;
        number = number * 10 + int(raw[i] - 48);
        if (number > (start == 1 ? int64(2147483648) : int64(2147483647))) return false;
    }
    value = int(start == 1 ? -number : number);
    return true;
}

bool ReadTurboUiText(const string &in dump, const string &in section, const string &in key, string &out value)
{
    value = "";
    string raw;
    if (!ReadTurboUiScalar(dump, section, "Text", key, raw)) return false;
    try {
        Json::Value@ parsed = Json::Parse(raw);
        if (parsed.GetType() != Json::Type::String) return false;
        value = string(parsed);
        return true;
    } catch { return false; }
}

#endif
