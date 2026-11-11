# Diagnostics harness

The harness has a standalone Bun receiver and an explicit diagnostics plugin build
for Turbo and Next. Production packages exclude the diagnostics directory, settings,
callbacks and collectors. Race webhook behavior and its FIFO remain independent.

## Build and run

```bash
bash scripts/build-op.sh all         # Production (release workflow default)
bash scripts/build-op.sh diagnostics # dist/tm-webhooks-diagnostics.op
```

```powershell
.\scripts\build-op.ps1 all
.\scripts\build-op.ps1 diagnostics
```

Install the diagnostic `.op` in Openplanet Developer signature mode. Disable the
production copy to avoid duplicate race events. Next requires the existing MLHook,
MLFeedRaceData and VehicleState dependencies; Turbo does not.

Run the receiver with Bun 1.3 or later and a dedicated random bearer token supplied
through `DIAGNOSTICS_TOKEN`. Do not commit credentials or captured game data.

```bash
bun tools/diagnostics-receiver/server.mjs
```

| Variable                | Default              | Meaning                                         |
| ----------------------- | -------------------- | ----------------------------------------------- |
| `DIAGNOSTICS_TOKEN`     | Required             | Dedicated bearer token                          |
| `DIAGNOSTICS_HOST`      | `127.0.0.1`          | Bind address; choose a LAN interface explicitly |
| `DIAGNOSTICS_PORT`      | `8787`               | Listening port                                  |
| `DIAGNOSTICS_DIRECTORY` | `./diagnostics-data` | Persistent capture directory                    |

The receiver is a separate process. This repository does not install a service or
modify the T3 stack. Use a persistent appdata directory when running on the server.
Use HTTPS outside a trusted LAN.

In **Openplanet > Settings > TM Webhooks (Diagnostics) > Diagnostics**, configure
the full endpoint ending in `/diagnostics/v1/chunks` and the dedicated token. Neither
is inherited from race webhooks. Then use **Diagnostics status > Start periodic
diagnostics**, or **Send one capture**. The interval defaults to five seconds and
is configurable from 1 to 300 seconds. It is a minimum between capture starts:
captures never overlap, and missed intervals are skipped. A long capture may take
longer than the configured interval. Periodic capture starts only by explicit action
and stops on plugin unload/restart. **Stop diagnostics** cancels collection, clears
queued packets and cancels in-flight requests. Already received data stays stored.

## Best-effort streaming (collector 1.1.0)

Each field, array element, coverage issue and reflection member is serialized into
its own small record and queued immediately. There is no whole-dump JSON batch,
local dump spool, second parse/serialization pass, or acknowledgement wait in the
collection coroutine. A yield follows each record serialization. This removes the
large `Flush()` operation that exceeded Turbo's one-second script execution limit.
It does not guarantee that an individual native getter or serializer cannot block.

An independent worker starts up to four HTTP requests concurrently. It retains
handles until completion or five-second expiry; it never retries, parses response
bodies, or gates capture on server success. The queue holds at most 64 packets.
Overflow, oversized records and failures are dropped. Status reports requests
started, failed requests and locally dropped packets; **finished collection does
not mean successful delivery**. A record is capped at 24 KiB before envelope
construction, and the receiver caps stream packets at 32 KiB. Maximum capture data
is 16 MiB and 32767 attempted records plus a final manifest. The manifest reports
attempted and locally dropped records; missing indices reveal delivery gaps.

Older `diagnostics-pending.json` files are no longer read, replayed or deleted by
this version. They can be archived or removed manually. There is no retry control.

## Capture scope and freezes

**Read native game values (experimental)** defaults off while runtime behavior is
being investigated. A metadata-only capture streams root reflection metadata;
it is not a game-state value snapshot. Enable native values explicitly after that
baseline succeeds. Native reads traverse live objects reachable from `GetApp()`
with generated typed readers for both games. The seven setter-only properties
identified by Turbo 1.29.14 are excluded, as are members with explicit
`readable: false` metadata. Public type pages do not reliably expose accessor flags.

**Include static API catalogue** defaults off to avoid resending constant metadata
on every periodic capture. If enabled, the packaged catalogue streams separate
class, member and method-signature records, within the same time/size limits. Method
signatures are metadata; arbitrary game methods are never invoked. Next helper
objects are not CMwNod instances: the native-values mode emits the MLFeed player/
race fields and VehicleState throttle already used by the plugin, not a full dump
of helper plugin internals.

**Write last-operation breadcrumb** now defaults off to avoid synchronous disk
writes during normal periodic capture. Enable it for hang investigation. It flushes
`diagnostics-last-operation.json` in the plugin storage folder before getters and
major stages, containing names/counters rather than values or credentials. Recover
that file after a hang. An interrupted write can leave an incomplete file. Write
failure disables tracing and emits a warning.

