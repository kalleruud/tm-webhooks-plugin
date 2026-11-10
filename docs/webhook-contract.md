# Webhook Contract

This document defines the human-readable webhook model for schema version
`1.1.0`. `openapi.yaml` is the machine-readable authority and must remain
synchronized with this document.

## Transport

The plugin sends each event directly to the configured URL:

```http
POST /
Content-Type: application/json; charset=utf-8
event_type: <type>
event-id: <eventId>
event-sequence: <sequence>
[Authorization: Bearer <token>]
```

`event_type` is required and exactly matches the payload's `type` property.
`event-id` and `event-sequence` are required and exactly match the payload's
`eventId` and `sequence` properties. All three event headers remain unchanged
across retries.
`Authorization` is included only when a nonempty authentication token is
configured. An empty token sends an unauthenticated request.

There is no outer payload wrapper. The `type` property discriminates the event
shape. Object schemas permit undeclared properties for forward compatibility.
Unavailable string values are omitted, never represented by empty string
sentinels. When a string field is emitted, it is non-empty.

### Responses

Any `2xx` response is successful; the plugin ignores its body. The documented
success responses are `200 OK` and `204 No Content`.

Errors use this forward-compatible shape:

| Field     | Type   | Description                       | Rules                          |
| --------- | ------ | --------------------------------- | ------------------------------ |
| `code`    | string | Identifier for the response error | Required machine-readable code |
| `message` | string | Explanation of the response error | Optional human-readable detail |

`503 Service Unavailable` with `code: "NO_ACTIVE_SESSION"` means the event was
valid but arrived outside an active receiver session. It is retryable and may
include `Retry-After` as integer seconds or an HTTP date.

The plugin retries network errors, `408`, `429`, and all `5xx` responses. Other
`4xx` and all `3xx` responses are permanent failures.

## Models

Models group fields by functional dependency. Events compose these nested
models instead of repeating their fields at the event root.

### Source

| Field           | Type   | Description                         | Rules                   |
| --------------- | ------ | ----------------------------------- | ----------------------- |
| `pluginName`    | string | Name of the producing plugin        | Required; `TM Webhooks` |
| `pluginVersion` | string | Version of the producing plugin     | Required plugin SemVer  |
| `game`          | enum   | Trackmania game producing the event | `turbo` or `next`       |

### Game

| Field          | Type             | Description                    | Rules                                                |
| -------------- | ---------------- | ------------------------------ | ---------------------------------------------------- |
| `gameId`       | UUID string      | Identity of the captured round | Required UUID v4, shared by all events in the round  |
| `totalPlayers` | positive integer | Number of players in the round | Required and constant; equals `start.players.length` |

### Player

| Field           | Type                 | Description                          | Rules                                        |
| --------------- | -------------------- | ------------------------------------ | -------------------------------------------- |
| `sessionId`     | UUID string          | Local game session                   | Optional; verified arcade/Hot Seat capture   |
| `turnId`        | UUID string          | Arcade turn across rounds            | Optional; arcade only                        |
| `participantId` | UUID string          | Hot Seat human slot within session   | Optional; stable across confirmed renames    |
| `attemptId`     | UUID string          | Identity of this captured attempt    | Required UUID v4, stable across all events   |
| `playerIndex`   | non-negative integer | Position of the player in the roster | Required, zero-based, stable within the game |
| `name`          | string               | Display name of the player           | Optional; omitted when unavailable           |
| `login`         | string               | Game login of the player             | Optional; omitted when not exposed           |
| `localId`       | string               | Decimal engine-local login ID        | Optional; Next-only                          |
| `accountId`     | string               | Ubisoft/Nadeo WebServices account ID | Optional; Next-only                          |

`start.players` is ordered by contiguous index, so
`players[i].playerIndex == i`. Its length equals `game.totalPlayers`.
Each entry has an independently generated UUID v4 in `attemptId`. Player race
events carry the same value in `player.attemptId` as the corresponding
`start.players[i].attemptId`. Checkpoints, laps, and checkpoint respawns retain
it. A restart or new round assigns fresh IDs to every captured player, even
when names, accounts, player indices, and times are unchanged. A split-screen
round has a distinct attempt ID for each player. `game.gameId` continues to
identify the round; `end` has no player or attempt ID.

