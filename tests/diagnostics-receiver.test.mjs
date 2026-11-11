import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile, readdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  createReceiver,
  MAX_CHUNK_BYTES,
} from '../tools/diagnostics-receiver/server.mjs'

const id = 'c211b7cd-f6a1-4f60-9000-2debd9484a00'
const record = {
  schemaVersion: '1.0.0',
  captureId: id,
  game: 'turbo',
  index: 0,
  total: 2,
  kind: 'records',
  data: [{ kind: 'object', id: 0, fields: { speed: 42 } }],
}
const manifest = {
  ...record,
  index: 1,
  kind: 'manifest',
  data: {
    startedAt: '2026-01-01T00:00:00Z',
    endedAt: '2026-01-01T00:00:01Z',
    status: 'complete',
  },
}
async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'tm-diagnostics-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const receiver = createReceiver({
    directory,
    token: 'test-only-token',
    ...options,
  })
  const send = (body, headers = {}) =>
    receiver.fetch(
      new Request('http://receiver/diagnostics/v1/chunks', {
        method: 'POST',
        headers: {
          authorization: 'Bearer test-only-token',
          'content-type': 'application/json',
          ...headers,
        },
        body: typeof body === 'string' ? body : JSON.stringify(body),
      })
    )
  return { receiver, send, directory }
}
test('out-of-order concurrent duplicates reconstruct one complete capture and survive restart', async t => {
  const { send, directory } = await fixture(t)
  const first = await send(manifest)
  assert.equal(first.status, 201)
  assert.deepEqual((await first.json()).missing, [0])
  await assert.rejects(readFile(join(directory, id, 'complete.json')), {
    code: 'ENOENT',
  })
  const results = await Promise.all([send(record), send(record)])
  assert.deepEqual(results.map(x => x.status).sort(), [200, 201])
  assert.ok((await results[0].json()).complete)
  const complete = JSON.parse(
    await readFile(join(directory, id, 'complete.json'))
  )
  assert.equal(complete.manifest.status, 'complete')
  assert.equal(complete.hashes.length, 2)
  const again = createReceiver({ directory, token: 'test-only-token' })
  assert.equal(
    (
      await again.fetch(
        new Request('http://receiver/diagnostics/v1/chunks', {
          method: 'POST',
          headers: {
            authorization: 'Bearer test-only-token',
            'content-type': 'application/json',
          },
          body: JSON.stringify(record),
        })
      )
    ).status,
    200
  )
  assert.equal(
    (await send({ ...record, data: [{ changed: true }] })).status,
    409
  )
  assert.equal((await send({ ...record, game: 'next' })).status, 409)
  assert.equal((await send({ ...record, total: 3 })).status, 409)
})
test('rejects unauthenticated, malformed, traversal, incompatible and oversized requests without writing', async t => {
  const { send, directory, receiver } = await fixture(t)
  assert.equal(
    (await send(record, { authorization: 'Bearer wrong' })).status,
    401
  )
  assert.equal(
    (await send(record, { 'content-type': 'text/plain' })).status,
    415
  )
  for (const bad of [
    '{',
    null,
    { ...record, captureId: '../outside' },
    { ...record, index: -1 },
    { ...record, total: 1025 },
    { ...record, schemaVersion: '2' },
    { ...manifest, index: 0 },
    { ...record, data: [null] },
  ])
    assert.equal((await send(bad)).status, 400)
  assert.equal((await send(' '.repeat(MAX_CHUNK_BYTES + 1))).status, 413)
  assert.equal(
    (await receiver.fetch(new Request('http://receiver/health'))).status,
    200
  )
  assert.equal(
    (await receiver.fetch(new Request('http://receiver/diagnostics/v1/chunks')))
      .status,
    405
  )
  assert.deepEqual(await readdir(directory), [])
})
test('enforces storage quota and capture quota before acknowledging', async t => {
  const { send, directory } = await fixture(t, { maxDiskBytes: 100 })
  assert.equal((await send(record)).status, 507)
  assert.deepEqual(await readdir(directory), [])
  assert.throws(() => createReceiver({ directory, token: '' }), /required/)
})
test('unfinished writes do not complete a capture; retry repairs it', async t => {
  const { send, directory } = await fixture(t)
  await send(record)
  await writeFile(join(directory, id, '1.json.tmp'), '{interrupted')
  assert.ok((await (await send(record)).json()).missing.includes(1))
  assert.equal((await send(manifest)).status, 201)
  assert.ok(
    JSON.parse(await readFile(join(directory, id, 'complete.json'))).receivedAt
  )
})
test('retention cleans incomplete and complete captures without deleting unrelated files', async t => {
  const { send, directory } = await fixture(t)
  await send(record)
  const metaPath = join(directory, id, 'capture.json')
  const meta = JSON.parse(await readFile(metaPath))
  await writeFile(metaPath, JSON.stringify({ ...meta, createdAt: 0 }))
  await writeFile(join(directory, 'keep.txt'), 'unrelated')
  await createReceiver({ directory, token: 'test', incompleteMs: 1 }).cleanup()
  assert.deepEqual(await readdir(directory), ['keep.txt'])
  await send(record)
  await send(manifest)
  await writeFile(metaPath, JSON.stringify({ ...meta, createdAt: 0 }))
  await createReceiver({ directory, token: 'test', retentionMs: 1 }).cleanup()
  assert.deepEqual(await readdir(directory), ['keep.txt'])
})
test('capture size limit remains enforced even when the store has free space', async t => {
  const { send, directory } = await fixture(t)
  await send(record)
  // Existing bytes count toward the capture budget, including interrupted temp files.
  await writeFile(
    join(directory, id, 'large.tmp'),
    Buffer.alloc(32 * 1024 * 1024)
  )
  assert.equal((await send(manifest)).status, 413)
})
test('real Bun HTTP server accepts authenticated uploads and inspect CLI reconstructs the dump', async t => {
  const { receiver, directory } = await fixture(t)
  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    fetch: receiver.fetch,
  })
  t.after(() => server.stop(true))
  for (const body of [record, manifest]) {
    const response = await fetch(
      `http://127.0.0.1:${server.port}/diagnostics/v1/chunks`,
      {
        method: 'POST',
        headers: {
          authorization: 'Bearer test-only-token',
          'content-type': 'application/json',
        },
        body: JSON.stringify(body),
      }
    )
    assert.equal(response.status, 201)
  }
  const streamId = 'c211b7cd-f6a1-4f60-9000-2debd9484a01'
  for (const body of [
    {
      schemaVersion: '1.1.0',
      captureId: streamId,
      game: 'next',
      index: 0,
      kind: 'record',
      data: { kind: 'field', value: 9 },
    },
    {
      schemaVersion: '1.1.0',
      captureId: streamId,
      game: 'next',
      index: 1,
      kind: 'manifest',
      data: manifest.data,
    },
  ]) {
    const response = await fetch(
      `http://127.0.0.1:${server.port}/diagnostics/v1/chunks`,
      {
        method: 'POST',
        headers: {
          authorization: 'Bearer test-only-token',
          'content-type': 'application/json',
        },
        body: JSON.stringify(body),
      }
    )
    assert.equal(response.status, 201)
  }
  assert.equal(
    JSON.parse(await readFile(join(directory, streamId, 'complete.json')))
      .total,
    2
  )
  const child = Bun.spawn(
    ['bun', 'tools/diagnostics-receiver/inspect.mjs', 'show', directory, id],
    { stdout: 'pipe', stderr: 'pipe' }
  )
  const dump = JSON.parse(await new Response(child.stdout).text())
  assert.equal(await child.exited, 0)
  assert.deepEqual(dump.missing, [])
  assert.equal(dump.records[0].fields.speed, 42)
})

