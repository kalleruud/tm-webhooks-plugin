import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile, readdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  createReceiver,
  MAX_STREAM_PACKET_BYTES,
} from '../tools/diagnostics-receiver/server.mjs'

const id = 'c211b7cd-f6a1-4f60-9000-2debd9484a00'
const manifestData = {
  startedAt: '2026-01-01T00:00:00Z',
  endedAt: '2026-01-01T00:00:01Z',
  status: 'complete',
  captureMode: 'run-recorder',
}
const streamRecord = {
  schemaVersion: '1.1.0',
  captureId: id,
  game: 'turbo',
  index: 0,
  kind: 'record',
  data: { kind: 'run-coverage', section: 'test', reason: 'fixture', value: 42 },
}
const streamManifest = {
  ...streamRecord,
  index: 2,
  kind: 'manifest',
  data: manifestData,
}
const post = (receiver, body, headers = {}) =>
  receiver.fetch(
    new Request('http://receiver/diagnostics/v1/chunks', {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: typeof body === 'string' ? body : JSON.stringify(body),
    })
  )
async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'tm-diagnostics-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const receiver = createReceiver({ directory, ...options })
  return {
    receiver,
    send: (body, headers) => post(receiver, body, headers),
    directory,
  }
}
const inspect = async (...args) => {
  const child = Bun.spawn(
    ['bun', 'tools/diagnostics-receiver/inspect.mjs', ...args],
    { stdout: 'pipe', stderr: 'pipe' }
  )
  const output = await new Response(child.stdout).text()
  assert.equal(await child.exited, 0)
  return JSON.parse(output)
}

test('accepts unauthenticated packets and rejects malformed or unsupported requests without writing', async t => {
  const { send, directory, receiver } = await fixture(t)
  assert.equal(
    (await send(streamRecord, { 'content-type': 'text/plain' })).status,
    415
  )
  for (const bad of [
    '{',
    null,
    { ...streamRecord, captureId: '../outside' },
    { ...streamRecord, schemaVersion: '1.0.0', total: 2 },
    { ...streamRecord, total: 3 },
    { ...streamRecord, index: 32767 },
    { ...streamRecord, index: -1 },
    { ...streamRecord, data: [] },
    { ...streamManifest, index: 32768 },
    { ...streamManifest, data: { status: 'complete' } },
  ])
    assert.equal((await send(bad)).status, 400)
  assert.equal(
    (await send(' '.repeat(MAX_STREAM_PACKET_BYTES + 1))).status,
    413
  )
  const health = await receiver.fetch(new Request('http://receiver/health'))
  assert.deepEqual(await health.json(), {
    status: 'ok',
    schemaVersions: ['1.1.0'],
  })
  assert.equal(
    (await receiver.fetch(new Request('http://receiver/diagnostics/v1/chunks')))
      .status,
    405
  )
  assert.deepEqual(await readdir(directory), [])
})

test('retention cleans incomplete and complete captures without deleting unrelated files', async t => {
  const { send, directory } = await fixture(t)
  await send(streamRecord)
  const metaPath = join(directory, id, 'capture.json')
  const meta = JSON.parse(await readFile(metaPath))
  await writeFile(metaPath, JSON.stringify({ ...meta, createdAt: 0 }))
  await writeFile(join(directory, 'keep.txt'), 'unrelated')
  await createReceiver({ directory, incompleteMs: 1 }).cleanup()
  assert.deepEqual(await readdir(directory), ['keep.txt'])
  for (const index of [0, 1]) await send({ ...streamRecord, index })
  await send(streamManifest)
  await writeFile(metaPath, JSON.stringify({ ...meta, createdAt: 0 }))
  await createReceiver({ directory, retentionMs: 1 }).cleanup()
  assert.deepEqual(await readdir(directory), ['keep.txt'])
})
test('capture size limit remains enforced even when the store has free space', async t => {
  const { send, directory } = await fixture(t)
  await send(streamRecord)
  await writeFile(
    join(directory, id, 'large.tmp'),
    Buffer.alloc(32 * 1024 * 1024)
  )
  // A fresh receiver measures existing files, including interrupted temp files.
  assert.equal(
    (await post(createReceiver({ directory }), { ...streamRecord, index: 1 }))
      .status,
    413
  )
})
test('real Bun HTTP server ingests a stream that the inspect CLI reconstructs', async t => {
  const { receiver, directory } = await fixture(t)
  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    fetch: receiver.fetch,
  })
  t.after(() => server.stop(true))
  for (const body of [
    streamRecord,
    { ...streamRecord, index: 1 },
    streamManifest,
  ]) {
    const response = await fetch(
      `http://127.0.0.1:${server.port}/diagnostics/v1/chunks`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      }
    )
    assert.equal(response.status, 201)
  }
  assert.equal(
    JSON.parse(await readFile(join(directory, id, 'complete.json'))).total,
    3
  )
  const dump = await inspect('show', directory, id)
  assert.deepEqual(dump.missing, [])
  assert.equal(dump.records[0].value, 42)
  const [listed] = (
    await new Response(
      Bun.spawn(
        ['bun', 'tools/diagnostics-receiver/inspect.mjs', 'list', directory],
        { stdout: 'pipe' }
      ).stdout
    ).text()
  )
    .trim()
    .split('\n')
    .map(line => JSON.parse(line))
  assert.equal(listed.status, 'complete')
})

