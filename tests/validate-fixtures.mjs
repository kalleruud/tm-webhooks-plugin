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

const mapLevels = ['white', 'green', 'blue', 'red', 'black', 'custom']

function validateFixture(events, expectedEventTypes) {
  assert.deepEqual(
    events.map(event => event.type),
    expectedEventTypes
  )

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
        if ('level' in event.map) assert.ok(mapLevels.includes(event.map.level))
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

// Validate every recognized level and omission, using complete event fixtures
// from each game. Invalid strings and null must fail rather than imply a level.
const levelCases = await readFixture('map-levels.json')
for (const events of [turboEvents, nextEvents]) {
  const types = events.map(event => event.type)
  for (const testCase of levelCases) {
    const variant = structuredClone(events)
    delete variant[0].map.level
    if ('level' in testCase) {
      variant[0].map.level = testCase.level
    }
    validateFixture(variant, types)
  }
  for (const invalid of ['unknown', 'White', '', null, 0]) {
    const variant = structuredClone(events)
    variant[0].map.level = invalid
    assert.throws(() => validateFixture(variant, types))
  }
}

// Both event type headers must stay declared, required, and interchangeable:
// `event_type` for existing receivers and `event-type` for proxies that drop
// underscore-bearing header names. Each must accept every fixture event type
// and every discriminator value of the payload contract.
const openapi = await readFile(
  new URL('../openapi.yaml', import.meta.url),
  'utf8'
)
function headerParameter(name) {
  const block = openapi.match(
    new RegExp(`- name: ${name}\\n((?: {10}.*\\n|\\s*\\n)+)`)
  )
  assert.ok(block, `openapi.yaml must declare the ${name} header`)
  assert.match(block[1], /^ {10}in: header$/m, `${name} must be a header`)
  assert.match(block[1], /^ {10}required: true$/m, `${name} must be required`)
  const enumLine = block[1].match(/^ {12}enum: \[(.*)\]$/m)
  assert.ok(enumLine, `${name} must declare an enum`)
  return enumLine[1].split(',').map(value => value.trim())
}
const mapping = openapi.match(/ {8}mapping:\n((?: {10}\w+: .*\n)+)/)
assert.ok(mapping, 'openapi.yaml must declare the Event discriminator mapping')
const discriminatorTypes = [...mapping[1].matchAll(/^ {10}(\w+):/gm)].map(
  match => match[1]
)
const legacyHeaderTypes = headerParameter('event_type')
const aliasHeaderTypes = headerParameter('event-type')
assert.deepEqual(aliasHeaderTypes, legacyHeaderTypes)
assert.deepEqual([...legacyHeaderTypes].sort(), [...discriminatorTypes].sort())
for (const event of [...turboEvents, ...nextEvents]) {
  assert.ok(legacyHeaderTypes.includes(event.type))
  assert.ok(aliasHeaderTypes.includes(event.type))
}
