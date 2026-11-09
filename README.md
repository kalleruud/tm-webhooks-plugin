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
