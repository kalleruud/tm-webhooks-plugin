# Issue #27: runtime access investigation

Status: blocked on live Turbo runtime validation. This is an investigation, not
an implemented `score` / `player_name` feature. No webhook payloads or schemas
have changed. Issue #27 targets the unpublished `1.1.0` contract; this
investigation does not change the schema version for either game build.

## Sources inspected

Inspected on 2026-11-09:

- [Issue #27](https://github.com/kalleruud/tm-webhooks-plugin/issues/27)
- [Turbo UI config](https://turbo.openplanet.dev/Game/CGamePlaygroundUIConfig)
- [Turbo UI manager](https://turbo.openplanet.dev/Game/CGamePlaygroundUIConfigMgr)
- [Turbo playground script](https://turbo.openplanet.dev/Game/CGamePlaygroundScript)
- [Turbo UI layer](https://turbo.openplanet.dev/Game/CGameUILayer)
- [Turbo UI script handler](https://turbo.openplanet.dev/Game/CGameScriptHandlerPlaygroundInterface)
- [Openplanet reflection](https://openplanet.dev/docs/api/Reflection)
- [Arcade mode source](https://github.com/openplanet-nl/turbo-scripts/blob/master/Scripts/Modes/TrackMania/TMC_LocalArcade.Script.txt)
- [Hot-seat mode source](https://github.com/openplanet-nl/turbo-scripts/blob/master/Scripts/Modes/TrackMania/TMC_HotSeat.Script.txt)
- [Score-table library](https://github.com/openplanet-nl/turbo-scripts/blob/master/Scripts/Libs/Openplanet/TMConsole/Ingame/ScoresTable.Script.txt)
- [Hot-seat name editor](https://github.com/openplanet-nl/turbo-scripts/blob/master/Scripts/Libs/Openplanet/TMConsole/Ingame/UI/UIWriteName.Script.txt)

The Turbo API pages identify their source build as 2016-11-07. They establish
candidate signatures, not compatibility with a currently running installation.
The game script sources likewise require a runtime cross-check.

## What the game scripts establish

Arcade calls `ST::ScoreWritten()` in postgame. It calls `ST::WriteName(False)`
when that is true, and `ST::WriteName(True)` on timeout. Both paths subsequently
call `SetTrackGhostsNickname()`. A changed ghost nickname or leaderboard name
therefore cannot prove explicit submission.

`WriteName(False)` uses `LibTMC_ScoresTable_NewScoreIndex` to select the entry,
sets its name from `LibTMC_ScoresTable_NewName`, sends updated names to the UI,
and resets the insertion index to `-1`. Capture must preserve the selected row
association before it is cleared. UI arrays include `Net_ScoresTableMenuRanks`,
`Net_ScoresTableMenuName`, and `Net_ScoresTableMenuTime`.

Arcade promotes a finish to `G_BestGhost` only when its time is strictly less
than `G_BestTimePlayer`, or no best exists. Equal times do not replace the
existing best in this source. This is useful lifecycle evidence, but does not
identify a captured best attempt without observing its promotion and turn.

Hot seat waits for `UIWriteName::ScoreWritten()`, then assigns
`G_IndexToName[Net_CurPlayerIndex] = UIWriteName::GetNewName()` and calls
`InitNames()`. Its UI state includes `Net_IndexToName` and `Net_CurPlayerIndex`.
The name editor sets `LibTMC_ScoresTable_NewNameTrigger` and
`LibTMC_ScoresTable_ScoreWritten` after pads confirm, and resets the flag at
editor lifecycle boundaries. Default colour labels and engine player names
cannot establish a confirmed human identity.

These are ManiaScript variables/functions, not AngelScript members callable as
`ST::ScoreWritten()` or `UIWriteName::GetNewName()` in this plugin.

## Candidate runtime access and remaining blocker

The documented entry path matches the existing Turbo adapter:
`cast<CGameManiaPlanet>(GetApp()).PlaygroundScript.UIManager.LocalPlayerConfig`.
UI config exposes layers and sequence state, but no typed getter for arbitrary
ManiaScript `declare` variables. `CGameUILayer.LocalPage` exposes the UI page;
this alone does not establish access to confirmation or the mode's globals.
Openplanet reflection documents engine class/member metadata; that does not
establish access to dynamically declared ManiaScript values.

`CGamePlaygroundScript` documents the candidate inspection method:

```angelscript
wstring Dbg_DumpDeclareForVariables(CMwNod@ Nod, bool StatsOnly)
```

A live development probe should null-check the app, playground script, UI
manager, and local config, then inspect:

```angelscript
app.PlaygroundScript.Dbg_DumpDeclareForVariables(
    app.PlaygroundScript.UIManager.LocalPlayerConfig, false);
```

This is a proposed probe, not a verified binding or a production parser. The
UI script handler also documents this method. It remains unverified whether
the dump exposes client netwrite values, server netread values, arrays, and
mode globals at the required phases, and whether transient transitions can be
observed reliably. Its output format is not a documented structured contract.
Do not ship a parser based on an invented dump format or unverified offsets.

No live Turbo/Openplanet session was inspected and no AngelScript compilation
was performed during this investigation. Packaging the shared `.op` archive
does not compile or smoke-test either target.

## Runtime evidence needed before implementation

Use a development build and record phase-labelled, local-only observations of
confirmation, trigger, editor visibility, slot, turn/attempt progression,
best-ghost promotion, insertion index, and committed row. Avoid logging tokens
or sending raw dumps to the configured webhook endpoint.

1. Arcade: enter text without confirming; confirm; leave the table visible;
   allow timeout; exit early; restart; finish equal-time attempts; play two
   consecutive turns with identical names. Establish which transitions survive
   polling and how the next turn rearms confirmation.
2. Attach mid-turn and miss an attempt. Verify turn identity and completeness
   without counting three observed finishes. Follow a confirmation through a
   delayed row update and verify which captured attempt the game promoted.
3. Hot seat: rename before racing, confirm unchanged text, cancel editing,
   switch slots/controllers, and rename after an attempt. Verify stable slot
   identity independently of engine player/login and name text.
4. Exit/re-enter the mode, replace the roster, restart, and change maps. Record
   which boundaries replace the logical session and which preserve participants.
5. Verify supported secret variants individually. Next needs its own verified
   equivalent API/lifecycle; its MLFeed race path provides no evidence of the
   Turbo name-entry lifecycle.

Once that access is established, implement the session/turn tracker beside
`RoundTracker`, allocate attempt UUIDs before race serialization, and keep the
session event sequence separate from round sequences. Freeze serialized events
before enqueueing. Extend OpenAPI, the webhook contract, examples, fixtures,
and receiver expectations together; do not advertise unimplemented event types.
Then exercise the issue's behavioral cases in the real games as well as
fixture checks and shared packaging.
