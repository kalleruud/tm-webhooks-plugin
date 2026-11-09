import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'

const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

function assertNoEmptyStrings(value, path = '$') {
  if (typeof value === 'string') {
    assert.notEqual(value, '', `${path} must not be an empty string`)
    return
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) =>
      assertNoEmptyStrings(item, `${path}[${index}]`)
    )
    return
  }
  if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      assertNoEmptyStrings(child, `${path}.${key}`)
    }
  }
}

function assertPlayer(player, index) {
  assert.ok(player)
  assert.equal(player.playerIndex, index)
  assert.match(player.attemptId, uuid)
  if ('name' in player) assert.equal(typeof player.name, 'string')
  if ('login' in player) {
    assert.equal(typeof player.login, 'string')
  }
  if ('localId' in player) {
    assert.equal(typeof player.localId, 'string')
  }
  if ('accountId' in player) {
    assert.equal(typeof player.accountId, 'string')
  }
}

async function readFixture(name) {
  return JSON.parse(
    await readFile(new URL(`fixtures/${name}`, import.meta.url))
  )
}

// Identity is scoped to an attempt, not a name, time, account, or roster index.
function validateAttemptIdentities(events) {
  const seen = new Set()
  let roster
  let gameId
  for (const event of events) {
    if (event.type === 'start') {
      roster = event.players
      gameId = event.game.gameId
      for (const [index, player] of roster.entries()) {
        assertPlayer(player, index)
        assert.ok(!seen.has(player.attemptId), 'attempt UUID must be fresh')
        assert.notEqual(player.attemptId, gameId)
        seen.add(player.attemptId)
      }
    } else {
      assert.ok(roster, 'player events need a captured start in these fixtures')
      assert.equal(event.game.gameId, gameId)
      if (event.type === 'end') {
        assert.ok(!('player' in event))
        assert.ok(!('attemptId' in event))
        roster = undefined
      } else {
        assertPlayer(event.player, event.player.playerIndex)
        assert.equal(
          event.player.attemptId,
          roster[event.player.playerIndex].attemptId,
          'attempt UUID must survive throttle, checkpoints, laps, respawns, and finish'
        )
      }
    }
  }
}

function validateFixture(events, expectedEventTypes) {
  assert.deepEqual(
    events.map(event => event.type),
    expectedEventTypes
  )

  validateAttemptIdentities(events)

  const start = events.find(event => event.type === 'start')
  const finish = events.find(event => event.type === 'finish')

  for (const event of events) {
    assertNoEmptyStrings(event)
    assert.equal(event.schemaVersion, '1.1.0')
    assert.match(event.eventId, uuid)
    assert.match(event.game.gameId, uuid)
    assert.equal(event.source.pluginName, 'TM Webhooks')
    assert.ok(['turbo', 'next'].includes(event.source.game))
    assert.ok(Number.isInteger(event.sequence) && event.sequence >= 0)
    assert.ok(Number.isInteger(event.durationMs) && event.durationMs >= 0)
    assert.match(
      event.occurredAt,
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
    )

    if (event.type === 'start') {
      assert.equal(event.players.length, event.game.totalPlayers)
      event.players.forEach((player, index) => assertPlayer(player, index))
      assert.ok('map' in event)
      assert.ok(event.mode)
      if (event.map !== null) {
        for (const field of ['name', 'uid', 'author', 'environment', 'type']) {
          assert.equal(typeof event.map[field], 'string')
        }
        assert.ok(event.map.medalTimesMs)
        for (const medal of ['author', 'gold', 'silver', 'bronze']) {
          assert.ok(Number.isInteger(event.map.medalTimesMs[medal]))
          assert.ok(event.map.medalTimesMs[medal] >= 0)
        }
        assert.equal(typeof event.map.isLaps, 'boolean')
        if (!event.map.isLaps) assert.ok(!('totalLaps' in event.map))
        if ('totalLaps' in event.map) {
          assert.ok(Number.isInteger(event.map.totalLaps))
          assert.ok(event.map.totalLaps > 0)
        }
        assert.ok(Number.isInteger(event.map.checkpointsPerLap))
        assert.ok(event.map.checkpointsPerLap >= 0)
      }
      assert.ok(
        [
          'campaign',
          'arcade',
          'hot-seat',
          'split-screen',
          'secret',
          'solo',
          'unknown',
        ].includes(event.mode.name)
      )
      assert.notEqual(event.mode.type, 'script')
      if (event.mode.name === 'secret') assert.ok(event.mode.type)
    } else if (event.type === 'end') {
      assert.ok(
        ['completed', 'restarted', 'aborted', 'unknown'].includes(
          event.endReason
        )
      )
    } else {
      assertPlayer(event.player, event.player.playerIndex)
      if (event.type !== 'first_throttle') assert.ok(event.checkpoint)
    }
  }

  assert.ok(start)
  assert.ok(finish)
  if (events.some(event => event.type === 'lap')) {
    const lap = events.find(event => event.type === 'lap')
    assert.equal(lap.checkpoint.checkpointLapIndex, 0)
  }
  assert.equal(
    finish.checkpoint.checkpointLapIndex,
    start.map.checkpointsPerLap + 1
  )
}

