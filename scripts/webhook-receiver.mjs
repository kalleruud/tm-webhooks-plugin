#!/usr/bin/env node
// Small LAN test receiver. Uses only Node's standard library.
import { createServer } from 'node:http'
import { timingSafeEqual } from 'node:crypto'
import { mkdir, open, readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { parseArgs } from 'node:util'

const { values } = parseArgs({
  options: {
    host: { type: 'string', default: '127.0.0.1' },
    port: { type: 'string', default: '8787' },
    'data-dir': { type: 'string', default: '.local/webhook-receiver' },
    'token-file': { type: 'string' },
    help: { type: 'boolean', default: false },
  },
})
if (values.help) {
  console.log(
    'node scripts/webhook-receiver.mjs [--host 0.0.0.0] [--port 8787] [--data-dir PATH] [--token-file PATH]'
  )
  process.exit(0)
}
const token = values['token-file']
  ? (await readFile(values['token-file'], 'utf8')).trim()
  : ''
if (values['token-file'] && !token)
  throw new Error('Token file must not be empty')
const expectedAuthorization = Buffer.from('Bearer ' + token)
function authorized(req) {
  if (!token) return true
  const actual = Buffer.from(req.headers.authorization ?? '')
  return (
    actual.length === expectedAuthorization.length &&
    timingSafeEqual(actual, expectedAuthorization)
  )
}
const port = Number(values.port)
if (!Number.isInteger(port) || port < 0 || port > 65535)
  throw new Error('Invalid port')
const directory = resolve(values['data-dir'])
await mkdir(directory, { recursive: true })
const file = resolve(
  directory,
  `${new Date().toISOString().replaceAll(':', '-')}-${process.pid}.jsonl`
)
const output = await open(file, 'ax', 0o600)
const diagnosticFile = file.replace(/\.jsonl$/, '.diagnostics.jsonl')
let diagnosticOutput
let diagnosticReceived = 0
const recentDiagnostics = []
const recent = []
let writes = Promise.resolve()
let received = 0
const maxBytes = 1024 * 1024

function json(res, status, body) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  })
  res.end(JSON.stringify(body, null, 2) + '\n')
}

async function readBody(req) {
  let size = 0
  const chunks = []
  // Continue draining oversized bodies so the client receives a clean 413.
  for await (const chunk of req) {
    size += chunk.length
    if (size <= maxBytes) chunks.push(chunk)
  }
  if (size > maxBytes)
    throw Object.assign(new Error('Payload exceeds 1 MiB'), { status: 413 })
  try {
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (!body || Array.isArray(body) || typeof body !== 'object')
      throw new Error()
    return body
  } catch {
    throw Object.assign(new Error('Expected a JSON object'), { status: 400 })
  }
}

const server = createServer(async (req, res) => {
  try {
    if (req.method === 'GET' && req.url === '/health') {
      json(res, 200, {
        status: 'ok',
        received,
        file,
        diagnosticReceived,
        diagnosticFile,
      })
    } else if (req.method === 'GET' && req.url === '/events') {
      json(res, 200, recent)
    } else if (req.method === 'GET' && req.url === '/diagnostics') {
      json(res, 200, recentDiagnostics)
    } else if (
      req.method === 'POST' &&
      ['/api/webhook', '/api/diagnostics'].includes(req.url)
    ) {
      const diagnostic = req.url === '/api/diagnostics'
      if (!authorized(req)) {
        req.resume()
        res.setHeader('WWW-Authenticate', 'Bearer')
        json(res, 401, { error: 'Unauthorized' })
        return
      }
      const payload = await readBody(req)
      const record = {
        receivedAt: new Date().toISOString(),
        headers: {
          event_type: req.headers.event_type,
          'event-id': req.headers['event-id'],
          'event-sequence': req.headers['event-sequence'],
        },
        payload,
      }
      // Serialize disk writes; acknowledge only after saving. Keep retries intact.
      const write = writes.then(async () => {
        if (diagnostic && !diagnosticOutput)
          diagnosticOutput = await open(diagnosticFile, 'ax', 0o600)
        await (diagnostic ? diagnosticOutput : output).appendFile(
          JSON.stringify(record) + '\n'
        )
      })
      writes = write.catch(() => {})
      await write
      if (diagnostic) {
        diagnosticReceived++
        recentDiagnostics.push(record)
        if (recentDiagnostics.length > 10) recentDiagnostics.shift()
        console.log(
          `[diagnostic] #${diagnosticReceived} sequence=${payload.sequence ?? '?'}`
        )
        res.writeHead(204)
        res.end()
        return
      }
      received++
      recent.push(record)
      if (recent.length > 100) recent.shift()
      console.log(
        `[${record.receivedAt}] #${received} ${payload.type ?? 'unknown'} sequence=${payload.sequence ?? '?'} eventId=${payload.eventId ?? '?'}`
      )
      console.log(JSON.stringify(payload, null, 2))
      res.writeHead(204)
      res.end()
    } else {
      json(res, 404, {
        error:
          'Use POST /api/webhook, GET /health, or GET /events (latest 100 deliveries)',
      })
    }
  } catch (error) {
    if (!error.status) console.error('Receiver error:', error.message)
    if (!res.headersSent)
      json(res, error.status ?? 503, {
        error: error.status
          ? error.message
          : 'Unable to save delivery; retry later',
      })
    else res.end()
  }
})
server.requestTimeout = 10000
server.maxConnections = 64
server.on('error', async error => {
  console.error(error.message)
  await output.close()
  if (diagnosticOutput) await diagnosticOutput.close()
  process.exit(1)
})
server.listen(port, values.host, () => {
  console.log(
    `Receiver: http://${values.host}:${server.address().port}/api/webhook`
  )
  console.log(`Session file: ${file}`)
  console.log(
    'GET /events returns the latest 100 deliveries. Authorization headers are never saved. Ctrl+C stops the receiver.'
  )
})
function stop() {
  server.close(async () => {
    await writes
    await output.close()
    if (diagnosticOutput) await diagnosticOutput.close()
  })
  server.closeIdleConnections()
}
process.once('SIGINT', stop)
process.once('SIGTERM', stop)
