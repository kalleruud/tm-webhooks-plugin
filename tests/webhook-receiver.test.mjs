import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

async function start(directory) {
  const child = spawn(process.execPath, [
    fileURLToPath(new URL('../scripts/webhook-receiver.mjs', import.meta.url)),
    '--port',
    '0',
    '--data-dir',
    directory,
  ])
  let text = ''
  const url = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      child.kill()
      reject(new Error('Receiver startup timed out'))
    }, 5000)
    child.stdout.on('data', chunk => {
      text += chunk
      const match = text.match(/Receiver: (http:\/\/127\.0\.0\.1:\d+)\/webhook/)
      if (match) {
        clearTimeout(timeout)
        resolve(match[1])
      }
    })
    child.on('error', error => {
      clearTimeout(timeout)
      reject(error)
    })
    child.on('exit', code => {
      clearTimeout(timeout)
      reject(new Error(`Receiver exited: ${code}`))
    })
  })
  return {
    url,
    async stop() {
      const exit = once(child, 'exit')
      child.kill('SIGTERM')
      await exit
    },
  }
}

test('captures retries without credentials, rejects invalid input, and preserves prior sessions', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'tm-webhooks-receiver-'))
  let receiver
  try {
    receiver = await start(directory)
    const payload = JSON.parse(
      await readFile(new URL('fixtures/events.json', import.meta.url))
    )[0]
    const post = (body, headers = {}) =>
      fetch(`${receiver.url}/webhook`, { method: 'POST', headers, body })
    const headers = {
      'Content-Type': 'application/json',
      event_type: payload.type,
      'event-id': payload.eventId,
      'event-sequence': String(payload.sequence),
      Authorization: 'Bearer must-not-be-saved',
    }
    for (let i = 0; i < 2; i++)
      assert.equal((await post(JSON.stringify(payload), headers)).status, 204)
    assert.equal((await post('{')).status, 400)
    assert.equal((await post('[]')).status, 400)
    assert.equal((await post('x'.repeat(1024 * 1024 + 1))).status, 413)
    assert.equal((await fetch(`${receiver.url}/missing`)).status, 404)
    const health = await (await fetch(`${receiver.url}/health`)).json()
    assert.equal(health.received, 2)
    const recent = await (await fetch(`${receiver.url}/events`)).json()
    assert.equal(recent.length, 2)
    assert.deepEqual(recent[0].payload, payload)
    assert.equal(recent[0].headers['event-id'], payload.eventId)
    assert.equal(recent[1].payload.eventId, payload.eventId)
    const content = await readFile(health.file, 'utf8')
    assert.equal(content.trim().split('\n').length, 2)
    assert.ok(!content.includes('must-not-be-saved'))
    await receiver.stop()
    receiver = await start(directory)
    const second = await (await fetch(`${receiver.url}/health`)).json()
    assert.equal(second.received, 0)
    assert.notEqual(second.file, health.file)
    assert.equal((await readdir(directory)).length, 2)
    assert.equal(await readFile(health.file, 'utf8'), content)
  } finally {
    if (receiver) await receiver.stop()
    await rm(directory, { recursive: true, force: true })
  }
})