Receivers should use attempt IDs for attempt correlation instead of matching
names or times. The attempt ID does not identify a human across hot-seat turns; participantId does.
In standard Turbo arcade capture, `sessionId`
and `turnId` are included in start player entries and player race events. In
standard Turbo Hot Seat capture, `sessionId` and
`participantId` are included instead.
They correlate captured attempts across rounds. Session IDs reset on leaving
arcade, map/script/UI replacement, or a change in the configured player count.
Turn IDs follow observed arcade phase/credit lifecycle, never a count of finishes.
Hot Seat participant IDs follow configured human slots independently of the
shared engine player/login. Secret variants are not enabled.

Trackmania Next sources `login`, `localId`, and `accountId` from MLFeed V4's
login, login MwId, and WebServices user ID. Turbo sources `name` and `login`
from `CTrackManiaPlayer`, and omits `localId` and `accountId` because its
runtime does not expose equivalent values. Player string fields are emitted only
when non-empty.

### Map

| Field               | Type                 | Description                                | Rules                                          |
| ------------------- | -------------------- | ------------------------------------------ | ---------------------------------------------- |
| `name`              | string               | Display name of the map                    | Required                                       |
| `uid`               | string               | Unique identifier of the map               | Required                                       |
| `author`            | string               | Creator of the map                         | Required                                       |
| `environment`       | string               | Environment or setting used by the map     | Required                                       |
| `type`              | string               | Map type reported by the game              | Required                                       |
| `medalTimesMs`      | MedalTimes           | Target medal times in milliseconds         | Required; zero values mean unknown/not exposed |
| `isLaps`            | boolean              | Whether the map uses multiple laps         | Required                                       |
| `totalLaps`         | positive integer     | Number of laps required to finish          | Optional; emitted only for lap maps when `> 0` |
| `checkpointsPerLap` | non-negative integer | Number of intermediate checkpoints per lap | Required; excludes start and finish            |

Trackmania Next sources the map from `app.RootMap`; Trackmania Turbo sources it from `app.Challenge`. `start.map` is always emitted. It is `null` only if a start event is emitted before the game exposes a map object; Map string fields are serialized from scalar game API values and are never emitted as empty strings. `environment` is sourced from the map's `CollectionName` in both games.

### MedalTimes

| Field    | Type                 | Description             | Rules    |
| -------- | -------------------- | ----------------------- | -------- |
| `author` | non-negative integer | Author medal time in ms | Required |
| `gold`   | non-negative integer | Gold medal time in ms   | Required |
| `silver` | non-negative integer | Silver medal time in ms | Required |
| `bronze` | non-negative integer | Bronze medal time in ms | Required |

### Mode

| Field  | Type   | Description                  | Rules                                 |
| ------ | ------ | ---------------------------- | ------------------------------------- |
| `name` | enum   | Normalized local game mode   | Required                              |
| `type` | string | Specific mode or rule family | Optional; Not all types are supported |

Turbo emits `campaign`, `arcade`, `hot-seat`, `split-screen`, `secret`, or
`unknown` as `mode.name`. Next emits `campaign`, `solo`, or `split-screen`.
`unknown` is the Turbo fallback when the game does not expose enough information
to identify the local mode positively; the plugin never guesses another mode as
a fallback.

Turbo secret modes identify the activated rule set in `mode.type`:

| Secret family | `mode.type` values                                                                                                                                                                                                                                                                 |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Split screen  | `split-screen-classic-fun`, `split-screen-classic-pro`, `split-screen-smash-fun`, `split-screen-smash-pro`, `split-screen-mono-screen-fun`, `split-screen-mono-screen-pro`, `split-screen-stunt-fun`, `split-screen-stunt-pro`, `split-screen-bonus-fun`, `split-screen-bonus-pro` |
| Arcade        | `arcade-smash`, `arcade-stunt`                                                                                                                                                                                                                                                     |
| Hot seat      | `hot-seat-smash`, `hot-seat-stunt`                                                                                                                                                                                                                                                 |

Next split-screen play emits one of the six selectable local rule families as
`mode.type`. `unknown` is used if the game exposes neither a recognized rule
enum nor a recognizable script name. Its values are `time-attack`, `rounds`,
`laps`, `cup`, `royal-time-attack`, and `platform`.

Next solo play uses the same standard rule-family values and may additionally
emit `team` or `stunts` when exposed by the active game script. The optional
`mode.type` field is omitted when no meaningful rule family can be resolved.
Next campaign play emits `campaign` as `mode.name` without a `mode.type`.

### Checkpoint

Checkpoint fields describe a player's checkpoint position. Events include them
through a nested `checkpoint` object.

