const string SCHEMA_VERSION = "1.1.0";
const string PLUGIN_NAME = "TM Webhooks";
const uint MAX_QUEUE_SIZE = 1000;

class PlayerSnapshot
{
    uint playerIndex;
    string name;
    string login;
    string localId;
    string accountId;
}

class MapSnapshot
{
    string name;
    string uid;
    string author;
    string environment;
    string mapType;
    string level;
    bool isLaps;
    uint totalLaps;
    uint checkpointsPerLap;
    uint authorTime;
    uint goldTime;
    uint silverTime;
    uint bronzeTime;
}

class ModeSnapshot
{
    string name;
    string modeType;
}

class PlayerObservation
{
    PlayerSnapshot@ player;
    uint durationMs;
    int checkpointDurationMs = -1;
    int finishDurationMs = -1;
    float throttle;
    uint checkpointIndex;
    uint checkpointLapIndex;
    uint lapNumber = 1;
    uint respawnCount;
    bool finished;
    int theoreticalDurationMs = -1;
    int lostMs = -1;
}

class GameObservation
{
    bool local;
    bool active;
    string sessionKey;
    string endReason = "unknown";
    array<PlayerSnapshot@> players;
    array<PlayerObservation@> playerStates;
    MapSnapshot@ map;
    ModeSnapshot@ mode;
}

class CapturedEvent
{
    string eventType;
    string eventId;
    string gameId;
    uint sequence;
    string occurredAt;
    uint durationMs;
    uint totalPlayers;
    PlayerSnapshot@ player;
    array<PlayerSnapshot@> players;
    MapSnapshot@ map;
    ModeSnapshot@ mode;
    uint checkpointIndex;
    uint checkpointLapIndex;
    uint lapNumber;
    int theoreticalDurationMs = -1;
    int lostMs = -1;
    string endReason;
}

class PendingWebhook
{
    string eventId;
    string eventType;
    uint eventSequence;
    string payload;

    PendingWebhook(const string &in id, const string &in type, uint sequence, const string &in body)
    {
        eventId = id;
        eventType = type;
        eventSequence = sequence;
        payload = body;
    }
}