test('best-effort stream accepts records immediately, handles final manifest first, and exposes gaps', async t => {
  const { send, directory } = await fixture(t)
  const response = await send(streamRecord)
  assert.equal(response.status, 201)
  assert.deepEqual(await response.json(), {
    captureId: id,
    index: 0,
    complete: false,
    missing: null,
  })
  const ending = await send(streamManifest)
  assert.deepEqual((await ending.json()).missing, [1])
  assert.equal((await send(streamRecord)).status, 200)
  await assert.rejects(readFile(join(directory, id, 'complete.json')), {
    code: 'ENOENT',
  })
  const filled = await send({ ...streamRecord, index: 1 })
  assert.ok((await filled.json()).complete)
  const complete = JSON.parse(
    await readFile(join(directory, id, 'complete.json'))
  )
  assert.equal(complete.total, 3)
  assert.equal((await send({ ...streamRecord, index: 3 })).status, 409)
  assert.equal((await send({ ...streamManifest, index: 1 })).status, 409)
  assert.equal(
    (await send({ ...streamRecord, data: { changed: true } })).status,
    409
  )
})
test('a lost stream manifest stays incomplete after restart; CLI still exposes received records', async t => {
  const { send, directory } = await fixture(t)
  await send({ ...streamRecord, index: 1 })
  const child = Bun.spawn(
    ['bun', 'tools/diagnostics-receiver/inspect.mjs', 'show', directory, id],
    { stdout: 'pipe', stderr: 'pipe' }
  )
  const dump = JSON.parse(await new Response(child.stdout).text())
  assert.equal(await child.exited, 0)
  assert.equal(dump.complete, false)
  assert.equal(dump.total, null)
  assert.deepEqual(dump.missing, [0])
  assert.equal(dump.records[0].value, 42)
  const response = await post(createReceiver({ directory }), streamManifest)
  assert.deepEqual((await response.json()).missing, [0])
})
test('stream protocol rejects excessive size, illegal indexes, game/protocol conflicts and storage exhaustion', async t => {
  const { send } = await fixture(t)
  for (const bad of [
    { ...streamRecord, total: 3 },
    { ...streamRecord, index: 32767 },
    { ...streamRecord, index: -1 },
    { ...streamRecord, data: [] },
    { ...streamManifest, index: 32768 },
  ])
    assert.equal((await send(bad)).status, 400)
  assert.equal(
    (await send({ ...streamRecord, data: { text: 'x'.repeat(32768) } })).status,
    413
  )
  await send(streamRecord)
  assert.equal(
    (await send({ ...streamRecord, game: 'next', index: 1 })).status,
    409
  )
  const second = await fixture(t, { maxDiskBytes: 100 })
  assert.equal((await second.send(streamRecord)).status, 507)
  assert.deepEqual(await readdir(second.directory), [])
})

test('run recording packets reconstruct a time-series timeline through the CLI', async t => {
  const { send, directory } = await fixture(t)
  const runSample = (elapsedMs, race) => ({
    kind: 'run-sample',
    recordingId: id,
    playerId: 'driver-1',
    userKey: 'user-1',
    playerIndex: 0,
    name: 'Test Driver',
    elapsedMs,
    sampleSequence: elapsedMs / 100 + 1,
    attemptToken: 'map:start',
    mapUid: 'map',
    apiType: 'CTrackManiaPlayer',
    race,
    input: { throttle: elapsedMs ? 1 : 0, brake: false },
    vehicle: { speed: elapsedMs ? 10 : 0 },
    sources: {
      'race.checkpointTimesMs': 'CTrackManiaPlayer.CurRace.Checkpoints',
    },
  })
  const data = [
    { kind: 'run-recording-start', elapsedMs: 0, sampleIntervalMs: 100 },
    runSample(0, {
      racing: false,
      finished: false,
      checkpointCount: 0,
      respawns: 0,
    }),
    runSample(100, {
      racing: true,
      finished: false,
      checkpointCount: 0,
      respawns: 0,
    }),
    runSample(200, {
      racing: true,
      finished: true,
      checkpointCount: 1,
      checkpointTimesMs: [125],
      respawns: 0,
      finishTimeMs: 150,
    }),
    {
      kind: 'run-leaderboard',
      elapsedMs: 200,
      rows: [{ name: 'Test Driver', points: 10 }],
    },
  ]
  for (let index = 0; index < data.length; index++)
    assert.equal(
      (await send({ ...streamRecord, index, data: data[index] })).status,
      201
    )
  assert.equal(
    (
      await send({
        ...streamManifest,
        index: data.length,
        data: manifestData,
      })
    ).status,
    201
  )
  const child = Bun.spawn(
    [
      'bun',
      'tools/diagnostics-receiver/inspect.mjs',
      'timeline',
      directory,
      id,
    ],
    { stdout: 'pipe', stderr: 'pipe' }
  )
  const report = JSON.parse(await new Response(child.stdout).text())
  assert.equal(await child.exited, 0)
  assert.equal(report.deliveryComplete, true)
  assert.equal(report.players[0].name, 'Test Driver')
  assert.equal(report.leaderboards[0].rows[0].points, 10)
  assert.equal(
    report.events.find(event => event.event === 'checkpoint_observed')
      .raceTimeMs,
    125
  )
  assert.equal(report.series['driver-1/vehicle.speed'].points.length, 3)
})
