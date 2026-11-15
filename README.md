<div align="center">
  <img src="assets/tm-wh.png" alt="TM Webhooks logo" width="480px">
</div>

<p align="center">
  An Openplanet plugin that emits race events from supported local modes in Trackmania Next (2020) and Trackmania Turbo.
</p>

---

The plugin sends race webhooks for `start`, `first_throttle`, `checkpoint`,
`lap`, `respawn`, `finish`, and `end`, with attempt IDs, per-round sequencing,
UTC timestamps, in-game durations, and game/source metadata. Standard
Turbo arcade capture adds confirmed-name `score` events. Standard Turbo
Hot Seat capture adds `player_name` and completed-attempt `score` events with
participant IDs and shared session sequencing. These session events omit
race-only game/duration fields. See [the webhook contract](docs/webhook-contract.md)
or [the OpenAPI description](openapi.yaml) for the complete payload model.

## Supported play

- Trackmania Next local play, campaign, and split screen
- Trackmania Turbo campaign, hot seat, arcade, split screen, and secret modes

Capture is conservative: it stays disabled unless a local playground can be
identified. Pending events share one memory-only queue across rounds. Failed deliveries retry
until a `2xx` response, independently of other events. Delivery may arrive out of
order; receivers must use `game.gameId` (race events) or `sessionId` (name/score events),
`sequence`, and `eventId` to reconstruct
and deduplicate events. Pending events are lost on plugin unload or game exit.

## Timing precision

`durationMs` uses the in-game race clock, not wall-clock or webhook delivery
time. Its precision depends on how the game exposes each event:

- `first_throttle` and `respawn` are detected by polling game state once per
  rendered frame. Their true transition happened sometime after the previous
  poll and before the current poll, so `durationMs` can be late by up to roughly
  one frame. This also applies when throttle is held through the countdown:
  Turbo may not expose the positive input until the first frame after the timer
  starts. The plugin does not subtract an estimated frame delay because the
  exact transition time is unavailable and any correction would fabricate
  precision.
- `checkpoint`, `lap`, and `finish` are not stamped with the frame in which the
  plugin notices them. The game records their authoritative race-clock times;
  the plugin reads those stored values (`CurCheckpointRaceTime`/`CurRace.Time`
  in Turbo and MLFeed checkpoint/finish times in Trackmania Next). A later
  observation can delay webhook creation and delivery, but it does not change
  these events' `durationMs`.
- `start` is defined at race-clock `0`. `end` uses the race clock when the end
  condition is observed.

## Configuration

Open **Openplanet > Settings > TM Webhooks > Webhook** and set:

- **Endpoint URL**: destination for HTTP POST requests
- **Authentication token**: optional secret sent as `Authorization: Bearer <token>`

Capture and delivery are disabled while the URL is empty. Requests use
`Content-Type: application/json; charset=utf-8` plus `event_type`, `event-id`,
and `event-sequence` headers matching the corresponding payload fields. When
the token is empty, the request is sent without authentication. The token is
masked and never logged.

## Dependencies

The plugin now ships as one package with one root `info.toml`.

For Trackmania Next, `MLHook`, `MLFeedRaceData`, and `VehicleState` must be
installed. They are declared as optional plugin dependencies so the same
package can still load in Trackmania Turbo, but the plugin intentionally probes
them during startup in Trackmania Next and fails during load if any of them are
missing.

Trackmania Turbo does not require those helper plugins.

## Build

Build the shared package on Windows:

```powershell
.\scripts\build-op.ps1 all
```

Or on a Unix-like shell:

```bash
./scripts/build-op.sh all
```

The output file is `dist/tm-webhooks.op`. The archive contains the root
`info.toml` and the shared `src` tree.

Unsigned builds require Openplanet Developer signature mode. Public
distribution requires the normal Openplanet review and signing process.

## Participant and attempt identity

`player` contains display and account metadata only. Each `start` includes
parallel `players` and `attempts` arrays joined by `playerIndex`. Subsequent
player events include the same `attempt` object:

```json
{
  "player": { "playerIndex": 0, "name": "Player One", "login": "player-one" },
  "attempt": {
    "playerIndex": 0,
    "attemptId": "57ef73e9-9407-4219-a08f-f4dd8e79c558",
    "participantId": "91852b93-8e35-4567-a049-2b7e16a04187"
  }
}
```