const turboEvents = await readFixture('events.json')
validateFixture(turboEvents, [
  'start',
  'first_throttle',
  'checkpoint',
  'lap',
  'respawn',
  'finish',
  'end',
])
assert.equal(turboEvents[0].players[0].login, 'player-one')
assert.ok(!('localId' in turboEvents[0].players[0]))
assert.ok(!('accountId' in turboEvents[0].players[0]))

const nextEvents = await readFixture('events.next.json')
validateFixture(nextEvents, [
  'start',
  'first_throttle',
  'checkpoint',
  'finish',
  'end',
])
assert.equal(nextEvents[0].players[0].localId, '123456789')
assert.match(nextEvents[0].players[0].accountId, uuid)
assert.equal(nextEvents[2].player.name, 'Driver Two')
assert.ok(!('login' in nextEvents[2].player))
assert.ok(!('localId' in nextEvents[2].player))
assert.ok(!('accountId' in nextEvents[2].player))

console.log(
  `Validated ${turboEvents.length + nextEvents.length} webhook event fixtures.`
)

// Both adapters share the identity contract. Restarting the same roster creates
// new attempts; a start-line respawn in the old round must retain its UUID.
const lifecycle = await readFixture('attempt-lifecycle.json')
for (const game of ['turbo', 'next']) {
  const events = lifecycle[game]
  validateAttemptIdentities(events)
  const starts = events.filter(event => event.type === 'start')
  assert.equal(starts.length, 2)
  assert.equal(
    events.find(event => event.type === 'end').endReason,
    'restarted'
  )
  assert.equal(
    events.find(event => event.type === 'respawn').checkpoint.checkpointIndex,
    0
  )
  assert.deepEqual(
    starts[0].players.map(player => player.name),
    starts[1].players.map(player => player.name)
  )

  for (const invalid of ['', 'not-a-uuid', starts[0].game.gameId, undefined]) {
    const broken = structuredClone(events)
    broken[0].players[0].attemptId = invalid
    assert.throws(() => validateAttemptIdentities(broken))
  }
  const respawnChanged = structuredClone(events)
  respawnChanged.find(event => event.type === 'respawn').player.attemptId =
    starts[1].players[0].attemptId
  assert.throws(() => validateAttemptIdentities(respawnChanged))

  const reused = structuredClone(events)
  reused.filter(event => event.type === 'start')[1].players[0].attemptId =
    starts[0].players[0].attemptId
  assert.throws(() => validateAttemptIdentities(reused))
  if (starts[0].players.length > 1) {
    const shared = structuredClone(events)
    shared[0].players[1].attemptId = shared[0].players[0].attemptId
    assert.throws(() => validateAttemptIdentities(shared))
  }
}
console.log(
  'Validated attempt identity across respawns, restarts, and player slots in both games.'
)