| Field                   | Type                 | Description                                | Rules                                              |
| ----------------------- | -------------------- | ------------------------------------------ | -------------------------------------------------- |
| `checkpointIndex`       | non-negative integer | Global checkpoint position across laps     | `0` at the start line; otherwise positive          |
| `checkpointLapIndex`    | non-negative integer | Checkpoint position within the current lap | See line-crossing convention below                 |
| `lapNumber`             | positive integer     | Current lap                                | Required and one-based                             |
| `theoreticalDurationMs` | non-negative integer | Checkpoint time without respawn losses     | Optional; Next-only MLFeed `LastTheoreticalCpTime` |
| `lostMs`                | non-negative integer | Dependency-provided time lost on respawn   | Optional, Next-only dependency value, unchanged    |

For a map with `N = map.checkpointsPerLap`, intermediate checkpoints use
`checkpointLapIndex` values `1..N`. A `lap` event describes the shared
start/finish line as the start of the newly entered lap and therefore uses `0`.
A `finish` event describes that same line as the end of the final lap and uses
`N + 1`. The same finish convention applies to point-to-point maps, so a
start-checkpoint-finish map with one intermediate checkpoint finishes at index
`2`.

## Events

### Common Fields

Race events contain the following fields. Session-scoped `score` and `player_name` use the same
metadata but omits `game` and `durationMs`, as detailed below:

| Field           | Type                 | Description                             | Rules                                                    |
| --------------- | -------------------- | --------------------------------------- | -------------------------------------------------------- |
| `schemaVersion` | string               | Version of the webhook payload schema   | Required SemVer; currently `1.1.0`                       |
| `type`          | string               | Kind of event represented               | Required event discriminator                             |
| `eventId`       | UUID string          | Unique identity of the captured event   | Globally unique UUID v4; immutable across retries        |
| `sequence`      | non-negative integer | Event position within the round         | Contiguous capture order within `game.gameId`            |
| `occurredAt`    | RFC 3339 string      | Wall-clock time of capture              | UTC with millisecond precision; immutable across retries |
| `durationMs`    | non-negative integer | Race-clock time of capture              | In-game race timer when the event occurred               |
| `game`          | Game                 | Identity and player count for the round | Required                                                 |
| `source`        | Source               | Metadata describing the event producer  | Required producer metadata                               |

`start.sequence` is `0` for complete captures. When capture begins mid-round,
the first captured event also uses sequence `0`, even though no start event was
emitted.

The examples form one Trackmania Turbo round and use fields supported by both
games. For Trackmania Next, `source.game` is `next`.

### `start`

Emitted exactly once when a fully captured round begins.

| Additional field | Type     | Description                        | Rules                                                   |
| ---------------- | -------- | ---------------------------------- | ------------------------------------------------------- |
| `players`        | Player[] | Players participating in the round | Required; ordered and length equals `game.totalPlayers` |
| `map`            | Map      | Map played during the round        | Nullable;                                               |
| `mode`           | Mode     | Game mode used during the round    | Nullable;                                               |

```json
{
  "schemaVersion": "1.1.0",
  "type": "start",
  "eventId": "4fda6f13-e003-47f6-a5df-32ec4e826749",
  "sequence": 0,
  "occurredAt": "2026-06-21T12:34:56.789Z",
  "durationMs": 0,
  "game": {
    "gameId": "b979cde4-2ef3-49b6-9ae8-c8231ba701f2",
    "totalPlayers": 1
  },
  "source": {
    "pluginName": "TM Webhooks",
    "pluginVersion": "x.y.z",
    "game": "turbo"
  },
  "players": [
    {
      "playerIndex": 0,
      "attemptId": "657ac0da-d1d5-4071-94f8-99dc0917636b",
      "name": "Player One",
      "login": "player-one"
    }
  ],
  "map": {
    "name": "Example Map",
    "uid": "ExampleMapUid",
    "author": "Mapper",
    "environment": "Stadium",
    "type": "TrackMania\\TM_Race",
    "medalTimesMs": {
      "author": 25000,
      "gold": 28000,
      "silver": 32000,
      "bronze": 40000
    },
    "isLaps": true,
    "totalLaps": 2,
    "checkpointsPerLap": 5
  },
  "mode": {
    "name": "campaign"
  }
}
```

### `first_throttle`

Emitted when the player first applies throttle during the game. It is emitted
at most once per player per game and never re-armed.

| Additional field | Type   | Description                         | Rules                                                 |
| ---------------- | ------ | ----------------------------------- | ----------------------------------------------------- |
| `player`         | Player | Full snapshot of the event's player | Required; matches `start.players[player.playerIndex]` |