const streamRecord = {
  schemaVersion: '1.1.0',
  captureId: id,
  game: 'turbo',
  index: 0,
  kind: 'record',
  data: { kind: 'field', objectId: 0, member: 'Speed', value: 42 },
}
const streamManifest = {
  ...streamRecord,
  index: 2,
  kind: 'manifest',
  data: manifest.data,
}
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
  assert.equal((await send(record)).status, 409)
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
  const receiver = createReceiver({ directory, token: 'test-only-token' })
  const response = await receiver.fetch(
    new Request('http://receiver/diagnostics/v1/chunks', {
      method: 'POST',
      headers: {
        authorization: 'Bearer test-only-token',
        'content-type': 'application/json',
      },
      body: JSON.stringify(streamManifest),
    })
  )
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

test('CLI diff preserves separate API-member identities within one type', async t => {
  const { send, directory } = await fixture(t)
  const secondId = 'c211b7cd-f6a1-4f60-9000-2debd9484a02'
  for (const captureId of [id, secondId]) {
    const members = [
      { name: 'First', type: captureId === id ? 'int' : 'bool' },
      { name: 'Last', type: 'float' },
    ]
    for (let index = 0; index < members.length; index++) {
      assert.equal(
        (
          await send({
            ...streamRecord,
            captureId,
            index,
            data: {
              kind: 'api-member',
              type: 'CExample',
              member: members[index],
            },
          })
        ).status,
        201
      )
    }
    assert.equal((await send({ ...streamManifest, captureId })).status, 201)
  }
  const child = Bun.spawn(
    [
      'bun',
      'tools/diagnostics-receiver/inspect.mjs',
      'diff',
      directory,
      id,
      secondId,
    ],
    { stdout: 'pipe', stderr: 'pipe' }
  )
  const output = (await new Response(child.stdout).text()).trim()
  assert.equal(await child.exited, 0)
  assert.notEqual(
    output,
    '',
    'changing First must not be hidden by unchanged Last'
  )
  const changes = output.split('\n').map(line => JSON.parse(line))
  assert.equal(changes.length, 1)
  assert.equal(changes[0].before.member.name, 'First')
  assert.equal(changes[0].after.member.type, 'bool')
})
