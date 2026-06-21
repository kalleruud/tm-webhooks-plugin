# Trackmania Webhook Plugin

The plugin sends ordered webhooks when race events occur in supported local
Trackmania modes. The detailed webhook payload model is defined in
[`contract.md`](contract.md) and must remain synchronized with `openapi.yaml`.

## Glossary

- **Game**: A complete race activity where one or more people race. In the
  supported scope, a game contains exactly one round and receives a new unique
  game ID when that round begins. Multi-round correlation is out of scope.
- **Round**: One continuous in-game timing session, from its single `start`
  event through its single final `end` event. Stopping or restarting the timer
  ends the round. A new timer session is a new round and game.
- **Player index**: The required zero-based identity for a player within one
  game. Platform account identifiers are optional metadata.

In Trackmania Turbo hot seat, each player's continuously timed attempt is a
separate round and game. The full configured roster is retained, while
player-scoped events include a full snapshot of the active player.

## Supported Games and Modes

Every feature must work in both Trackmania Turbo and Trackmania Next (2020).
Trackmania Next requires the `MLHook`, `MLFeedRaceData`, and `VehicleState`
helper plugins. The shared package declares them as optional dependencies so
Turbo can still load, then explicitly fails during startup in TMNEXT if they
are missing.

Only local play is supported:

- Trackmania Next local play and campaign
- Trackmania Next split screen in any mode
- Trackmania Turbo campaign, hot seat, arcade, and split screen
- Trackmania Turbo secret modes

Capture is disabled unless the plugin can positively identify a local mode. An
unknown mode may still be captured when it is demonstrably local; unavailable
mode metadata is omitted.

## Architecture

- Use the clean-code skill during implementation and review.
- Put deep implementations behind small service interfaces in `src/services`.
- Keep game-specific detection in separate Turbo and Next adapters that produce
  the same internal event model.
- Keep `src/Main.as` as a thin orchestration layer.
- Keep shared webhook schemas and delivery behavior identical across games.
- Use preprocessor guards only at game-specific integration boundaries.

Recommended service boundaries are game detection, round tracking, event
creation, timestamp creation, serialization, and FIFO delivery. Services must
not expose game API details across those boundaries.

## Configuration

The Openplanet settings are:

- Endpoint URL
- Maximum retry count, default `3`, minimum `0`, maximum `10`

Capture and delivery are disabled while the endpoint URL is empty. No URL
validation is performed; the configured endpoint is trusted with short-lived
Openplanet identity tokens. Settings take effect immediately, including during
a round. Enabling capture mid-round may therefore produce a partial game
without a `start` event.

Changing the URL does not clear the queue or cancel an event. Every attempt,
including retries of previously queued events, uses the current URL and obtains
a fresh identity token with `Auth::GetToken()`. Authentication failure must
never result in an unauthenticated request; it consumes an attempt and follows
the normal retry delay and exhaustion rules. Tokens must never be logged.

## Time

`occurredAt` is created with Openplanet's built-in time APIs in both games:

- `Time::Stamp` supplies Unix epoch seconds.
- `Time::FormatStringUTC` formats UTC rather than local time.
- `Time::Now` retains millisecond resolution between events.

Do not use local-time formatting, an IANA timezone setting, or an external time
API. Automated timestamp behavior must be verified for both game builds.

`durationMs` always follows the in-game race timer, including its pause
behavior. Delivery delay never affects event timestamps or durations.

## Round Lifecycle

- Emit one `start` at timer `0`, after the countdown and before player events.
- Freeze the player roster and `game.totalPlayers` when `start` is created.
- Emit `first_throttle` at most once per player per game. Never re-arm it after
  laps or respawns.
- Trigger first throttle on the first accelerator value strictly greater than
  zero after the round begins.
- Emit checkpoint events only on actual validation transitions, suppressing
  duplicate observations across frames.