```json
{
  "schemaVersion": "1.1.0",
  "type": "first_throttle",
  "eventId": "652d3844-9e57-4528-94e4-1bfe20c0b194",
  "sequence": 1,
  "occurredAt": "2026-06-21T12:34:56.914Z",
  "durationMs": 125,
  "game": {
    "gameId": "b979cde4-2ef3-49b6-9ae8-c8231ba701f2",
    "totalPlayers": 1
  },
  "source": {
    "pluginName": "TM Webhooks",
    "pluginVersion": "x.y.z",
    "game": "turbo"
  },
  "player": {
    "playerIndex": 0,
    "attemptId": "657ac0da-d1d5-4071-94f8-99dc0917636b",
    "name": "Player One",
    "login": "player-one"
  }
}
```

### `checkpoint`, `lap`, `respawn`, and `finish`

These event types share one contract:

| Event type   | Emitted when                                             | Rules                                                          |
| ------------ | -------------------------------------------------------- | -------------------------------------------------------------- |
| `checkpoint` | A player validates an intermediate checkpoint            | Both indices are positive; start and finish are not numbered   |
| `lap`        | A player starts a new lap after crossing the finish line | `checkpointLapIndex` is `0`; not emitted on the final finish   |
| `respawn`    | A respawn action is detected for a player                | Indices identify the destination and are both `0` at start     |
| `finish`     | A player finishes the round                              | At most once; `durationMs` is final and finish is not numbered |

| Additional field | Type       | Description                         | Rules                                                 |
| ---------------- | ---------- | ----------------------------------- | ----------------------------------------------------- |
| `player`         | Player     | Full snapshot of the event's player | Required; matches `start.players[player.playerIndex]` |
| `checkpoint`     | Checkpoint | Checkpoint state for the event      | Required                                              |

#### Example

```json
{
  "schemaVersion": "1.1.0",
  "type": "checkpoint",
  "eventId": "a86f8d3d-7a36-4ec4-a9c9-60c69932bfd1",
  "sequence": 2,
  "occurredAt": "2026-06-21T12:35:06.789Z",
  "durationMs": 10000,
  "game": {
    "gameId": "b979cde4-2ef3-49b6-9ae8-c8231ba701f2",
    "totalPlayers": 1
  },
  "source": {
    "pluginName": "TM Webhooks",
    "pluginVersion": "x.y.z",
    "game": "turbo"
  },
  "player": {
    "playerIndex": 0,
    "attemptId": "657ac0da-d1d5-4071-94f8-99dc0917636b",
    "name": "Player One",
    "login": "player-one"
  },
  "checkpoint": {
    "checkpointIndex": 1,
    "checkpointLapIndex": 1,
    "lapNumber": 1
  }
}
```

### `end`

Emitted when capture of the round ends. It adds `endReason` and contains no
player fields.

| Additional field | Type | Description                     | Rules                                             |
| ---------------- | ---- | ------------------------------- | ------------------------------------------------- |
| `endReason`      | enum | Reason the captured round ended | `completed`, `restarted`, `aborted`, or `unknown` |

In Trackmania Turbo, an unfinished attempt ended by elimination or by the
standard arcade end-turn button is reported as `aborted`. The end-turn button
ends the whole arcade turn, including its current unfinished attempt; it is
distinct from a per-attempt restart. Standard arcade can return directly to the
before-start state, so its postgame/final phase distinguishes the interrupted
attempt from a timer restart into preparation. Mode phase/credit updates may
lag the player reset: unknown and tentative restart transitions wait up to
250 ms for clarification. A consumed arcade credit marks an unfinished attempt
aborted. During that wait the round is retained without replaying player
observations; end duration stays at the last observed race timer. If the state
remains inconclusive, the reason is unknown. A fully captured turn can still
have `captureComplete: true` when its final attempt was aborted: completeness
describes capture coverage, not whether every attempt finished.

In Trackmania Next, a captured finish is reported as `completed` and a stable
replacement spawn is reported as `restarted`. Other exits, including quitting
the playground, fall back to `aborted`.

```json
{
  "schemaVersion": "1.1.0",
  "type": "end",
  "eventId": "b0985c12-77ac-4f81-8f69-19e89f937df1",
  "sequence": 6,
  "occurredAt": "2026-06-21T12:36:46.789Z",
  "durationMs": 110000,
  "game": {
    "gameId": "b979cde4-2ef3-49b6-9ae8-c8231ba701f2",
    "totalPlayers": 1
  },
  "source": {
    "pluginName": "TM Webhooks",
    "pluginVersion": "x.y.z",
    "game": "turbo"
  },
  "endReason": "completed"
}
```

