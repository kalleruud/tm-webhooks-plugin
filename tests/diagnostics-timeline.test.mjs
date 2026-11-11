import { test } from 'node:test'
import assert from 'node:assert/strict'
import { analyzeRecording } from '../tools/diagnostics-receiver/timeline.mjs'
const sample = (elapsedMs, changes = {}) => ({
  kind: 'run-sample',
  playerId: 'local-1',
  userKey: 'user-1',
  name: 'Driver',
  playerIndex: 0,
  elapsedMs,
  sampleSequence: elapsedMs / 100,
  mapUid: 'map',
  attemptToken: 'map:start-1',
  apiType: 'CTrackManiaPlayer',
  race: {
    racing: true,
    finished: false,
    timeMs: elapsedMs,
    checkpointCount: 0,
    respawns: 0,
    lap: 1,
  },
  input: { throttle: 1, brake: false, steer: 0 },
  vehicle: { speed: 20, damageHull: 0 },
  ...changes,
})
const beginning = {
  kind: 'run-recording-start',
  elapsedMs: 0,
  sampleIntervalMs: 100,
}
const analyze = records =>
  analyzeRecording({
    captureId: 'recording',
    complete: true,
    missing: [],
    records: [beginning, ...records],
  })
test('reconstructs a run from out-of-order samples with checkpoint times and distinct inferred input transitions', () => {
  const baseline = sample(0, {
    race: {
      racing: false,
      finished: false,
      timeMs: -100,
      checkpointCount: 0,
      respawns: 0,
      lap: 1,
    },
    input: { throttle: 0, brake: false },
  })
  const first = sample(100)
  const checkpoint = sample(200, {
    race: {
      racing: true,
      finished: false,
      checkpointCount: 1,
      checkpointTimesMs: [125],
      respawns: 0,
      lap: 1,
    },
    input: { throttle: 1, brake: true },
  })
  const finish = sample(300, {
    race: {
      racing: true,
      finished: true,
      checkpointCount: 1,
      checkpointTimesMs: [125],
      respawns: 0,
      lap: 2,
      finishTimeMs: 240,
    },
  })
  const report = analyze([finish, checkpoint, baseline, first])
  assert.equal(report.players[0].samples, 4)
  assert.deepEqual(
    report.events
      .filter(e => e.event === 'checkpoint_observed')
      .map(e => e.raceTimeMs),
    [125]
  )
  for (const name of [
    'start_observed',
    'throttle_pressed',
    'brake_pressed',
    'lap_observed',
    'finish_observed',
  ])
    assert.ok(
      report.events.some(e => e.event === name),
      name
    )
  assert.deepEqual(
    report.events.find(e => e.event === 'start_observed').observationWindowMs,
    [0, 100]
  )
  assert.equal(
    report.events.find(e => e.event === 'finish_observed').raceTimeMs,
    240
  )
  assert.deepEqual(
    report.series['local-1/input.throttle'].points.map(p => p.value),
    [0, 1, 1, 1]
  )
})
test('does not fabricate start or finish when recording begins mid-run or fields are unavailable', () => {
  const report = analyze([
    sample(1000),
    sample(1100, { race: { racing: true, timeMs: 1100 } }),
  ])
  assert.equal(report.players[0].attempts[0].joinedMidRun, true)
  assert.ok(
    !report.events.some(e =>
      ['start_observed', 'finish_observed', 'respawn_observed'].includes(
        e.event
      )
    )
  )
})
test('impact candidates exclude braking, respawns, long observation gaps and changed attempt tokens', () => {
  for (const [before, after] of [
    [
      sample(0, { vehicle: { speed: 50 } }),
      sample(100, { vehicle: { speed: 10 }, input: { brake: true } }),
    ],
    [
      sample(0, { vehicle: { speed: 50 } }),
      sample(100, {
        vehicle: { speed: 10 },
        race: { racing: true, respawns: 1 },
      }),
    ],
    [
      sample(0, { vehicle: { speed: 50 } }),
      sample(1000, { vehicle: { speed: 10 } }),
    ],
    [
      sample(0, { vehicle: { speed: 50 } }),
      sample(100, { vehicle: { speed: 10 }, attemptToken: 'other-start' }),
    ],
  ])
    assert.ok(
      !analyze([before, after]).events.some(e => e.event === 'impact_candidate')
    )
  const report = analyze([
    sample(0, { vehicle: { speed: 50, damageHull: 0 } }),
    sample(100, { vehicle: { speed: 10, damageHull: 0.2 } }),
  ])
  const impact = report.events.find(e => e.event === 'impact_candidate')
  assert.equal(impact.speedDrop, 40)
  assert.match(impact.classification, /not proof/)
  assert.equal(
    report.series['local-1/derived.speedChangePerSecond'].points[0].value,
    -400
  )
})
test('keeps split-screen players and native collision evidence separate and preserves incomplete delivery', () => {
  const report = analyzeRecording({
    complete: false,
    missing: [2],
    records: [
      beginning,
      sample(0),
      sample(0, { playerId: 'local-2', name: 'Other Driver' }),
      {
        kind: 'run-native-event',
        elapsedMs: 10,
        event: 'vehicle_collision',
        source: 'CSmArenaRulesMode.PendingEvents',
      },
    ],
  })
  assert.equal(report.players.length, 2)
  assert.equal(
    report.events.find(e => e.event === 'vehicle_collision').provenance,
    'native-api-event'
  )
  assert.equal(report.deliveryComplete, false)
  assert.deepEqual(report.missingPackets, [2])
})
test('does not pair checkpoint histories with a different source count', () => {
  const report = analyze([
    sample(0),
    sample(100, {
      race: {
        racing: true,
        finished: false,
        respawns: 0,
        checkpointCount: 2,
        checkpointTimesMs: [999],
        checkpointHistoryMatchesCount: false,
        checkpointTimeMs: 80,
      },
      sources: { 'race.checkpointTimeMs': 'MLFeed.LastCpTime' },
    }),
  ])
  const events = report.events.filter(e => e.event === 'checkpoint_observed')
  assert.equal(events[0].raceTimeMs, null)
  assert.equal(events[1].raceTimeMs, 80)
  assert.equal(events[1].source, 'MLFeed.LastCpTime')
})

