<div align="center">
  <img src="assets/tm-wh.png" alt="TM Webhooks logo" width="480px">
</div>

<p align="center">
  An Openplanet plugin that emits ordered race events from supported local modes in Trackmania Next (2020) and Trackmania Turbo.
</p>

---

The plugin sends a separate webhook for `start`, `first_throttle`,
`checkpoint`, `lap`, `respawn`, `finish`, and `end`. Every event carries a UUID,
an in-round sequence number, an RFC 3339 UTC timestamp, the in-game duration,
and stable game/source metadata. See [the webhook contract](docs/webhook-contract.md)
or [the OpenAPI description](openapi.yaml) for the complete payload model.

## Supported play

- Trackmania Next local play, campaign, and split screen
- Trackmania Turbo campaign, hot seat, arcade, split screen, and secret modes

Capture is conservative: it stays disabled unless a local playground can be
identified. Pending events share one memory-only FIFO across rounds.

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
- **Maximum retry count**: retries after the initial attempt, from 0 to 10

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

## Local test receiver

Requires Node.js 22 or newer; no packages to install. From this repository:

```bash
node scripts/webhook-receiver.mjs --host 0.0.0.0 --port 8787
```

Set the plugin's **Endpoint URL** to
`http://<receiver-LAN-IP>:8787/api/webhook` (on Svetlana: `http://10.0.1.2:8787/api/webhook`).
For authenticated POSTs, start with `--token-file /path/to/token` and put the
same token in the plugin's **Authentication token** setting. Keep the token file
outside version control (for example, `.local/webhook-receiver/token`). An
explicit token file must contain a nonempty token; missing or incorrect bearer
credentials receive `401` and are not saved. With no token file, leave the
plugin token empty. Authentication applies to webhook POSTs; health and recent
event reads remain available without credentials. Bind to `127.0.0.1` (the default) for local-only tests,
or `0.0.0.0` for LAN testing. It is a development capture tool, not a production
receiver, and does not enforce the webhook schema.

Each delivery prints its full payload and appends a record containing
`receivedAt`, the three event headers, and `payload` to a new per-run JSONL file
in `.local/webhook-receiver/`. This directory is gitignored. Authorization
headers are never saved. Retries are retained as separate deliveries with their
original event IDs. Old session files are preserved across restarts. Override
the storage location with `--data-dir /persistent/path`.

- `GET /health`: status, count received during this run, and session file path.
- `GET /events`: latest 100 deliveries from this run as JSON.
- `POST /api/webhook`: saves a JSON object and returns `204`; malformed bodies return
  `400`, bodies larger than 1 MiB return `413`, and save failures return `503`.

Stop with **Ctrl+C**; rerun the command for a later session. To keep it running
in the background on a Unix-like system:

```bash
mkdir -p .local/webhook-receiver
nohup node scripts/webhook-receiver.mjs --host 0.0.0.0 --port 8787 > .local/webhook-receiver/receiver.log 2>&1 &
echo $! > .local/webhook-receiver/receiver.pid
tail -f .local/webhook-receiver/receiver.log
```

Stop that background process before starting another on the same port:

```bash
kill "$(cat .local/webhook-receiver/receiver.pid)"
```

### Turbo name-entry diagnostic test (development build 1.0.2)

The optional probe investigates #27. It does **not** turn observations into
`score` or `player_name` webhooks. Next keeps its existing race capture and does
not compile or run this Turbo-only probe.

1. Build/install the latest shared plugin (`./scripts/build-op.sh all`), or use
   `dist/tm-webhooks.op`. Reload it in Turbo with Developer signature mode.
   If compilation fails, report the exact Openplanet error and line before testing.
2. Keep the normal endpoint `/api/webhook`. In **Settings > TM Webhooks > Name
   diagnostics**, set **Diagnostic URL** to
   `http://10.0.1.2:8787/api/diagnostics`, then enable **Enable name-entry probe**.
   The probe uses the existing webhook authentication token. Raw UI variable
   dumps may contain profile and leaderboard data; send only to your test receiver.
3. Start before entering arcade. Play one complete three-attempt turn. At name
   entry, type `OLE`, wait two seconds without confirming, then confirm. Leave
   the leaderboard visible for five seconds. Note which row is blank and which
   displays `OLE`. Run another turn using the same name. If possible, let a
   subsequent name editor time out without confirmation.
4. In a separate hot-seat test, start the probe before entering the mode. Confirm
   a name for one participant, switch slots, rename the other, and switch back.
   Report the order of actions. Stop the probe when finished.

The probe samples at most four times per second for up to ten minutes and sends
only changed snapshots. It retains at most 32 pending samples and reports drops
and sequence gaps; diagnostic deliveries are best-effort with a five-second
request timeout. Slow receivers and transitions between samples can lose
observations, so this is evidence gathering, not verified name-event capture.
It stays active outside races, including name-entry and results screens. Raw
variable dumps are capped at 16 KiB each with explicit truncation markers.
Normal race event payloads and delivery are unchanged. A runtime probe exception
disables the probe so race capture can continue.

