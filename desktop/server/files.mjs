import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

export const semver = createRequire(import.meta.url)('../../auto-switch/vendor/node-semver');
export const digest = value => crypto.createHash('sha256').update(value ?? '<absent>').digest('hex');
export const projectId = value => digest(value).slice(0, 20);
export const inside = (root, file) => file === root || file.startsWith(root + path.sep);
export class AppError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; }
}

export async function readRegular(file, limit = 1024 * 1024) {
  let handle;
  try {
    handle = await fs.open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > limit) throw new AppError('文件类型或大小不受支持');
    const buffer = Buffer.alloc(limit + 1);
    let size = 0;
    while (size < buffer.length) {
      const { bytesRead } = await handle.read(buffer, size, buffer.length - size, null);
      if (!bytesRead) break;
      size += bytesRead;
    }
    if (size > limit) throw new AppError('文件超过大小限制');
    return buffer.toString('utf8', 0, size);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    if (error.code === 'ELOOP') throw new AppError('不能读取或覆盖符号链接文件');
    throw error;
  } finally { await handle?.close(); }
}

export async function writeAtomic(file, text, expected) {
  const previous = await readRegular(file);
  if (expected !== undefined && digest(previous) !== expected) throw new AppError('文件已被外部修改，请刷新后重试', 409);
  let mode = 0o600;
  try { mode = (await fs.stat(file)).mode & 0o777; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  const temp = path.join(path.dirname(file), `.gui-nvm-${crypto.randomUUID()}.tmp`);
  await fs.writeFile(temp, text, { flag: 'wx', mode });
  try {
    // Recheck immediately before replacing, including symlinks introduced during a write.
    if (digest(await readRegular(file)) !== digest(previous)) throw new AppError('文件已被外部修改，请刷新后重试', 409);
    await fs.rename(temp, file);
  } finally { await fs.unlink(temp).catch(() => {}); }
}

export function parseDeclaration(text) {
  const lines = text.split(/\r?\n/).map(line => line.split('#')[0].trim()).filter(Boolean);
  const versions = lines.filter(line => !line.includes('='));
  if (versions.length !== 1 || /\s|[\x00-\x1f\x7f]/.test(versions[0])) throw new AppError('版本声明无效');
  return versions[0];
}

export async function findDeclaration(directory) {
  let cursor = directory;
  while (true) {
    for (const name of ['.nvmrc', '.node-version', 'package.json']) {
      const file = path.join(cursor, name);
      const text = await readRegular(file, name === 'package.json' ? 1048576 : 8192);
      if (text === null) continue;
      if (name === 'package.json') {
        let json;
        try { json = JSON.parse(text); } catch { throw new AppError('package.json 格式错误'); }
        if (json?.engines?.node === undefined) continue;
        if (typeof json.engines.node !== 'string' || !semver.validRange(json.engines.node)) throw new AppError('engines.node 范围无效');
        return { requested: json.engines.node, source: name, file, inherited: cursor !== directory };
      }
      return { requested: parseDeclaration(text), source: name, file, inherited: cursor !== directory };
    }
    const parent = path.dirname(cursor);
    if (parent === cursor) return null;
    cursor = parent;
  }
}

export async function resolveVersion(requested, installed, nvmDir, depth = 0) {
  if (!requested || depth > 8) return null;
  if (/^(node|stable)$/.test(requested)) return installed[0]?.version ?? null;
  if (requested === 'system') return 'system';
  if (requested.startsWith('lts/')) {
    const name = requested.slice(4).toLowerCase();
    const lts = installed.filter(item => item.lts && (name === '*' || String(item.lts).toLowerCase() === name));
    return lts[0]?.version ?? null;
  }
  if (/^[a-z][a-z0-9_-]*$/i.test(requested)) {
    const alias = await readRegular(path.join(nvmDir, 'alias', requested), 8192);
    return alias ? resolveVersion(alias.trim(), installed, nvmDir, depth + 1) : null;
  }
  const range = semver.validRange(requested);
  return range ? installed.find(item => semver.satisfies(item.version, range))?.version ?? null : null;
}

export async function projectRecord(directory, installed, nvmDir, phaseOf) {
  const id = projectId(directory);
  const manifest = await readRegular(path.join(directory, 'package.json')).catch(() => null);
  let name = path.basename(directory);
  try { const json = JSON.parse(manifest); if (typeof json?.name === 'string' && json.name.length < 120) name = json.name; } catch {}
  const base = { id, name, path: directory };
  try {
    const declaration = await findDeclaration(directory);
    if (!declaration) return { ...base, requested: '', resolved: null, source: '', status: 'unconfigured' };
    const resolved = await resolveVersion(declaration.requested, installed, nvmDir);
    return { ...base, ...declaration, resolved, status: !resolved ? 'missing' : phaseOf(resolved).phase === 'EOL' ? 'eol' : 'ready' };
  } catch (error) { return { ...base, requested: '', resolved: null, source: '', status: 'invalid', error: error.message }; }
}

export const EXCLUSIONS = new Set(['node_modules', '.git', '.pnpm', '.yarn', 'dist', 'build', 'target', 'coverage', 'output', '.next', '.nuxt', '.cache', 'vendor', 'Pods', 'DerivedData', '.venv', 'venv', 'fixtures', 'mocks', 'Library', '.Trash']);

export async function discover(roots, { signal, onProgress = () => {}, maxDirectories = 50000 } = {}) {
  const queue = [...roots];
  const seen = new Set();
  const projects = [];
  const errors = [];
  let visited = 0;
  let limited = false;
  while (queue.length) {
    if (signal?.aborted) throw new AppError('扫描已取消', 409);
    if (visited >= maxDirectories) { limited = true; break; }
    const directory = queue.shift();
    if (seen.has(directory)) continue;
    seen.add(directory);
    let entries;
    try { entries = await fs.readdir(directory, { withFileTypes: true }); }
    catch (error) { errors.push({ path: directory, code: error.code }); continue; }
    visited += 1;
    if (entries.some(entry => entry.isFile() && ['package.json', '.nvmrc', '.node-version'].includes(entry.name))) projects.push(directory);
    for (const entry of entries) {
      if (entry.isDirectory() && !entry.name.startsWith('.') && !EXCLUSIONS.has(entry.name)) queue.push(path.join(directory, entry.name));
    }
    if (visited % 25 === 0) { onProgress({ visited, found: projects.length }); await new Promise(resolve => setImmediate(resolve)); }
  }
  onProgress({ visited, found: projects.length });
  return { projects: [...new Set(projects)].sort(), errors: errors.slice(0, 100), visited, limited };
}

export async function makePreview(project, destination, requested, installed, nvmDir) {
  if (!['.nvmrc', '.node-version', 'package.json'].includes(destination)) throw new AppError('不支持的声明文件');
  if (typeof requested !== 'string' || !requested.trim() || requested.length > 4096 || /[\x00-\x1f\x7f]/.test(requested)) throw new AppError('版本值无效');
  requested = requested.trim();
  if (destination !== 'package.json' && !/^(v?\d+(?:\.\d+){0,2}|lts\/(?:\*|[a-z]+)|[a-z][a-z0-9_-]*)$/i.test(requested)) throw new AppError('此文件只接受版本号或 nvm 别名');
  if (destination === 'package.json' && !semver.validRange(requested)) throw new AppError('engines.node 需要有效的版本范围');
  const resolved = await resolveVersion(requested, installed, nvmDir);
  if (!resolved || resolved === 'system') throw new AppError('目标版本尚未安装，请先到 Node 版本库安装');
  const real = await fs.realpath(project.path);
  if (real !== project.path) throw new AppError('项目路径已变化，请重新扫描', 409);
  const file = path.join(project.path, destination);
  const before = await readRegular(file);
  let after = requested + '\n';
  if (destination === 'package.json') {
    if (before === null) throw new AppError('项目没有 package.json');
    let json;
    try { json = JSON.parse(before); } catch { throw new AppError('package.json 格式错误'); }
    if (!json || Array.isArray(json) || typeof json !== 'object') throw new AppError('package.json 必须是对象');
    const indent = before.match(/\n([ \t]+)"/)?.[1] || '  ';
    json.engines = { ...(typeof json.engines === 'object' && json.engines !== null ? json.engines : {}), node: requested };
    after = JSON.stringify(json, null, indent) + '\n';
  }
  const shadowed = destination === 'package.json'
    ? ['.nvmrc', '.node-version'] : destination === '.node-version' ? ['.nvmrc'] : [];
  for (const name of shadowed) if (await readRegular(path.join(project.path, name), 8192) !== null) throw new AppError(`${name} 的优先级更高，请修改该文件`);
  return { file, before, after, expected: digest(before), resolved, requested, destination };
}
