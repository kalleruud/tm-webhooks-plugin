# Diagnostics harness

The harness has a standalone Bun receiver and an opt-in diagnostics plugin build
for **both Turbo and Next**. Normal release packages contain no diagnostics files,
settings, menu callbacks, collectors, or defines. The existing race webhook
contract and FIFO are independent of diagnostics.

## Build and run

```bash
# Default release package, unchanged release-workflow entry point
bash scripts/build-op.sh all
# Explicit diagnostic package
bash scripts/build-op.sh diagnostics
# Equivalent explicit profile
bash scripts/build-op.sh all dist diagnostics
```

On Windows:

```powershell
.\scripts\build-op.ps1 all
.\scripts\build-op.ps1 diagnostics
# Or: .\scripts\build-op.ps1 all -Profile diagnostics
```

Install `dist/tm-webhooks-diagnostics.op` in Openplanet Developer signature mode.
Disable the production copy while testing to avoid two plugins sending race events.
The diagnostic package has a distinct name and no public site ID. Next still needs
the existing MLHook, MLFeedRaceData, and VehicleState dependencies; Turbo does not.

Run the receiver with Bun 1.3 or later. Supply a dedicated random bearer token in
`DIAGNOSTICS_TOKEN` through your shell/environment's secret mechanism. The service
refuses to start without it. Never commit the token or capture files.

```bash
bun tools/diagnostics-receiver/server.mjs
```

| Environment variable    | Default              | Meaning                                     |
| ----------------------- | -------------------- | ------------------------------------------- |
| `DIAGNOSTICS_TOKEN`     | Required             | Dedicated bearer token                      |
| `DIAGNOSTICS_HOST`      | `127.0.0.1`          | Bind address; set explicitly for LAN access |
| `DIAGNOSTICS_PORT`      | `8787`               | Receiver port                               |
| `DIAGNOSTICS_DIRECTORY` | `./diagnostics-data` | Persistent capture directory                |

The receiver is a separate process; the plugin does not start it. Nothing in this
change installs a service or alters the running T3 stack. If you choose to run it
on the server, choose a persistent directory under your appdata and bind to a LAN
interface deliberately. For a different machine, use its reachable hostname/IP
in the plugin. Use HTTPS when traffic leaves a trusted local network.

In **Openplanet > Settings > TM Webhooks (Diagnostics) > Diagnostics**, set the
full diagnostics endpoint (for example
`http://127.0.0.1:8787/diagnostics/v1/chunks`) and its dedicated token. These settings
never inherit or fall back to the race webhook URL/token. Empty URL or token
prevents upload; local capture still works.

Use **Diagnostics status > Capture diagnostics dump and upload**, or the plugin menu
entry. Status shows capture and upload progress. Cancel interrupts at the next
yield. A cancelled capture is saved with a partial manifest and can be uploaded
with Retry. A failed upload retains the pending dump; Retry replays identical
chunks safely. No captures run automatically on startup or on every frame.

### First capture after a freeze

Native game getters can block the game thread; script cancellation and try/catch
cannot interrupt a blocked native call. **Read native game values (experimental)**
therefore defaults to off. First run a **metadata-only** capture: this sends the
root's reflection metadata and packaged API definitions, without invoking the
generated game-value readers or helper summaries. Its manifest says
`captureMode: metadata-only`; it is not a complete game-state snapshot.

Keep **Write last-operation breadcrumb** enabled while diagnosing. Before native
reads and major capture/upload stages, the probe writes and flushes
`diagnostics-last-operation.json` in this plugin's storage folder. It contains
phase/member names and counters, not captured values or tokens. If the game hangs,
recover that file after restarting and share it to identify the last operation.
A crash during a breadcrumb write can leave the file incomplete. Trace-write
failure disables tracing and emits a warning. Tracing adds disk overhead.

Only after a metadata capture succeeds should native-value reads be explicitly
enabled for investigation. Retain small object/depth/array limits during that
step. `captureMode: native-values` identifies these captures; enabling them is
still experimental and can reproduce a blocking getter.

