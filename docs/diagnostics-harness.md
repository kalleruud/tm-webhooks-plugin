# Diagnostics harness

The harness records what Trackmania Turbo and Trackmania Next expose during a run,
so agents can choose reliable race APIs and test the plugin's interpretations
against real driving. It consists of a separate diagnostics plugin build and a
standalone Bun receiver. It is intended for local testing and investigation:
the receiver has no authentication. Production packages exclude the diagnostics
directory, its settings and its per-frame hook. Race webhook behavior and its
FIFO remain independent.

## Quick start

```bash
bash scripts/build-op.sh diagnostics   # dist/tm-webhooks-diagnostics.op
bun tools/diagnostics-receiver/server.mjs
```

```powershell
.\scripts\build-op.ps1 diagnostics
```

1. Install `tm-webhooks-diagnostics.op` in Openplanet Developer signature mode and
   disable the production copy to avoid duplicate race events. Next requires the
   existing MLHook, MLFeedRaceData and VehicleState dependencies; Turbo does not.
2. In **Openplanet > Settings > TM Webhooks (Diagnostics) > Diagnostics**, set
   **Receiver URL** (default `http://127.0.0.1:8787/diagnostics/v1/chunks`) and
   enable **Record runs**.
3. Play. Disable **Record runs** to finish the recording.
4. Inspect the recording with `inspect.mjs` (see below).

The **Diagnostics status** tab shows the build version, recording progress,
requests started/failed, local drops, queue depth and the last HTTP status.

## Recording

While **Record runs** is enabled and the URL is valid, the plugin records
continuously. Each recording has one capture ID. Disabling ends it with a
`run-recording-end` record and a manifest; queued packets still drain. Long
sessions roll over into a new recording every 15 minutes, or earlier at 32767
attempted records or 16 MiB of payload. The next recording starts one second
later while the setting stays enabled.

Players are sampled every **100 ms**. Each sample retains its actual observation
time, monotonic recording elapsed time, sample sequence, player ID, map UID,
source start token and API provenance. Samples never pretend that all players
were read at one instant. Player IDs combine source user identity and roster
slot; `userKey` allows correlation if roster order changes and avoids conflating
split-screen users who share an account. Attempt tokens are source evidence, not
an asserted restart.

| Evidence       | Turbo                                                                               | Next                                                                                   |
| -------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Inputs         | `CTrackManiaPlayer.InputGasPedal/InputIsBraking/InputSteer`                         | `CSmScriptPlayer` equivalents                                                          |
| Speed/position | `CTrackManiaPlayer.Speed/DisplaySpeed/Position`                                     | `CSmScriptPlayer.Speed/DisplaySpeed/Position/Velocity`                                 |
| Car state      | Gear, RPM, turbo ratio, contacts, skidding/flying, distance, damage ratios          | Gear, RPM, turbo ratio, contacts, skidding/flying, distance, entity availability       |
| Race           | RaceState, RaceStartTime, CurRace checkpoints/time, laps, respawns, continuous rank | Native script race fields plus MLFeed clock/checkpoints/laps/respawns/finish           |
| Scores/names   | RaceRules.Scores, falling back to player.Score                                      | ArenaRules.Scores, falling back to player.Score                                        |
| Native events  | StartLine, WayPoint, Respawn, GiveUp, Stunt                                         | Waypoint/respawn request, vehicle collisions and stunts where PendingEvents is exposed |

Map name/UID/author/environment/medal targets, raw mode identifiers, inferred mode,
UI phase, player count/local terminal count, player names/logins/user IDs/language/
ladder details and car model are checked about once per second. Context and
leaderboard snapshots are emitted when changed and at least once every five
seconds. Leaderboard array order is not assumed to be finishing rank: list indices,
rank sort values, points and native best/previous times are kept separately. These
are the game's exposed score rows, not a fetched global online leaderboard.

Samples intentionally include player and leaderboard names and user details;
credentials, tokens, unrelated chat and profile resources are not collected. Up to
16 playground players, 32 score rows, 256 checkpoint times and eight per-score Next
race times are retained per snapshot. Source counts/truncation flags identify caps.
Unexposed values are omitted rather than replaced with zero. Turbo's raw state
and result time remain available; inactive cars with a default Finished enum and
result -1 are not treated as valid finishes or active racing. Mismatched Next
checkpoint-count/history sources are marked so analysis will not pair wrong times.

Native race events are polled each recorder loop and deduplicated by a bounded
set of event handles, without consuming or modifying the queue. They may be
missed if the mode consumes them before observation. Native getters can still
block; this is focused recording, not a guarantee of safe access in every mode.

## Delivery