### `score` (standard Turbo arcade)

With an endpoint configured, standard Turbo arcade emits one session-scoped score after a changed explicit UI name-submission
trigger and subsequent insertion-index clearing. It does not depend on catching
the transient ScoreWritten boolean, text stability, profile names, or matching
finish times. Timeout/default names do not change the submission trigger.

A score includes common `schemaVersion`, `type`, `eventId`, `sequence`,
`occurredAt`, and `source`, plus required `sessionId`, `turnId`,
`mode: "arcade"`, `mapUid`, `player: {name}`, `attemptIds`, and
`captureComplete`. It omits `game` and `durationMs`. No rank, time, or best
attempt is claimed while reliable leaderboard/ghost association remains unverified.

The session-scoped sequence starts at zero and increments for each captured
score in that session. Race sequences still restart for each `game.gameId`.
Receivers choose sequence scope by event type and deduplicate retries by
`eventId`. A score may arrive after the `end` events of its referenced attempts;
`end` closes only a round, not the arcade turn or local session. Delivery uses
the same HTTP headers and FIFO; retries preserve the serialized score.

The tracker ignores stale submission triggers at attachment. Consecutive turns
with identical submitted names can produce distinct scores because the trigger,
turn ID and captured attempt IDs change. Only captured attempts are listed, in
capture order. Late attachment or an unavailable lifecycle snapshot marks the
turn partial (`captureComplete: false`); no missing IDs are fabricated. A newly
verified turn boundary discards pending state from the previous turn. Retention
is limited to 256 attempt references per turn; overflow suppresses that turn's
score instead of sending a misleading truncated list.

`tests/fixtures/arcade-score.json` demonstrates a complete turn, repeated-name
partial turn, post-round submission, and separate round/session sequencing.
The unpublished schema remains `1.1.0`. Next emits no unverified equivalents.

### `player_name` (standard Turbo Hot Seat)

Contains the common `schemaVersion`, `type`, `eventId`, `sequence`,
`occurredAt`, and `source` metadata, plus required `sessionId`,
`participantId`, and nonempty `name`. It omits `game` and `durationMs`;
a name edit can be confirmed before any round exists. Emit on the first captured
explicit confirmation or a changed confirmed name. An identical already-confirmed
name, default colour label, typing, cancellation, or slot switch emits nothing.
The shared name-trigger transition and stable slot/handover counters identify
the edited participant; ambiguous transitions are skipped rather than guessed.
A stale name present when capture starts is not treated as a new confirmation.

The receiver updates that participant's display name across attempts in the
same session. Existing serialized race/score events remain immutable. Name and
score events share one session-scoped sequence starting at zero; race events
retain their separate per-game sequences and existing ordering/HTTP delivery.

### `score` (standard Turbo Hot Seat)

Contains common event metadata plus required `sessionId`, `participantId`,
`mode: "hot-seat"`, `mapUid`, `attemptId`, and
`result: {status: "finished", timeMs}`. Emit once for each captured completed
attempt when its authoritative final time is available, after its existing
immediate `finish` event. Aborted/restarted attempts emit no score. Time is not
inferred from the scoreboard or a personal best. It omits `game` and
`durationMs`, and has no arcade turn/attempt-list/completeness fields.

Optional `player: {name}` contains only the participant's explicitly confirmed
name at capture. If none was captured, omit both the name and the empty wrapper;
BLUE/RED/profile names are not substituted. A later `player_name` resolves that
participant's prior attempts. Renaming a slot preserves its participant UUID; switching back to another
slot uses that slot's original UUID without emitting another rename.

Standard Hot Seat uses `Net_NbPlayer` for its human roster and
`Net_CurPlayerIndex` for the active slot; `Net_NbPlayers` is the shared engine
count and is not the human roster. This path requires one engine racer;
unverified double-driver/multiple-racer variants are excluded. A session resets on exit, map/script/UI
replacement, observed roster selection/restart phases, roster-generation or
roster-size change. Slots persist across name edits and handovers. At most 16
participant records and one most-recent scored-attempt ID are retained; no
periodic score-table events are sent. Unsupported modes and Next keep their
existing race path without these session events.

Representative name/score and late-name examples, including the combined
sequence, are in `tests/fixtures/hotseat-events.json`. They cover the combined session sequence and stable participant references.