The receiver accepts authenticated `POST /api/diagnostics`, saves these records
in a separate `*.diagnostics.jsonl` file, and exposes its latest ten diagnostic
records through `GET /diagnostics`. `GET /health` reports both counts and paths.
Race event captures remain in the original JSONL file. Raw diagnostics are not
printed to the receiver console. Test its HTTP behavior with
`node --test tests/webhook-receiver.test.mjs`.

The public score cross-check follows the
[TurboCup reader](https://github.com/chrizonix/OpenPlanet-Plugins/blob/master/Scripts/Plugin_TurboCup.as):
`PlayerInfos[].RaceScore.BestTime` / `LastRaceTime` plus the network player name.
Its [companion recorder](https://github.com/chrizonix/TrackMania-Turbo-Recorder)
consumes these polled records; neither establishes explicit arcade name
confirmation. The probe additionally tests the documented
[`Dbg_DumpDeclareForVariables`](https://turbo.openplanet.dev/Game/CGamePlaygroundScript)
binding on shared/local UI, rules, and matching local name-entry pages. The dump
format and visibility of `LibTMC_ScoresTable_ScoreWritten`, entered names, and
hot-seat slot variables must be verified from your run before production parsing.

Probe version 2 (plugin 1.0.2) additionally records visible score/name layer
metadata and bounded label text, preserving empty labels and their control
paths. It checks the compiled page's ScriptText as well as ManialinkPageUtf8
when selecting name-entry pages. The 1.0.1 arcade test verified access to
`LibTMC_ScoresTable_NewName = "1111"` and a changed new-name trigger after
submission. The score-written boolean had already reset between samples, and
leaderboard arrays appeared as `[???]`, so neither the boolean alone nor the
array dump is sufficient for complete result capture. The new label probe tests
whether the displayed blank/name/time rows can supply the missing association;
it does not infer a row from time or display order. Label scans are capped at
32 layers, depth 8, 512 controls, and 96 labels (160 bytes of text each), with
visibility, truncation, and scan-limit flags. For this next test, reload the new
plugin, re-enable the probe, show the leaderboard containing `1111` and the
blank row for five seconds, then submit another name and leave the resulting
leaderboard visible for five seconds.

### Experimental arcade scores (development build 1.0.3)

The 1.0.1/1.0.2 tests read `1111` and `2222` from the explicit name-trigger
transition. `ScoreWritten` was already false in those samples. The displayed
leaderboard arrays remain opaque and the inspected server layers' `LocalPage`
handles were null, so the implementation does not claim rank/time/best-attempt
association. These fields are optional in issue #27.

Version 1.0.3 adds an opt-in **Webhook > Capture arcade scores (experimental)**
setting. In standard Turbo arcade with one local terminal, it assigns session
and turn context to newly captured attempts, retains their IDs across race end,
and sends a `score` to the regular `/api/webhook` after a changed submission
trigger and observed insertion-index clearing. The score name is the entered
name, not the engine profile name. Names are parsed only from the verified
scalar dump shape; malformed or unavailable state invalidates association.
The unchanged diagnostic probe is optional and helps inspect test failures.

Build/reload 1.0.3, then test with the existing URL and token:

1. Enable **Capture arcade scores (experimental)** before entering arcade or
   while on its idle leaderboard. Start a new turn, play its attempts, submit
   `3333`, and leave the leaderboard visible. Expect one `score` after the race
   events, with `player.name: "3333"` and only that turn's captured attempt IDs.
2. Play another turn with the **same name**. Expect a different `turnId`, fresh
   attempt IDs, and the next session-scoped score sequence. No extra score
   should appear while the leaderboard remains visible.
3. In a separate turn, let name entry time out. Expect no score for the default
   name. Restart an attempt and use a checkpoint respawn in another turn: the
   restart should allocate a new attempt ID, while the respawn keeps its ID.
4. Enable capture or reload mid-turn. A resulting score must be partial, with
   `captureComplete: false`; never three fabricated IDs. Test leaving/re-entering
   arcade and changing maps to check session reset behavior.

If the UI dump call fails at runtime, arcade score capture disables itself and
logs an `[arcade]` warning; normal race capture continues. This is still a draft
implementation requiring live session/turn-boundary validation. Hot-seat,
secret variants, and Next equivalents remain disabled until verified.

Development build 1.0.4 corrects an end-reason defect found in the `4444` live
test: two finished attempts and the final give-up were all correctly included
in a single complete score, but the final round was labelled `restarted`.
Standard arcade can return directly to BeforeStart on give-up. Its observed
postgame/final phase now marks that unfinished round `aborted`, while timer
restart behavior remains unchanged. Existing explicit aborted state is retained.
Rebuild/reload and repeat a last-attempt give-up to validate that end reason;
score completeness should remain true when all attempts were captured, even
though one was aborted. No retroactive changes are made to saved captures.