- Normalize `checkpointLapIndex` across modes: intermediate checkpoints are
  `1..checkpointsPerLap`, lap events use `0` for the newly started lap, and
  finish events use `checkpointsPerLap + 1` for the completed final lap.
- Emit one respawn event for every detected respawn action, including repeated
  respawns at the same destination.
- A start-line respawn remains a respawn while the timer continues. It does not
  create a new game or another start event.
- On the final crossing, emit `finish`, not `lap`.
- Emit at most one `finish` per player. Some modes only allow the winner to
  finish, so other players may have no finish event.
- When finish and end are observed together, enqueue every finish before end.
- Emit exactly one `end` as the last event of a detected round.
- A normal mode-declared conclusion is `completed`, including winner-only
  split-screen conclusions. Leaving the map or returning to a menu is
  `aborted`. A timer restart is `restarted`. Use `unknown` instead of guessing.
- On game or plugin process termination, end delivery is best-effort and not
  guaranteed.

When multiple events occur in one frame, order them by event priority and then
by ascending player index. Priority is: `start`, `first_throttle`, `checkpoint`,
`lap`, `respawn`, `finish`, `end`.

## Delivery

Use one process-wide FIFO with at most one HTTP request in flight. Events from a
new game are appended after pending events from earlier games. Changing game ID
or settings does not clear the queue.

The queue is memory-only and has a fixed capacity of 1,000 events. Plugin or
game shutdown discards pending events. When full, retain the queued prefix and
drop newly occurring events. Log every overflow with the event ID.

Delivery rules:

- Send JSON with `POST`, `Content-Type: application/json; charset=utf-8`,
  `event_type: <type>`, `event-id: <eventId>`, and
  `event-sequence: <sequence>`. Event headers match the payload and remain
  unchanged across retries. Include the freshly acquired Openplanet identity
  token as `Authorization: Bearer <token>` on every request.
- Use a fixed 10-second request timeout. A timeout is a retryable network error.
- Treat any `2xx` response as success and ignore its response body.
- Retry network errors, `408`, `429`, and `5xx` responses.
- Honor `Retry-After` as either integer seconds or an HTTP date, with no local
  cap. If absent, wait `currentRetryAttempt * 5` seconds with no jitter.
- Retry counts exclude the initial request. Read the current configured maximum
  before each retry.
- Drop other `4xx` and all `3xx` responses as permanent failures. Do not follow
  redirects.
- After a permanent failure or retry exhaustion, log the event ID, attempt
  count, status, and a bounded response-body excerpt, with credentials redacted,
  then advance the FIFO.

Retries reuse the immutable serialized event, including its ID, sequence,
schema version, timestamp, and duration. They use the current endpoint and a
new Openplanet identity token.

## Contract

`contract.md` is the human-readable webhook model. `openapi.yaml` is the
machine-readable source for generated endpoint types. They must be updated in
the same change whenever payloads, authentication, response codes, or headers
change.

The initial schema version is `1.0.0` and follows SemVer:

- MAJOR: removed or renamed fields, changed meanings or types, or removed event
  variants
- MINOR: new optional fields or event variants
- PATCH: documentation or OpenAPI corrections that do not change accepted JSON

Schema version and plugin version are independent.

## Build and Release

- The repository has one root `info.toml` for both supported games.
- `scripts/build-op.sh` and `scripts/build-op.ps1` build one shared artifact.
- The artifact name is `tm-webhooks.op`.
- One repository version source is reported as `source.pluginVersion`.
- `.github/workflows/publish.yml` uses the build scripts and publishes the
  shared plugin artifact on merge into `main`.

Package the root `info.toml` and `src` contents, not the repository directory
itself.
Unsigned development builds require Openplanet Developer signature mode;
distributed builds require the normal Openplanet review/signing process.

## Automated Verification

CI must:

- Validate `openapi.yaml`.
- Verify representative JSON fixtures against every event schema.
- Build the shared plugin artifact.
- Run shared service tests against both game adapters where practical.