Only one pending capture is retained in plugin storage as
`diagnostics-pending.json`. Upload success deletes it. Retry or explicitly delete
it before taking another capture; captures are never silently overwritten.
A `.tmp` file may remain if the game exits during spool writing; only a completed
spool file is eligible for Retry. Neither endpoint nor token is persisted there.

## What a full dump means

The generator follows documented object-reference types, base classes, and their
derived classes from `CTrackMania`. It emits typed property reads and bounded
array traversal, never arbitrary method calls, constructors for game objects,
or memory-offset reads. Properties with readable accessors are collected;
no game property is written. The packaged inventories are appended as API-definition records (within the same
capture budgets), including method signatures as reference metadata; methods are not invoked just because they exist.

Public type pages do not distinguish every setter-only property from readable
state. The generator excludes seven properties confirmed to lack get accessors by
Turbo 1.29.14's compiler log, conservatively in both games, and respects explicit
`readable: false` member metadata. These remain in the inventory and appear as
unsupported with a getter-unavailable reason. Catching a runtime exception cannot
protect a read rejected during compilation. Other runtime/API mismatches still
require compile/load validation against the installed Openplanet version.

A capture walks **live objects reachable from `GetApp()`**. It does not fabricate
instances for classes absent from the active mode, and it cannot read every API
in every scene at once. Menu, race, editor, and split-screen captures expose
different graphs. Capture each state separately when investigating a transition.
A dump spans frames; every object has an observation timestamp. Changes in the
playground terminate traversal with an explicit truncated result.

Native reflection contributes type/member names and IDs and is compared with the
generated fields for each object. The public reflection API has no generic typed
value reader. Undocumented runtime classes, non-node structs/interfaces, DataRef
values, and other unsupported shapes remain explicit coverage gaps. Next's
helper script objects are not CMwNod instances: a separate helper summary reads
the MLFeed race/player values and VehicleState throttle already used by this
plugin, rather than claiming a full dump of helper plugin internals.

Runtime member entries distinguish captured values from `not-captured` names.
Per-object issues give exclusion, unsupported-type, and getter-exception reasons.
The manifest reports captured/excluded/unsupported/failed counts, truncations,
runtime and plugin versions, collector version, API inventory hash, and budgets.
`complete` means traversal finished within the budgets; check the coverage counts
for unavailable fields. Receiver `complete: true` means **all chunks arrived**;
a fully uploaded capture may still have `truncated`, `cancelled`, or `failed`
probe status.

Primitive JSON values retain their type; 64-bit integers are strings to avoid
precision loss in consumers. Vectors/matrices use the runtime's textual component
representation. Non-finite numbers are strings. Objects have dump-local IDs and
`ref` links, so shared references and cycles do not recurse forever. Arrays carry
original length and captured values. Long strings include their original byte
length and a valid UTF-8 prefix.

### Budgets and privacy

Defaults: 4096 objects, depth 12, 128 elements per array, 4096 bytes per string,
and 30 seconds. Settings allow bounded increases. The capture has a fixed 16 MiB
serialized-record budget; a record over 256 KiB is replaced by an explicit
omission record. Chunks target 384 KiB. Work yields between objects and at least every 32 checkpoints, or after
approximately 2 ms between property reads. Array elements, reference scans, and
reflection enumeration also checkpoint; an individual native getter cannot
be preempted. Large arrays are capped before traversing their elements. These
are cooperative budgets, not a guarantee that unsafe native getters cannot
stall or crash the game. Catchable getter exceptions are recorded.

Member names matching credentials, tokens, cookies, logins, accounts, profiles,
authors, friends, messages, paths, URLs, or similar sensitive categories are
excluded before reading. This is a conservative name policy, **not a guarantee
that arbitrary game text contains no private data**. Dumps can contain names,
map content, UI strings, IDs, and other private state. Inspect them before sharing.
Plugin settings and HTTP secrets are never collected. Logs/status never include
request bodies, bearer tokens, or response bodies.

## Receiver protocol and storage

`GET /health` returns `{"status":"ok"}`. The only ingestion endpoint is
`POST /diagnostics/v1/chunks`, requiring JSON and the dedicated bearer token.
The full schema is in [OpenAPI](../openapi.yaml).