function validateArcadeScores(events) {
  const attempts = new Map()
  const turns = new Map()
  const roundSequences = new Map()
  const sessionSequences = new Map()
  const ended = new Set()
  const rounds = new Map()
  for (const event of events) {
    assertNoEmptyStrings(event)
    assert.equal(event.schemaVersion, '1.1.0')
    assert.match(event.eventId, uuid)
    if (event.type === 'score') {
      assert.ok(!('game' in event))
      assert.ok(!('durationMs' in event))
      assert.match(event.sessionId, uuid)
      assert.match(event.turnId, uuid)
      assert.equal(event.sequence, sessionSequences.get(event.sessionId) ?? 0)
      sessionSequences.set(event.sessionId, event.sequence + 1)
      assert.equal(event.mode, 'arcade')
      assert.equal(typeof event.player.name, 'string')
      assert.equal(typeof event.captureComplete, 'boolean')
      assert.equal(typeof event.mapUid, 'string')
      assert.ok(event.mapUid.length > 0)
      assert.equal(new Set(event.attemptIds).size, event.attemptIds.length)
      assert.deepEqual(event.attemptIds, turns.get(event.turnId))
      for (const id of event.attemptIds) {
        assert.equal(attempts.get(id).sessionId, event.sessionId)
        assert.equal(attempts.get(id).turnId, event.turnId)
        assert.ok(ended.has(id), 'fixture submissions occur after round end')
      }
    } else {
      const game = event.game.gameId
      assert.equal(event.sequence, roundSequences.get(game) ?? 0)
      roundSequences.set(game, event.sequence + 1)
      if (event.type === 'start') {
        rounds.set(game, event.players)
        for (const [i, player] of event.players.entries()) {
          assertPlayer(player, i)
          assert.match(player.sessionId, uuid)
          assert.match(player.turnId, uuid)
          assert.ok(!attempts.has(player.attemptId))
          attempts.set(player.attemptId, player)
          if (!turns.has(player.turnId)) turns.set(player.turnId, [])
          turns.get(player.turnId).push(player.attemptId)
        }
      } else if (event.player) {
        assert.deepEqual(
          event.player,
          rounds.get(game)[event.player.playerIndex]
        )
      } else if (event.type === 'end') {
        for (const player of rounds.get(game)) ended.add(player.attemptId)
      }
    }
  }
}
const arcade = await readFixture('arcade-score.json')
validateArcadeScores(arcade)
const scores = arcade.filter(event => event.type === 'score')
assert.equal(scores.length, 2)
assert.equal(scores[0].player.name, scores[1].player.name)
assert.notEqual(scores[0].turnId, scores[1].turnId)
assert.equal(scores[0].captureComplete, true)
assert.equal(scores[1].captureComplete, false)
for (const corrupt of [
  event => {
    event.game = { gameId: event.sessionId, totalPlayers: 1 }
  },
  event => {
    event.durationMs = 0
  },
  event => {
    event.player.name = ''
  },
  event => {
    delete event.captureComplete
  },
  event => {
    event.sequence = 99
  },
  event => {
    event.turnId = event.sessionId
  },
  event => {
    event.attemptIds.reverse()
  },
  event => {
    event.attemptIds.push(event.attemptIds[0])
  },
]) {
  const invalid = structuredClone(arcade)
  corrupt(invalid.find(event => event.type === 'score'))
  assert.throws(() => validateArcadeScores(invalid))
}
console.log(
  'Validated arcade score envelopes, captured attempt references, repeated names, and session sequencing.'
)

// A fully observed turn can include an aborted attempt: completeness describes
// capture coverage, not whether every attempt finished successfully.
assert.equal(scores[0].attemptIds.length, 3)
const interrupted = scores[0].attemptIds[2]
const interruptedRound = arcade.find(
  event =>
    event.type === 'start' &&
    event.players.some(player => player.attemptId === interrupted)
).game.gameId
assert.ok(
  !arcade.some(
    event => event.game?.gameId === interruptedRound && event.type === 'finish'
  )
)
assert.equal(
  arcade.find(
    event => event.game?.gameId === interruptedRound && event.type === 'end'
  ).endReason,
  'aborted'
)
assert.equal(scores[0].captureComplete, true)

const cancellation = await readFixture('turbo-cancel-boundary.json')
validateAttemptIdentities(cancellation.expectedEvents)
const started = cancellation.expectedEvents.filter(
  event => event.type === 'start'
)
const ends = cancellation.expectedEvents.filter(event => event.type === 'end')
assert.equal(started.length, 2)
assert.deepEqual(
  ends.map(event => event.endReason),
  ['aborted', 'aborted']
)
assert.ok(
  !cancellation.expectedEvents.some(event =>
    ['finish', 'score'].includes(event.type)
  )
)
const runningTimers = [
  ...new Set(
    cancellation.observations
      .filter(state => state.raceState === 1)
      .map(state => state.raceStartTime)
  ),
]
assert.equal(runningTimers.length, started.length)
const finalCountdown = cancellation.observations.slice(-2)
assert.ok(finalCountdown.every(state => state.raceState === 0))
assert.ok(finalCountdown[0].raceStartTime > 0)
assert.equal(finalCountdown[1].raceStartTime, 0)
console.log(
  'Validated expected cancellation payloads and no fabricated countdown attempt; runtime transition handling requires game testing.'
)

