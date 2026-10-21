'use strict'

const assert = require('assert')
const fs = require('fs')
const os = require('os')
const path = require('path')
const childProcess = require('child_process')
const resolver = path.join(__dirname, 'resolve.cjs')
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'nvm-auto-resolver-'))
const manifest = path.join(scratch, '中文 package.json')
const versions = ['v16.16.0', 'v20.19.5', 'v22.20.0', 'v22.22.3', 'v24.0.0-rc.1', 'v24.17.0']
let count = 0

function run(args) {
  const env = Object.assign({}, process.env)
  delete env.NODE_OPTIONS
  delete env.NODE_PATH
  const result = childProcess.spawnSync(process.execPath, [resolver].concat(args), {
    encoding: 'utf8', env, timeout: 5000,
  })
  assert.ifError(result.error)
  assert.strictEqual(result.status, 0, result.stderr)
  assert.strictEqual(result.stderr, '')
  assert.ok(result.stdout.endsWith('\n'))
  const lines = result.stdout.slice(0, -1).split('\n')
  assert.strictEqual(lines.length, 3, 'Every result must have exactly three lines')
  count += 1
  return lines
}

function range(value, installed) {
  return run(['range', value].concat(installed || versions))
}

function packageResult(value, raw) {
  fs.writeFileSync(manifest, raw ? value : JSON.stringify(value))
  return run(['package', manifest].concat(versions))
}

try {
  const cases = [
    ['>=20 <23', 'v22.22.3'],
    ['^20.0.0', 'v20.19.5'],
    ['~22.20.0', 'v22.20.0'],
    ['16 || 20', 'v20.19.5'],
    ['22.x', 'v22.22.3'],
    ['22.x+build.1', 'v22.22.3'],
    ['22.22.3+build.1', 'v22.22.3'],
    ['20.19.5 - 22.22.3', 'v22.22.3'],
    ['*', 'v24.17.0'],
    ['v22.22.3', 'v22.22.3'],
    ['  >=22 <23  ', 'v22.22.3'],
  ]
  cases.forEach(([requirement, expected]) => {
    assert.deepStrictEqual(range(requirement), ['ok', requirement.trim(), expected])
  })
  assert.deepStrictEqual(range('>=20', ['v24.0.0-rc.1', 'garbage', 'v20.19.5']),
    ['ok', '>=20', 'v20.19.5'])
  assert.strictEqual(range('24.0.0-rc.1', ['v24.0.0-rc.1'])[0], 'missing')
  assert.strictEqual(range('>=99')[0], 'missing')
  assert.strictEqual(range('>=20', [])[0], 'missing')
  assert.strictEqual(range('lts/*')[0], 'error')
  assert.strictEqual(range('>=')[0], 'error')
  assert.strictEqual(range('')[0], 'error')
  assert.strictEqual(range('   ')[0], 'error')
  assert.strictEqual(range('2'.repeat(4097))[0], 'error')
  ;['\n', '\t', '\r', '\u001b', '\u007f', '\u0085', '\u2028', '\u2029'].forEach(control => {
    assert.strictEqual(range('>=20' + control)[0], 'error')
  })
  assert.strictEqual(range('*', ['v22.22.3\nforged'])[0], 'error')
  assert.strictEqual(run([])[0], 'error')
  assert.strictEqual(run(['unknown', '*'])[0], 'error')

  assert.deepStrictEqual(packageResult({ engines: { node: '^22.0.0' } }),
    ['ok', '^22.0.0', 'v22.22.3'])
  assert.deepStrictEqual(packageResult({ name: 'no-node-engine' }), ['none', '', ''])
  assert.deepStrictEqual(packageResult({ engines: { pnpm: '10' } }), ['none', '', ''])
  assert.deepStrictEqual(packageResult({ engines: null }), ['none', '', ''])
  assert.strictEqual(packageResult({ engines: { node: 22 } })[0], 'error')
  assert.strictEqual(packageResult({ engines: { node: null } })[0], 'error')
  assert.strictEqual(packageResult({ engines: { node: ['ok', 'injected', 'lines'] } })[0], 'error')
  assert.strictEqual(packageResult({ engines: { node: { value: '>=20' } } })[0], 'error')
  assert.strictEqual(packageResult({ engines: { node: '' } })[0], 'error')
  assert.strictEqual(packageResult({ engines: { node: '22\u0000' } })[0], 'error')
  assert.strictEqual(packageResult('{ invalid', true)[0], 'error')
  assert.strictEqual(packageResult('module.exports = {}', true)[0], 'error')
  assert.strictEqual(packageResult(null)[0], 'error')
  assert.strictEqual(packageResult([])[0], 'error')
  assert.strictEqual(packageResult('primitive')[0], 'error')
  assert.strictEqual(packageResult({ engines: { node: '>=99' } })[0], 'missing')
  assert.strictEqual(run(['package', path.join(scratch, 'missing.json')])[0], 'error')
  assert.strictEqual(run(['package', scratch])[0], 'error')
  assert.strictEqual(packageResult(' '.repeat(1024 * 1024 + 1), true)[0], 'error')

  // JSON properties and project modules must remain inert data.
  const marker = path.join(scratch, 'must-not-exist')
  fs.writeFileSync(path.join(scratch, 'index.js'), 'require("fs").writeFileSync(' + JSON.stringify(marker) + ', "unsafe")')
  assert.deepStrictEqual(packageResult({ main: 'index.js', type: 'module', engines: { node: '22.x' },
    scripts: { preinstall: 'touch ' + marker } }), ['ok', '22.x', 'v22.22.3'])
  assert.strictEqual(fs.existsSync(marker), false)
  assert.strictEqual(packageResult('{"__proto__":{"engines":{"node":"22.x"}}}', true)[0], 'none')
  process.stdout.write('PASS: ' + count + ' resolver cases\n')
} finally {
  // All entries belong to this test's temporary directory.
  fs.readdirSync(scratch).forEach(entry => fs.unlinkSync(path.join(scratch, entry)))
  fs.rmdirSync(scratch)
}