Each record is serialized individually and queued immediately; collection never
waits for the receiver. A diagnostics-only per-frame hook starts at most one HTTP
request and checks at most one pending request each frame, with up to four
requests in flight and a five-second expiry. There are no retries. The queue
holds at most 64 packets; overflow, records over 24 KiB and failed requests are
dropped and counted. The manifest reports attempted and locally dropped records,
and missing indices on the receiver reveal delivery gaps. **A finished recording
does not mean successful delivery.**

### Reconstruct the timeline

```bash
bun tools/diagnostics-receiver/inspect.mjs timeline ./diagnostics-data <recording-uuid> > run-timeline.json
```

The timeline includes player/attempt observations, map/mode and leaderboard
snapshots, native events, and field-by-field timestamped series with per-point API
sources. If a field switches between native and feed APIs, the series is marked
as mixed and retains every source rather than assigning all points to the first.
Sample differences infer start, checkpoint, lap, respawn, finish, throttle and brake
transitions. Their observation windows are retained; authoritative checkpoint and
finish times are used when available. Starting mid-run never fabricates a start
transition. Large sampling gaps are flagged, and delivery completion/missing packet
indices remain distinct from probe status.

Speed differences provide `derived.speedChangePerSecond` in **native speed units
per second**, not an assumed m/s². Damage increases or a sharp speed drop with braking explicitly false at both
observations
may produce `impact_candidate`; respawns, attempt changes and large gaps suppress
that inference. It is not proof of a collision or a wall target. Next's native
vehicle-collision records are labelled separately, without inventing what was hit.
Turbo's inspected race-event API has no dedicated wall-contact event. Raw evidence
is retained so these API interpretations can be tested against your driving.

## Receiver

Run the receiver with Bun 1.3 or later.

| Variable                | Default              | Meaning                                         |
| ----------------------- | -------------------- | ----------------------------------------------- |
| `DIAGNOSTICS_HOST`      | `127.0.0.1`          | Bind address; choose a LAN interface explicitly |
| `DIAGNOSTICS_PORT`      | `8787`               | Listening port                                  |
| `DIAGNOSTICS_DIRECTORY` | `./diagnostics-data` | Persistent capture directory                    |

The receiver is unauthenticated. Keep it on loopback or a trusted LAN; it warns
when bound to another address. When the game runs on a different machine, bind
the receiver to a LAN interface and point **Receiver URL** at it. This
repository does not install a service. Do not commit captured game data.

The receiver protocol is specified in
[tools/diagnostics-receiver/openapi.yaml](../tools/diagnostics-receiver/openapi.yaml),
separately from the race webhook contract.

`GET /health` returns `{"status":"ok","schemaVersions":["1.1.0"]}`. JSON POSTs to
`/diagnostics/v1/chunks` carry one stream packet:

```json
{
  "schemaVersion": "1.1.0",
  "captureId": "c211b7cd-f6a1-4f60-9000-2debd9484a00",
  "game": "turbo",
  "index": 0,
  "kind": "record",
  "data": { "kind": "run-recording-start", "recordSequence": 0 }
}
```

Stream packets have no `total`. Indices increase for every attempted record,
including locally dropped ones. A final `kind: manifest` packet's index defines the
record count and carries status, timestamps and drop counts. Out-of-order packets
and exact duplicates are accepted. Conflicting content, game or final indices
return 409. Acknowledgements contain `missing: null` until the final index is
known; the sender ignores them. When every index through the manifest is present,
the receiver writes `complete.json`; otherwise the capture remains incomplete.
Missing data is never silently repaired.

Each capture stores `capture.json`, numbered packet files and (only after all
packets arrive) `complete.json`.

```bash
bun tools/diagnostics-receiver/inspect.mjs list ./diagnostics-data
bun tools/diagnostics-receiver/inspect.mjs show ./diagnostics-data <capture-uuid>
bun tools/diagnostics-receiver/inspect.mjs timeline ./diagnostics-data <capture-uuid>
```

Receiver limits: 32 KiB per packet, 32768 packets and 32 MiB per capture, 512 MiB
per store. Incomplete captures expire after one day, completed captures after
seven days. Retention runs on uploads and hourly. One receiver process must own
the storage directory. Writes are flushed then renamed.

## Validation

```bash
bun test tests/diagnostics-receiver.test.mjs tests/diagnostics-timeline.test.mjs
python3 tests/diagnostics-recorder.py
python3 scripts/refresh-openplanet-api.py   # Refresh API inventories
```

`tests/diagnostics-recorder.py` checks every member the recorder reads against
the Openplanet API inventories in `tests/fixtures/openplanet-api`, and checks that
production archives contain no diagnostics code. These tests do not prove native
compilation, frame cost or network behavior inside Openplanet; that requires an
in-game run in both games.

References: [Turbo](https://turbo.openplanet.dev/),
[Next](https://next.openplanet.dev/),
[build defines](https://openplanet.dev/docs/reference/info-toml).