Every game and mode uses participant UUIDs, independent of names and accounts.
Ordinary play retains an ID while the same engine racer remains observed in the
same map/mode. Hot Seat uses verified human slots, stable through handovers and
renames. Arcade uses participants scoped to a turn. Unverified shared-racer
Turbo modes get fresh IDs per attempt. These are local identities: plugin reload,
map/mode changes and racer replacement can create new IDs, and an unobserved
controller swap cannot establish that the same human is playing.

A new run gets a new attempt ID; respawns retain it. Verified Turbo capture adds
`sessionId` and, in arcade, `turnId` to the attempt reference. Use these references
to join name/score events to races, rather than matching names or times.

## Name and score events

With an endpoint configured, standard Trackmania Turbo arcade and Hot Seat
capture entered names automatically. These events omit race-only `game` and
`durationMs` fields. Their sequence belongs to `sessionId`; race sequences belong
to `game.gameId`. Deliveries may arrive out of order; deduplicate by `eventId`.

### `player_name` — confirmed Hot Seat name

Emitted on the first captured explicit confirmation or a changed confirmed name.
Renaming preserves `participantId`. Typing, default names and controller
handovers do not emit name events. Later names can resolve earlier attempts.

```json
{
  "schemaVersion": "1.1.0",
  "type": "player_name",
  "eventId": "0b2b5412-9da6-4700-8343-c92f512ccf97",
  "sequence": 0,
  "occurredAt": "2026-11-09T19:20:00.000Z",
  "source": {
    "pluginName": "TM Webhooks",
    "pluginVersion": "1.1.0",
    "game": "turbo"
  },
  "sessionId": "0e4cb220-49d7-4c84-a42b-e4d21c212947",
  "participantId": "d2d1593a-ae5b-4fcf-9cdc-ecfd2530bce2",
  "name": "7777"
}
```

### `score` — arcade turn

Emitted after explicit name confirmation and commit, linking captured attempts
and participants in the turn. `captureComplete: false` marks partial capture;
missing attempts are never fabricated. Timeout/default names emit no score.
Unverified rank, time and best-attempt fields are omitted.

```json
{
  "schemaVersion": "1.1.0",
  "type": "score",
  "eventId": "e28f890d-eb39-4a70-8f69-ad139fe0e8f3",
  "sequence": 0,
  "occurredAt": "2026-11-09T17:43:33.750Z",
  "source": {
    "pluginName": "TM Webhooks",
    "pluginVersion": "1.1.0",
    "game": "turbo"
  },
  "sessionId": "08b71b17-dfa7-421b-895c-b28c2e55dbe3",
  "turnId": "1367e330-058b-4a5c-b816-c1ffd437d9a9",
  "mode": "arcade",
  "mapUid": "ExampleMapUid",
  "player": {
    "name": "2222"
  },
  "attemptIds": ["57ef73e9-9407-4219-a08f-f4dd8e79c558"],
  "captureComplete": true,
  "participantIds": ["35340a39-0348-405f-85ba-d6e35ea8075d"]
}
```

### `score` — Hot Seat finish

Emitted once per captured completed attempt with its authoritative final time.
Aborted/restarted attempts emit no score. `player` contains the confirmed name
when known; otherwise the whole wrapper is omitted. A rename never rewrites an
earlier event.

```json
{
  "schemaVersion": "1.1.0",
  "type": "score",
  "eventId": "908e2de4-61dc-40e5-86c4-799a9a2175b4",
  "sequence": 1,
  "occurredAt": "2026-11-09T19:20:00.000Z",
  "source": {
    "pluginName": "TM Webhooks",
    "pluginVersion": "1.1.0",
    "game": "turbo"
  },
  "sessionId": "0e4cb220-49d7-4c84-a42b-e4d21c212947",
  "participantId": "d2d1593a-ae5b-4fcf-9cdc-ecfd2530bce2",
  "mode": "hot-seat",
  "mapUid": "ExampleMapUid",
  "attemptId": "8d11a937-9e19-4382-97b7-0fcea4f1b10b",
  "result": {
    "status": "finished",
    "timeMs": 26398
  },
  "player": {
    "name": "7777"
  }
}
```

Name capture requires a verified standard Turbo mode and one local terminal;
Hot Seat also requires one shared engine racer. Secret and unverified variants
emit no name/score events. Next retains race capture and participant/attempt IDs.
A runtime name-access failure disables that capture path until plugin reload;
normal race capture continues. See [the contract](docs/webhook-contract.md).