```json
{
  "schemaVersion": "1.0.0",
  "captureId": "c211b7cd-f6a1-4f60-9000-2debd9484a00",
  "game": "turbo",
  "index": 0,
  "total": 2,
  "kind": "records",
  "data": []
}
```

Indices `0..total-2` contain arrays of diagnostic records. Index `total-1`
is an object manifest with `startedAt`, `endedAt`, and a probe `status` of
`complete`, `truncated`, `cancelled`, or `failed`. Every envelope for a capture
must use the same game/total. At least two chunks and at most 1024 are accepted.

Acknowledgements include `captureId`, `index`, `complete`, and `missing` indices.
New chunks return 201; identical retries return 200. Out-of-order uploads are
accepted. Conflicting content/game/total returns 409. Invalid chunks return 400,
missing/incorrect auth 401, incorrect content type 415, size violations 413,
storage failures 503, and storage quota exhaustion 507.

The plugin retries network failures, 408, 429, and 5xx up to four attempts per
chunk, with 1/2/4-second backoff and numeric Retry-After capped at 60 seconds.
Requests time out after 15 seconds; redirects are disabled. Cancel remains
responsive during backoff. A later manual Retry starts from chunk zero.

Each capture gets a UUID-named directory containing `capture.json`, numbered raw
chunks, and (only after all chunks arrive) `complete.json` with the manifest and
server-computed SHA-256 hashes. Temporary files are written/flushed then renamed;
no acknowledgement is sent before the chunk write completes. Power-loss
survivability depends on the filesystem and host storage; this is not a database
with replicated durability. One receiver process must own each storage directory.

Limits: 1 MiB per HTTP body, 32 MiB per stored capture, 512 MiB per store (with
metadata reserve), one day for incomplete captures, seven days for completed
captures. Retention runs on uploads and hourly. Disk-full captures stay available
for inspection; 507 requests can be retried after cleanup. The library constructor
allows retention/quota overrides for embedding/tests; CLI defaults are fixed.

```bash
bun tools/diagnostics-receiver/inspect.mjs list ./diagnostics-data
bun tools/diagnostics-receiver/inspect.mjs show ./diagnostics-data <capture-uuid>
bun tools/diagnostics-receiver/inspect.mjs diff ./diagnostics-data <before-uuid> <after-uuid>
```

`show` reconstructs records and lists missing chunks. `diff` compares records at
their first traversal path; IDs and traversal order can change between captures,
so this is a raw diagnostic comparison rather than a semantic game-state diff.

## Regeneration and verification

```bash
# Offline, deterministic generation from committed inventories
python3 scripts/generate-diagnostics.py
# Refresh public documentation; requires network access
python3 scripts/generate-diagnostics.py --refresh
# Refresh only one game's reference
python3 scripts/generate-diagnostics.py --refresh --game next

bun test tests/diagnostics-receiver.test.mjs
python3 tests/diagnostics-generation.py
node tests/validate-fixtures.mjs
npx prettier -w .
```

API sources: [Turbo](https://turbo.openplanet.dev/),
[Next](https://next.openplanet.dev/),
[reflection](https://openplanet.dev/docs/api/Reflection), and
[build defines](https://openplanet.dev/docs/reference/info-toml).
The inventories carry a source URL per class. Refresh both games after runtime
API changes and compile/load the diagnostics artifact before distribution.

Receiver protocol tests include a real HTTP upload and CLI reconstruction,
auth/schema failures, concurrent duplicate retries, conflicts, partial writes,
restart, retention, and quotas. Generation tests cover nested enum panels,
every documented field's accounting, deterministic output, and production
archive isolation. CI runs these alongside existing webhook fixtures and format/
OpenAPI checks.

**Required game validation before calling this release ready:** compile/load in
Turbo and Next; capture menus, a race, respawn, finish, supported local multiplayer,
and a map transition; inspect resulting coverage; measure frame cost and memory;
exercise offline upload, cancel, and retry. This Linux container does not contain
the game/Openplanet runtimes or PowerShell, so local automated checks do not prove
AngelScript compilation, native getter safety, frame cost, or Windows packaging.