Captures span frames. Object summaries identify the dump-local ID, first traversal
path, runtime type, observation timestamp and coverage counts. Field/array packets
reference object IDs; shared objects/cycles use `ref` values. Reflection members and
coverage issues are separate records. Unavailable types, getter exceptions,
privacy exclusions, truncation and cancellation are explicit. Non-finite numbers
and 64-bit integers are strings; vectors/matrices use textual component values.

Defaults: 4096 objects, depth 12, 128 array elements, 512 string bytes, 30 seconds.
Settings allow bounded increases. Checkpoints also yield every 32 operations or
approximately 2 ms, including array loops, reference scans and reflection metadata.
Playground changes terminate native traversal. Getter calls themselves cannot be
preempted; native capture can still stall or crash the game.

Credentials, tokens, logins, accounts, profiles, authors, messages, paths, URLs and
similar sensitive member names are excluded before reading. This is not a guarantee
that free-text game values contain no private data. Dumps can still contain names,
map content, UI strings and IDs; inspect before sharing. Plugin settings and request
secrets are never collected. Tokens and response bodies are not logged.

## Receiver protocol and inspection

`GET /health` returns `{"status":"ok","schemaVersions":["1.0.0","1.1.0"]}`. Authenticated JSON POSTs use the existing
`/diagnostics/v1/chunks` endpoint. The receiver supports old schema `1.0.0` chunk
uploads for compatibility and new `1.1.0` best-effort streaming packets:

```json
{
  "schemaVersion": "1.1.0",
  "captureId": "c211b7cd-f6a1-4f60-9000-2debd9484a00",
  "game": "turbo",
  "index": 0,
  "kind": "record",
  "data": { "kind": "field", "objectId": 0, "member": "Speed", "value": 42 }
}
```

Stream packets have no `total`. Indices increase for every attempted record,
including locally dropped ones. A final `kind: manifest` packet's index defines the
record count and carries probe status/timestamps, capture mode and coverage.
Out-of-order packets and exact duplicates are accepted. Conflicting content/game/
protocol/final indices return 409. Acknowledgements contain `complete: false` and
`missing: null` until the final index is known. The sender does not consume them.
If every index through the manifest is present, the receiver writes `complete.json`;
otherwise the capture remains incomplete. Lost manifests stay explicitly incomplete
with unknown total, even after restart. Missing data is never silently repaired.

Each capture stores `capture.json`, numbered packet files and (only after all
packets arrive) `complete.json`. The CLI exposes already received records even
without a manifest. A receiver-complete stream may contain a probe that was
truncated or failed; inspect both delivery completion and manifest status.

```bash
bun tools/diagnostics-receiver/inspect.mjs list ./diagnostics-data
bun tools/diagnostics-receiver/inspect.mjs show ./diagnostics-data <capture-uuid>
bun tools/diagnostics-receiver/inspect.mjs diff ./diagnostics-data <before-uuid> <after-uuid>
```

The comparison is raw record data keyed by traversal path/member/object/index;
it is not a semantic game-state diff. IDs may change between captures.

Receiver limits: 32 KiB per stream packet (1 MiB for legacy chunks), 32768 packets
per stream (1024 legacy chunks), 32 MiB per stored capture including reserved
metadata space, 512 MiB per store. Incomplete captures expire after one day,
completed captures after seven days. Retention runs on uploads and hourly. One
receiver process must own the storage directory. Writes are flushed then renamed;
power-loss durability depends on the filesystem. Storage/validation errors return
4xx/5xx; best-effort senders drop failures without retrying. Receiver library options
can override storage/retention limits for embedding or tests.

## Regeneration and validation

```bash
python3 scripts/generate-diagnostics.py            # Offline generation
python3 scripts/generate-diagnostics.py --refresh  # Refresh official references
python3 scripts/generate-diagnostics.py --refresh --game next
bun test tests/diagnostics-receiver.test.mjs
python3 tests/diagnostics-generation.py
node tests/validate-fixtures.mjs
npx prettier -w .
```

References: [Turbo](https://turbo.openplanet.dev/),
[Next](https://next.openplanet.dev/),
[reflection](https://openplanet.dev/docs/api/Reflection),
[build defines](https://openplanet.dev/docs/reference/info-toml).

Local tests exercise legacy/stream protocol validation, real HTTP ingestion, CLI
inspection, out-of-order delivery, gaps, lost manifests, restart, quotas, retention,
generation and production isolation. These do not prove native compilation, frame
cost, network behavior inside Openplanet or Windows packaging. Turbo loaded the
previous getter-fix build; the streaming rewrite needs real Turbo and Next retests.
