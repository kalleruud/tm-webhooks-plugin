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