test('brake release or an unknown previous brake value cannot imply an unbraked impact', () => {
  for (const input of [{ brake: true }, {}]) {
    const report = analyze([
      sample(0, { input, vehicle: { speed: 50 } }),
      sample(100, { input: { brake: false }, vehicle: { speed: 10 } }),
    ])
    assert.ok(!report.events.some(event => event.event === 'impact_candidate'))
  }
  const damage = analyze([
    sample(0, {
      input: { brake: true },
      vehicle: { speed: 50, damageHull: 0 },
    }),
    sample(100, {
      input: { brake: false },
      vehicle: { speed: 10, damageHull: 0.2 },
    }),
  ])
  assert.ok(damage.events.some(event => event.event === 'impact_candidate'))
})

test('each time-series point retains its actual API source across native/feed changes', () => {
  const report = analyze([
    sample(0, {
      sources: { 'race.timeMs': 'CSmScriptPlayer.CurrentRaceTime' },
    }),
    sample(100, { sources: { 'race.timeMs': 'MLFeed.CurrentRaceTime' } }),
    sample(200, { sources: { 'race.timeMs': 'MLFeed.CurrentRaceTime' } }),
  ])
  const field = report.series['local-1/race.timeMs']
  assert.deepEqual(
    field.points.map(point => point.source),
    [
      'CSmScriptPlayer.CurrentRaceTime',
      'MLFeed.CurrentRaceTime',
      'MLFeed.CurrentRaceTime',
    ]
  )
  assert.deepEqual(field.sources, [
    'CSmScriptPlayer.CurrentRaceTime',
    'MLFeed.CurrentRaceTime',
  ])
  assert.equal(field.source, 'mixed; see point sources')
})
