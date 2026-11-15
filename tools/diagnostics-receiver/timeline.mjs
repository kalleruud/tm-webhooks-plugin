// Pure analysis of recorded evidence. Inferences are kept distinct from native
// events and include observation windows; absence is never treated as zero.
const finite = value => typeof value === 'number' && Number.isFinite(value)
function flatten(value, prefix = '', result = {}) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const [key, child] of Object.entries(value))
      flatten(child, prefix ? `${prefix}.${key}` : key, result)
  } else result[prefix] = value
  return result
}

export function analyzeRecording(dump) {
  const records = [...dump.records]
    .filter(record => record.kind?.startsWith('run-'))
    .sort(
      (a, b) =>
        (a.elapsedMs ?? 0) - (b.elapsedMs ?? 0) ||
        (a.recordSequence ?? 0) - (b.recordSequence ?? 0)
    )
  const players = new Map(),
    events = [],
    series = {},
    previous = new Map()
  const start = records.find(record => record.kind === 'run-recording-start')
  const event = (name, sample, before, detail = {}) =>
    events.push({
      event: name,
      provenance: 'inferred-from-samples',
      playerId: sample.playerId,
      attemptToken: sample.attemptToken,
      elapsedMs: sample.elapsedMs,
      observationWindowMs: [before.elapsedMs, sample.elapsedMs],
      ...detail,
    })
  for (const sample of records) {
    if (sample.kind === 'run-native-event') {
      events.push({ ...sample, provenance: 'native-api-event' })
      continue
    }
    if (sample.kind !== 'run-sample' || !sample.playerId) continue
    if (!players.has(sample.playerId))
      players.set(sample.playerId, {
        playerId: sample.playerId,
        userKey: sample.userKey,
        name: sample.name,
        playerIndex: sample.playerIndex,
        firstObservedMs: sample.elapsedMs,
        samples: 0,
        names: [],
        attempts: [],
      })
    const player = players.get(sample.playerId)
    if (!player.names.length || player.names.at(-1).name !== sample.name)
      player.names.push({ elapsedMs: sample.elapsedMs, name: sample.name })
    player.name = sample.name ?? player.name
    player.lastObservedMs = sample.elapsedMs
    player.samples++
    const before = previous.get(sample.playerId)
    const sameAttempt =
      before &&
      before.attemptToken === sample.attemptToken &&
      before.mapUid === sample.mapUid
    const race = sample.race ?? {},
      oldRace = before?.race ?? {}
    if (!before || !sameAttempt) {
      player.attempts.push({
        token: sample.attemptToken ?? null,
        name: sample.name,
        mapUid: sample.mapUid,
        observedAtMs: sample.elapsedMs,
        joinedMidRun:
          race.racing === true &&
          (!finite(race.timeMs) ||
            race.timeMs > (start?.sampleIntervalMs ?? 100)),
        grouping: 'source start token; not proof of a restart',
      })
      events.push({
        event: before ? 'attempt_token_changed' : 'player_observed',
        provenance: 'observed-state',
        playerId: sample.playerId,
        elapsedMs: sample.elapsedMs,
        attemptToken: sample.attemptToken,
      })
    }
    if (before && sameAttempt) {
      const dt = sample.elapsedMs - before.elapsedMs
      if (dt > Math.max(500, 3 * (start?.sampleIntervalMs ?? 100)))
        event('sampling_gap', sample, before, { durationMs: dt })
      if (oldRace.racing === false && race.racing === true)
        event('start_observed', sample, before, {
          raceTimeMs: race.timeMs,
          source: sample.sources?.['race.timeMs'],
        })
      if (
        finite(race.respawns) &&
        finite(oldRace.respawns) &&
        race.respawns > oldRace.respawns
      )
        event('respawn_observed', sample, before, {
          before: oldRace.respawns,
          after: race.respawns,
        })
      if (
        finite(race.checkpointCount) &&
        finite(oldRace.checkpointCount) &&
        race.checkpointCount > oldRace.checkpointCount
      ) {
        for (
          let checkpoint = oldRace.checkpointCount + 1;
          checkpoint <= race.checkpointCount &&
          checkpoint <= oldRace.checkpointCount + 256;
          checkpoint++
        ) {
          const stored =
            race.checkpointHistoryMatchesCount === false
              ? undefined
              : race.checkpointTimesMs?.[checkpoint - 1]
          const fromHistory = finite(stored)
          const fromLastField =
            !fromHistory &&
            checkpoint === race.checkpointCount &&
            finite(race.checkpointTimeMs)
          event('checkpoint_observed', sample, before, {
            checkpoint,
            raceTimeMs: fromHistory
              ? stored
              : fromLastField
                ? race.checkpointTimeMs
                : null,
            timingEvidence: fromHistory
              ? 'stored-checkpoint-history'
              : fromLastField
                ? 'last-checkpoint-field'
                : 'unavailable',
            source:
              sample.sources?.[
                fromHistory
                  ? 'race.checkpointTimesMs'
                  : fromLastField
                    ? 'race.checkpointTimeMs'
                    : 'race.checkpointCount'
              ],
          })
        }
      }
      if (finite(race.lap) && finite(oldRace.lap) && race.lap > oldRace.lap)
        event('lap_observed', sample, before, {
          before: oldRace.lap,
          after: race.lap,
        })
      if (oldRace.finished === false && race.finished === true)
        event('finish_observed', sample, before, {
          raceTimeMs: race.finishTimeMs ?? null,
          source: sample.sources?.['race.finishTimeMs'],
        })
      const input = sample.input ?? {},
        oldInput = before.input ?? {}
      if (
        finite(input.throttle) &&
        finite(oldInput.throttle) &&
        input.throttle > 0.01 !== oldInput.throttle > 0.01
      )
        event(
          input.throttle > 0.01 ? 'throttle_pressed' : 'throttle_released',
          sample,
          before
        )
      if (
        typeof input.brake === 'boolean' &&
        typeof oldInput.brake === 'boolean' &&
        input.brake !== oldInput.brake
      )
        event(input.brake ? 'brake_pressed' : 'brake_released', sample, before)
      const vehicle = sample.vehicle ?? {},
        oldVehicle = before.vehicle ?? {}
      const noRespawn =
        finite(race.respawns) && race.respawns === oldRace.respawns
      if (
        dt > 0 &&
        dt <= 500 &&
        noRespawn &&
        race.racing === true &&
        oldRace.racing === true
      ) {
        if (finite(vehicle.speed) && finite(oldVehicle.speed)) {
          const key = `${sample.playerId}/derived.speedChangePerSecond`
          ;(series[key] ??= {
            source:
              'finite difference of native Speed and observed timestamps; native speed units/s',
            points: [],
          }).points.push({
            elapsedMs: sample.elapsedMs,
            value: ((vehicle.speed - oldVehicle.speed) * 1000) / dt,
          })
        }
        const speedDrop =
          finite(vehicle.speed) && finite(oldVehicle.speed)
            ? oldVehicle.speed - vehicle.speed
            : null
        const damageIncrease =
          finite(vehicle.damageHull) && finite(oldVehicle.damageHull)
            ? vehicle.damageHull - oldVehicle.damageHull
            : null
        if (
          (damageIncrease !== null && damageIncrease > 0.01) ||
          (speedDrop !== null &&
            speedDrop > 8 &&
            input.brake === false &&
            oldInput.brake === false)
        )
          event('impact_candidate', sample, before, {
            classification:
              'inference; not proof of collision or a wall target',
            speedDrop,
            damageIncrease,
            braking: input.brake ?? null,
          })
      }
    }
    for (const [name, value] of Object.entries(
      flatten({
        race: sample.race ?? {},
        input: sample.input ?? {},
        vehicle: sample.vehicle ?? {},
      })
    )) {
      const key = `${sample.playerId}/${name}`
      const source =
        sample.sources?.[name] ??
        start?.sources?.[name] ??
        sample.sources?.[name.split('.')[0]] ??
        sample.apiType ??
        'unavailable'
      const field = (series[key] ??= { source, sources: [], points: [] })
      if (!field.sources.includes(source)) field.sources.push(source)
      field.source =
        field.sources.length > 1 ? 'mixed; see point sources' : source
      field.points.push({
        elapsedMs: sample.elapsedMs,
        sampleSequence: sample.sampleSequence,
        source,
        value,
      })
    }
    previous.set(sample.playerId, sample)
  }
  for (const field of Object.values(series)) {
    const points = field.points
    const numeric = points.map(point => point.value).filter(finite)
    let changes = 0
    for (let i = 1; i < points.length; i++)
      if (
        JSON.stringify(points[i].value) !== JSON.stringify(points[i - 1].value)
      )
        changes++
    field.summary = {
      samples: points.length,
      changes,
      first: points[0]?.value ?? null,
      last: points.at(-1)?.value ?? null,
    }
    if (numeric.length) {
      let min = numeric[0],
        max = numeric[0]
      for (const value of numeric) {
        if (value < min) min = value
        if (value > max) max = value
      }
      field.summary.min = min
      field.summary.max = max
    }
  }
  return {
    captureId: dump.captureId,
    deliveryComplete: dump.complete ?? false,
    missingPackets: dump.missing ?? [],
    manifest: dump.manifest ?? null,
    sampleIntervalMs: start?.sampleIntervalMs ?? null,
    recording: start ?? null,
    players: [...players.values()],
    context: records.filter(record => record.kind === 'run-context'),
    leaderboards: records.filter(record => record.kind === 'run-leaderboard'),
    events: events.sort((a, b) => a.elapsedMs - b.elapsedMs),
    series,
    coverage: records.filter(record => record.kind === 'run-coverage'),
    limitations: [
      'Best-effort delivery and polling can miss data.',
      'Sample transitions are observation windows, not exact event timestamps.',
      'Impact candidates are not confirmed wall hits.',
      'Player identity includes a roster slot; userKey helps correlate roster changes.',
      'API leaderboard list order is not assumed rank.',
    ],
  }
}
