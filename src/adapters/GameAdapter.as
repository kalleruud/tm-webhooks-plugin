interface GameAdapter
{
    GameObservation@ Observe();
}

GameAdapter@ CreateGameAdapter()
{
#if TMNEXT
    return NextGameAdapter();
#elif TURBO
    return TurboGameAdapter();
#else
    return null;
#endif
}

string AdapterGameName()
{
#if TMNEXT
    return "next";
#else
    return "turbo";
#endif
}

// Both games expose Difficulty as an unnamed enum in this order:
// White, Green, Blue, Red, Black, Custom. Other values are unavailable/unknown.
string MapDifficultyLevel(uint difficulty)
{
    switch (difficulty) {
        case 0: return "white";
        case 1: return "green";
        case 2: return "blue";
        case 3: return "red";
        case 4: return "black";
        case 5: return "custom";
    }
    return "";
}

// Turbo reports the Trackmania map-type prefix with inconsistent
// capitalisation (for example TrackMania\Race and Trackmania\Race). Both games
// emit the canonical TrackMania\ prefix; suffixes and other values stay raw.
const string MAP_TYPE_PREFIX = "TrackMania\\";

string NormalizeMapType(const string &in mapType)
{
    int prefixLength = MAP_TYPE_PREFIX.Length;
    if (mapType.Length < prefixLength) return mapType;
    if (mapType.SubStr(0, prefixLength).ToLower() != MAP_TYPE_PREFIX.ToLower()) return mapType;
    return MAP_TYPE_PREFIX + mapType.SubStr(prefixLength);
}
