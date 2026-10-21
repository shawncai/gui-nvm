'use strict'

// Private line protocol for nvm-auto.zsh; never import a project's code.
// package <path> <installed-version>... | range <range> <installed-version>...
// stdout: status, requested range, resolved version or diagnostic (three lines).
const fs = require('fs')
const semver = require('./vendor/node-semver')

const MAX_PACKAGE_BYTES = 1024 * 1024
const MAX_RANGE_LENGTH = 4096
const UNSAFE_TEXT = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/
const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key)

function response(status, range, detail) {
  return [status, range || '', detail || '']
}

function failure(message) {
  return response('error', '', message)
}

function resolveRange(range, installed) {
  if (typeof range !== 'string') return failure('engines.node must be a string')
  if (UNSAFE_TEXT.test(range)) return failure('Node version range contains control characters')
  range = range.trim()
  if (!range) return failure('Node version range must not be empty')
  if (range.length > MAX_RANGE_LENGTH) return failure('Node version range exceeds 4096 characters')
  if (semver.validRange(range) === null) return failure('Invalid Node semver range')

  const stable = installed.map(version => {
    if (UNSAFE_TEXT.test(version)) throw new Error('Unsafe installed version')
    const parsed = semver.parse(version)
    return parsed && parsed.prerelease.length === 0 ? parsed.version : null
  }).filter(Boolean)
  const selected = semver.maxSatisfying(stable, range)
  return selected
    ? response('ok', range, 'v' + selected)
    : response('missing', range, 'No installed stable Node version satisfies this range')
}

function readPackage(file) {
  let descriptor
  try {
    // Reject directories/devices/FIFOs, and cap input before reading/parsing it.
    descriptor = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK)
    const info = fs.fstatSync(descriptor)
    if (!info.isFile()) return failure('package.json is not a regular file')
    if (info.size > MAX_PACKAGE_BYTES) return failure('package.json exceeds 1 MiB')
    const input = Buffer.alloc(MAX_PACKAGE_BYTES + 1)
    let size = 0
    let count
    do {
      count = fs.readSync(descriptor, input, size, input.length - size, null)
      size += count
    } while (count && size < input.length)
    if (size > MAX_PACKAGE_BYTES) return failure('package.json exceeds 1 MiB')
    let manifest
    try {
      manifest = JSON.parse(input.toString('utf8', 0, size))
    } catch (_) {
      return failure('package.json is not valid JSON')
    }
    if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
      return failure('package.json must contain a JSON object')
    }
    if (!own(manifest, 'engines') || !manifest.engines ||
        typeof manifest.engines !== 'object' || !own(manifest.engines, 'node')) {
      return response('none')
    }
    return { range: manifest.engines.node }
  } catch (_) {
    return failure('Cannot read package.json')
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor)
  }
}

function main(args) {
  const mode = args[0]
  if ((mode !== 'package' && mode !== 'range') || args.length < 2) {
    return failure('Usage: resolve.cjs package FILE VERSION... | range RANGE VERSION...')
  }
  let range = args[1]
  if (mode === 'package') {
    range = readPackage(range)
    if (Array.isArray(range)) return range
    range = range.range
  }
  return resolveRange(range, args.slice(2))
}

let result
try {
  result = main(process.argv.slice(2))
} catch (_) {
  result = failure('Cannot resolve installed Node versions')
}
process.stdout.write(result.join('\n') + '\n')
