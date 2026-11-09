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
