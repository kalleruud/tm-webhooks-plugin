#!/usr/bin/env bun
import { readFile, readdir } from 'node:fs/promises'
import { resolve, join } from 'node:path'

const [command = 'list', directory = './diagnostics-data', first, second] =
  process.argv.slice(2)
const root = resolve(directory)
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
async function load(id) {
  if (!uuid.test(id || '')) throw new Error('Expected capture UUID')
  const dir = join(root, id)
  const meta = JSON.parse(await readFile(join(dir, 'capture.json'), 'utf8'))
  const records = []
  const missing = []
  let manifest = null
  for (let i = 0; i < meta.total; i++) {
    try {
      const chunk = JSON.parse(await readFile(join(dir, `${i}.json`), 'utf8'))
      if (chunk.kind === 'records') records.push(...chunk.data)
      else manifest = chunk.data
    } catch (error) {
      if (error.code === 'ENOENT') missing.push(i)
      else throw error
    }
  }
  return { ...meta, manifest, missing, records }
}
if (command === 'list') {
  for (const id of await readdir(root)) {
    if (!uuid.test(id)) continue
    const dump = await load(id)
    console.log(
      JSON.stringify({
        captureId: id,
        game: dump.game,
        status: dump.manifest?.status || 'incomplete',
        missing: dump.missing,
        records: dump.records.length,
      })
    )
  }
} else if (command === 'show') {
  console.log(JSON.stringify(await load(first), null, 2))
} else if (command === 'diff') {
  const a = await load(first),
    b = await load(second)
  // Paths describe the first route from GetApp; IDs are local to each capture.
  const byPath = dump =>
    new Map(
      dump.records.map(record => [
        record.path || record.id || record.kind,
        record,
      ])
    )
  const left = byPath(a),
    right = byPath(b)
  for (const path of new Set([...left.keys(), ...right.keys()])) {
    if (JSON.stringify(left.get(path)) !== JSON.stringify(right.get(path)))
      console.log(
        JSON.stringify({ path, before: left.get(path), after: right.get(path) })
      )
  }
} else
  throw new Error(
    'Usage: inspect.mjs list|show|diff <directory> [capture UUID] [capture UUID]'
  )
