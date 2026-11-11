import { createHash, timingSafeEqual } from 'node:crypto'
import {
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises'
import { resolve, join } from 'node:path'

export const MAX_CHUNK_BYTES = 1024 * 1024
export const MAX_CAPTURE_BYTES = 32 * 1024 * 1024
export const MAX_CHUNKS = 1024
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const hash = text => createHash('sha256').update(text).digest('hex')
const json = (body, status = 200) => Response.json(body, { status })
const sameToken = (a, b) =>
  timingSafeEqual(Buffer.from(hash(a)), Buffer.from(hash(b)))

export function validateChunk(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  const { schemaVersion, captureId, game, index, total, kind, data } = value
  if (
    schemaVersion !== '1.0.0' ||
    !uuid.test(captureId) ||
    !['turbo', 'next'].includes(game)
  )
    return false
  if (
    !Number.isInteger(total) ||
    total < 2 ||
    total > MAX_CHUNKS ||
    !Number.isInteger(index) ||
    index < 0 ||
    index >= total
  )
    return false
  if (kind === 'records')
    return (
      index < total - 1 &&
      Array.isArray(data) &&
      data.every(x => x && typeof x === 'object' && !Array.isArray(x))
    )
  return (
    kind === 'manifest' &&
    index === total - 1 &&
    data &&
    typeof data === 'object' &&
    !Array.isArray(data) &&
    typeof data.startedAt === 'string' &&
    typeof data.endedAt === 'string' &&
    ['complete', 'truncated', 'cancelled', 'failed'].includes(data.status)
  )
}

export const MAX_STREAM_PACKETS = 32768
export const MAX_STREAM_PACKET_BYTES = 32768
export function validateStream(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false
  if (
    value.schemaVersion !== '1.1.0' ||
    !uuid.test(value.captureId) ||
    !['turbo', 'next'].includes(value.game)
  )
    return false
  if (
    !Number.isInteger(value.index) ||
    value.index < 0 ||
    value.index >= MAX_STREAM_PACKETS ||
    'total' in value
  )
    return false
  if (
    !value.data ||
    typeof value.data !== 'object' ||
    Array.isArray(value.data)
  )
    return false
  if (value.kind === 'record') return value.index < MAX_STREAM_PACKETS - 1
  return (
    value.kind === 'manifest' &&
    typeof value.data.startedAt === 'string' &&
    typeof value.data.endedAt === 'string' &&
    ['complete', 'truncated', 'cancelled', 'failed'].includes(value.data.status)
  )
}

async function optionalJson(path) {
  try {
    return JSON.parse(await readFile(path, 'utf8'))
  } catch (error) {
    if (error.code === 'ENOENT') return null
    throw error
  }
}
async function atomicJson(path, value) {
  const temporary = `${path}.tmp`
  await writeFile(temporary, JSON.stringify(value) + '\n', {
    mode: 0o600,
    flush: true,
  })
  await rename(temporary, path)
}

// One process owns the store. Serialize writes/cleanup so quota and finalization
// checks see a consistent set of files, including simultaneous retries.
export function createReceiver({
  directory,
  token,
  retentionMs = 7 * 86400000,
  incompleteMs = 86400000,
  maxDiskBytes = 512 * 1024 * 1024,
}) {
  if (!token) throw new Error('DIAGNOSTICS_TOKEN is required')
  const root = resolve(directory)
  let tail = Promise.resolve()
  const streams = new Map()
  let diskBytes = null
  let lastCleanup = 0
  const exclusive = work => {
    const result = tail.then(work)
    tail = result.catch(() => {})
    return result
  }
  async function cleanup() {
    await mkdir(root, { recursive: true, mode: 0o700 })
    const now = Date.now()
    let used = 0
    for (const name of await readdir(root)) {
      if (!uuid.test(name)) continue
      const path = join(root, name)
      const meta = await optionalJson(join(path, 'capture.json'))
      if (!meta) continue
      const complete = await optionalJson(join(path, 'complete.json'))
      if (now - meta.createdAt > (complete ? retentionMs : incompleteMs)) {
        await rm(path, { recursive: true })
        streams.delete(name)
        continue
      }
      for (const file of await readdir(path))
        used += (await stat(join(path, file))).size
    }
    diskBytes = used
    lastCleanup = now
    return used
  }
  async function accept(value) {
    const used = await cleanup()
    const dir = join(root, value.captureId)
    const metaPath = join(dir, 'capture.json')
    const meta = await optionalJson(metaPath)
    if (
      meta &&
      (meta.schemaVersion === '1.1.0' ||
        meta.game !== value.game ||
        meta.total !== value.total)
    )
      return json({ error: 'capture-conflict' }, 409)
    const path = join(dir, `${value.index}.json`)
    const serialized = JSON.stringify(value)
    const previous = await optionalJson(path)
    if (previous && hash(JSON.stringify(previous)) !== hash(serialized))
      return json({ error: 'chunk-conflict' }, 409)
    if (!previous) {
      let captureBytes = 0
      if (meta)
        for (const file of await readdir(dir))
          captureBytes += (await stat(join(dir, file))).size
      if (captureBytes + Buffer.byteLength(serialized) > MAX_CAPTURE_BYTES)
        return json({ error: 'capture-too-large' }, 413)
      // Reserve metadata and completion-report space as well as the chunk itself.
      if (used + Buffer.byteLength(serialized) + 65536 > maxDiskBytes)
        return json({ error: 'storage-full' }, 507)
      await mkdir(dir, { recursive: true, mode: 0o700 })
      if (!meta)
        await atomicJson(metaPath, {
          captureId: value.captureId,
          game: value.game,
          total: value.total,
          createdAt: Date.now(),
        })
      await atomicJson(path, value)
      diskBytes = null
    }
    const files = new Set(await readdir(dir))
    const missing = Array.from(
      { length: value.total },
      (_, index) => index
    ).filter(index => !files.has(`${index}.json`))
    if (!missing.length && !(await optionalJson(join(dir, 'complete.json')))) {
      const manifest = await optionalJson(join(dir, `${value.total - 1}.json`))
      const hashes = []
      for (let index = 0; index < value.total; index++)
        hashes.push(
          hash(JSON.stringify(await optionalJson(join(dir, `${index}.json`))))
        )
      await atomicJson(join(dir, 'complete.json'), {
        captureId: value.captureId,
        game: value.game,
        total: value.total,
        receivedAt: new Date().toISOString(),
        manifest: manifest.data,
        hashes,
      })
    }
    return json(
      {
        captureId: value.captureId,
        index: value.index,
        complete: !missing.length,
        missing,
      },
      previous ? 200 : 201
    )
  }
  async function acceptStream(value) {
    if (diskBytes === null || Date.now() - lastCleanup > 60000) await cleanup()
    const dir = join(root, value.captureId)
    const metaPath = join(dir, 'capture.json')
    let state = streams.get(value.captureId)
    if (!state) {
      const meta = await optionalJson(metaPath)
      if (meta && (meta.schemaVersion !== '1.1.0' || meta.game !== value.game))
        return json({ error: 'capture-conflict' }, 409)
      state = { meta, files: new Set(), bytes: 0 }
      if (meta) {
        for (const file of await readdir(dir)) {
          state.bytes += (await stat(join(dir, file))).size
          if (/^\d+\.json$/.test(file))
            state.files.add(Number(file.split('.')[0]))
        }
      }
      if (meta) streams.set(value.captureId, state)
    }
    if (state.meta?.game && state.meta.game !== value.game)
      return json({ error: 'capture-conflict' }, 409)
    if (
      state.meta?.total != null &&
      (value.index >= state.meta.total ||
        (value.kind === 'manifest' && value.index !== state.meta.total - 1) ||
        (value.kind === 'record' && value.index === state.meta.total - 1))
    )
      return json({ error: 'capture-conflict' }, 409)
    if (
      value.kind === 'manifest' &&
      [...state.files].some(index => index > value.index)
    )
      return json({ error: 'capture-conflict' }, 409)
    const path = join(dir, `${value.index}.json`)
    const serialized = JSON.stringify(value)
    const previous = state.files.has(value.index)
      ? await optionalJson(path)
      : null
    if (previous && hash(JSON.stringify(previous)) !== hash(serialized))
      return json({ error: 'chunk-conflict' }, 409)
    if (!previous) {
      const size = Buffer.byteLength(serialized) + 1
      if (state.bytes + size + 65536 > MAX_CAPTURE_BYTES)
        return json({ error: 'capture-too-large' }, 413)
      if (diskBytes + size + 65536 > maxDiskBytes)
        return json({ error: 'storage-full' }, 507)
      await mkdir(dir, { recursive: true, mode: 0o700 })
      if (!state.meta) {
        state.meta = {
          schemaVersion: '1.1.0',
          captureId: value.captureId,
          game: value.game,
          total: null,
          createdAt: Date.now(),
        }
        await atomicJson(metaPath, state.meta)
        const metaBytes = (await stat(metaPath)).size
        diskBytes += metaBytes
        state.bytes += metaBytes
      }
      await atomicJson(path, value)
      streams.set(value.captureId, state)
      state.files.add(value.index)
      state.bytes += size
      diskBytes += size
    }
    // The last packet supplies the final index. If it is lost, total remains
    // unknown and the capture is explicitly incomplete. Never infer success.
    if (value.kind === 'manifest' && state.meta.total === null) {
      const before = (await stat(metaPath)).size
      const updated = { ...state.meta, total: value.index + 1 }
      await atomicJson(metaPath, updated)
      state.meta = updated
      const delta = (await stat(metaPath)).size - before
      state.bytes += delta
      diskBytes += delta
    }
    const total = state.meta.total
    const missing =
      total === null
        ? null
        : Array.from({ length: total }, (_, index) => index).filter(
            index => !state.files.has(index)
          )
    const complete = missing !== null && missing.length === 0
    if (complete && !(await optionalJson(join(dir, 'complete.json')))) {
      const manifest = await optionalJson(join(dir, `${total - 1}.json`))
      await atomicJson(join(dir, 'complete.json'), {
        captureId: value.captureId,
        game: value.game,
        total,
        receivedAt: new Date().toISOString(),
        manifest: manifest.data,
      })
      const extra = (await stat(join(dir, 'complete.json'))).size
      diskBytes += extra
      state.bytes += extra
    }
    return json(
      { captureId: value.captureId, index: value.index, complete, missing },
      previous ? 200 : 201
    )
  }
  return {
    cleanup: () => exclusive(cleanup),
    async fetch(request) {
      const url = new URL(request.url)
      if (url.pathname === '/health' && request.method === 'GET')
        return json({ status: 'ok', schemaVersions: ['1.0.0', '1.1.0'] })
      if (url.pathname !== '/diagnostics/v1/chunks')
        return json({ error: 'not-found' }, 404)
      if (request.method !== 'POST')
        return json({ error: 'method-not-allowed' }, 405)
      if (
        !sameToken(
          request.headers.get('authorization') || '',
          `Bearer ${token}`
        )
      )
        return json({ error: 'unauthorized' }, 401)
      if (
        (request.headers.get('content-type') || '')
          .split(';')[0]
          .trim()
          .toLowerCase() !== 'application/json'
      )
        return json({ error: 'content-type' }, 415)
      let value
      let receivedBytes = 0
      try {
        const reader = request.body?.getReader()
        if (!reader) return json({ error: 'invalid-json' }, 400)
        const parts = []
        while (true) {
          const { done, value: part } = await reader.read()
          if (done) break
          receivedBytes += part.byteLength
          if (receivedBytes > MAX_CHUNK_BYTES) {
            await reader.cancel()
            return json({ error: 'chunk-too-large' }, 413)
          }
          parts.push(Buffer.from(part))
        }
        value = JSON.parse(Buffer.concat(parts).toString('utf8'))
      } catch {
        return json({ error: 'invalid-json' }, 400)
      }
      const streaming = validateStream(value)
      if (streaming && receivedBytes > MAX_STREAM_PACKET_BYTES)
        return json({ error: 'stream-packet-too-large' }, 413)
      if (!streaming && !validateChunk(value))
        return json({ error: 'invalid-chunk' }, 400)
      try {
        return await exclusive(() =>
          streaming ? acceptStream(value) : accept(value)
        )
      } catch {
        // Do not leak payloads, tokens, filesystem paths, or OS error messages.
        return json({ error: 'storage-failure' }, 503)
      }
    },
  }
}

if (import.meta.main) {
  const token = process.env.DIAGNOSTICS_TOKEN
  const directory = process.env.DIAGNOSTICS_DIRECTORY || './diagnostics-data'
  const host = process.env.DIAGNOSTICS_HOST || '127.0.0.1'
  const port = Number(process.env.DIAGNOSTICS_PORT || 8787)
  const receiver = createReceiver({ directory, token })
  await receiver.cleanup()
  const server = Bun.serve({
    hostname: host,
    port,
    maxRequestBodySize: MAX_CHUNK_BYTES,
    idleTimeout: 30,
    fetch: receiver.fetch,
  })
  const timer = setInterval(
    () =>
      receiver
        .cleanup()
        .catch(() => console.error('Diagnostics cleanup failed')),
    3600000
  )
  process.on('SIGINT', () => {
    clearInterval(timer)
    server.stop()
  })
  console.log(`Diagnostics receiver listening on ${host}:${server.port}`)
}