function validateHotSeat(events) {
  const names = new Map()
  const owners = new Map()
  const roundPlayers = new Map()
  const finishTimes = new Map()
  const scored = new Set()
  const sessionSequences = new Map()
  const roundSequences = new Map()
  for (const event of events) {
    assertNoEmptyStrings(event)
    assert.match(event.eventId, uuid)
    assert.equal(event.schemaVersion, '1.1.0')
    if (['player_name', 'score'].includes(event.type)) {
      assert.ok(!('game' in event) && !('durationMs' in event))
      assert.match(event.sessionId, uuid)
      assert.match(event.participantId, uuid)
      assert.equal(event.sequence, sessionSequences.get(event.sessionId) ?? 0)
      sessionSequences.set(event.sessionId, event.sequence + 1)
      const key = `${event.sessionId}:${event.participantId}`
      if (event.type === 'player_name') {
        assert.equal(typeof event.name, 'string')
        assert.ok(event.name.length > 0)
        assert.notEqual(
          event.name,
          names.get(key),
          'identical confirmed name must not emit again'
        )
        names.set(key, event.name)
      } else {
        assert.equal(event.mode, 'hot-seat')
        assert.equal(typeof event.mapUid, 'string')
        assert.match(event.attemptId, uuid)
        assert.equal(owners.get(event.attemptId), key)
        assert.equal(event.result.status, 'finished')
        assert.equal(event.result.timeMs, finishTimes.get(event.attemptId))
        assert.ok(
          !scored.has(event.attemptId),
          'one score per completed captured attempt'
        )
        scored.add(event.attemptId)
        for (const field of ['turnId', 'attemptIds', 'captureComplete'])
          assert.ok(!(field in event))
        if (names.has(key)) assert.equal(event.player.name, names.get(key))
        else
          assert.ok(
            !('player' in event),
            'no default/profile name or empty wrapper'
          )
      }
    } else {
      const game = event.game.gameId
      assert.equal(event.sequence, roundSequences.get(game) ?? 0)
      roundSequences.set(game, event.sequence + 1)
      if (event.type === 'start') {
        roundPlayers.set(game, event.players)
        for (const [index, player] of event.players.entries()) {
          assertPlayer(player, index)
          assert.match(player.sessionId, uuid)
          assert.match(player.participantId, uuid)
          assert.ok(!('turnId' in player))
          assert.ok(!owners.has(player.attemptId))
          owners.set(
            player.attemptId,
            `${player.sessionId}:${player.participantId}`
          )
        }
      } else if (event.player) {
        assert.deepEqual(
          event.player,
          roundPlayers.get(game)[event.player.playerIndex]
        )
        if (event.type === 'finish')
          finishTimes.set(event.player.attemptId, event.durationMs)
      }
    }
  }
  assert.equal(
    scored.size,
    finishTimes.size,
    'each observed finish has a score'
  )
}
const hotseat = await readFixture('hotseat-events.json')
validateHotSeat(hotseat)
const hotNames = hotseat.filter(event => event.type === 'player_name')
assert.deepEqual(
  hotNames.map(event => event.name),
  ['7777', '8888', '9999']
)
assert.equal(hotNames[1].participantId, hotNames[2].participantId)
assert.notEqual(hotNames[0].participantId, hotNames[1].participantId)
const hotScores = hotseat.filter(event => event.type === 'score')
assert.ok(!('player' in hotScores[0])) // Named later through the same participant UUID.
assert.equal(hotScores[2].player.name, '8888') // Existing payload is not rewritten by rename.
assert.equal(hotScores.at(-1).player.name, '9999')
for (const corrupt of [
  events => {
    events.find(e => e.type === 'score').player = { name: 'BLUE' }
  },
  events => {
    events.find(e => e.type === 'score').result.timeMs++
  },
  events => {
    events.find(e => e.type === 'score').participantId =
      hotNames[0].participantId
  },
  events => {
    events.find(e => e.type === 'player_name').game = {
      gameId: hotNames[0].sessionId,
      totalPlayers: 1,
    }
  },
  events => {
    events.find(e => e.type === 'score').durationMs = 0
  },
  events => {
    events.filter(e => e.type === 'player_name')[2].name = '8888'
  },
  events => {
    events.filter(e => e.type === 'score')[1].sequence = 0
  },
  events => {
    events.filter(e => e.type === 'player_name')[2].participantId =
      hotNames[0].participantId
  },
]) {
  const invalid = structuredClone(hotseat)
  corrupt(invalid)
  assert.throws(() => validateHotSeat(invalid))
}
console.log(
  'Validated Hot Seat session sequencing, stable rename identity, late names, immutable earlier names, final times, and no scores for aborted/restarted attempts.'
)
