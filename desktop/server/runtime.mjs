import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { AppError, readRegular, writeAtomic, semver, digest } from './files.mjs';
import { fetchIndex, networkEnvironment } from './network.mjs';

const initialSchedule = JSON.parse(await fs.readFile(new URL('./release-schedule.json', import.meta.url), 'utf8'));
const nvmSource = fileURLToPath(new URL('../../nvm.sh', import.meta.url));
export function releasePhase(version, schedule = initialSchedule, today = new Date().toISOString().slice(0, 10)) {
  const major = String(version).match(/^v?(\d+)\./)?.[1];
  const entry = schedule['v' + major];
  if (!entry) return { phase: 'Unknown', description: '支持状态待同步', codename: '', lts: false };
  const phase = today >= entry.end ? 'EOL' : entry.maintenance && today >= entry.maintenance ? 'Maintenance LTS' : entry.lts && today >= entry.lts ? 'LTS' : 'Current';
  return { phase, description: { EOL: '已停止支持', 'Maintenance LTS': '维护期', LTS: '长期支持', Current: '新特性 · 非 LTS' }[phase], codename: entry.codename || '', lts: Boolean(entry.lts && today >= entry.lts), supportEnd: entry.end };
}

export class Runtime {
  constructor({ nvmDir = process.env.NVM_DIR || path.join(os.homedir(), '.nvm'), dataDir, fetcher = fetchIndex, installer } = {}) {
    this.nvmDir = path.resolve(nvmDir);
    this.dataDir = dataDir;
    this.fetcher = fetcher;
    this.installer = installer;
    this.schedule = initialSchedule;
    this.catalog = [];
    this.catalogAt = null;
    this.catalogError = null;
    this.tasks = [];
    this.active = null;
  }
  phaseOf(version) { return releasePhase(version, this.schedule); }
  async installed() {
    let entries;
    try { entries = await fs.readdir(path.join(this.nvmDir, 'versions/node'), { withFileTypes: true }); }
    catch (e) { if (e.code === 'ENOENT') return []; throw e; }
    const versions = [];
    for (const entry of entries) {
      if (!entry.isDirectory() || !/^v\d+\.\d+\.\d+$/.test(entry.name)) continue;
      try { if (!(await fs.stat(path.join(this.nvmDir, 'versions/node', entry.name, 'bin/node'))).isFile()) continue; }
      catch { continue; }
      const details = this.phaseOf(entry.name);
      versions.push({ version: entry.name, ...details, lts: details.lts ? details.codename || true : false, installed: true });
    }
    return versions.sort((a, b) => semver.rcompare(a.version, b.version));
  }
  async defaultVersion() {
    const text = await readRegular(path.join(this.nvmDir, 'alias/default'), 8192).catch(() => null);
    return { value: text?.trim() || '', expected: digest(text) };
  }
  async setDefault(version, expected) {
    if (!(await this.installed()).some(item => item.version === version)) throw new AppError('只能选择已安装的 Node 版本');
    if (typeof expected !== 'string') throw new AppError('缺少配置校验值');
    await fs.mkdir(path.join(this.nvmDir, 'alias'), { recursive: true });
    await writeAtomic(path.join(this.nvmDir, 'alias/default'), version + '\n', expected);
  }
  async loadCache() {
    try {
      const data = JSON.parse(await readRegular(path.join(this.dataDir, 'releases.json'), 8 * 1024 * 1024));
      this.catalog = this.validateCatalog(data.rows);
      this.catalogAt = data.at;
    } catch {}
  }
  validateCatalog(rows) {
    if (!Array.isArray(rows) || !rows.length || rows.length > 10000) throw new AppError('版本索引格式无效');
    return rows.filter(row => /^v\d+\.\d+\.\d+$/.test(row.version) && /^\d{4}-\d{2}-\d{2}$/.test(row.date) && Array.isArray(row.files)).map(row => ({ version: row.version, date: row.date, lts: typeof row.lts === 'string' ? row.lts : false, files: row.files.filter(item => typeof item === 'string') })).sort((a, b) => semver.rcompare(a.version, b.version));
  }
  async syncCatalog() {
    if (this.syncing) return this.syncing;
    this.syncing = (async () => {
      try {
        this.syncController = new AbortController();
        const response = await this.fetcher('https://nodejs.org/dist/index.json', { signal: AbortSignal.any([this.syncController.signal, AbortSignal.timeout(20000)]) });
        if (!response.ok) throw new Error('HTTP ' + response.status);
        const text = await response.text();
        if (text.length > 8 * 1024 * 1024) throw new Error('版本索引过大');
        const catalog = this.validateCatalog(JSON.parse(text));
        if (!catalog.length) throw new Error('版本索引为空');
        this.catalog = catalog;
        this.catalogAt = new Date().toISOString();
        this.catalogError = null;
        await writeAtomic(path.join(this.dataDir, 'releases.json'), JSON.stringify({ rows: catalog, at: this.catalogAt }));
      } catch (error) { this.catalogError = `同步失败：${error.message}`; }
      return this.catalog;
    })();
    try { return await this.syncing; } finally { this.syncing = null; }
  }
  releases(installed) {
    const versions = new Set(installed.map(item => item.version));
    const file = (os.platform() === 'darwin' ? 'osx' : os.platform()) + '-' + os.arch() + (os.platform() === 'darwin' ? '-tar' : '');
    return this.catalog.map(item => ({ ...item, ...this.phaseOf(item.version), installed: versions.has(item.version), compatible: item.files.includes(file) }));
  }
  async install(version) {
    if (!/^v\d+\.\d+\.\d+$/.test(version)) throw new AppError('版本号无效');
    if (this.active || this.starting) throw new AppError('已有安装任务正在运行', 409);
    this.starting = true;
    try {
    const installed = await this.installed();
    if (this.closed) throw new AppError('本地服务正在关闭', 503);
    if (installed.some(item => item.version === version)) throw new AppError('此版本已安装', 409);
    const release = this.releases(installed).find(item => item.version === version);
    if (!release?.compatible) throw new AppError('此版本没有适用本机架构的官方二进制包');
    const task = { id: crypto.randomUUID(), version, state: 'running', startedAt: new Date().toISOString(), log: '', phase: '下载并校验' };
    this.tasks.unshift(task);
    this.tasks = this.tasks.slice(0, 30);
    const controller = new AbortController();
    const operation = this.runInstall(task, controller.signal);
    this.active = { task, controller, operation };
    operation.finally(() => { this.active = null; });
    return task;
    } finally { this.starting = false; }
  }
  async runInstall(task, signal) {
    let staging;
    try {
      await fs.mkdir(this.nvmDir, { recursive: true });
      staging = await fs.mkdtemp(path.join(this.nvmDir, '.gui-nvm-install-'));
      const log = chunk => { task.log = (task.log + chunk.toString().replace(/\x1b\[[0-9;]*[A-Za-z]/g, '')).slice(-16000); };
      if (this.installer) await this.installer({ version: task.version, staging, signal, log });
      else {
        const proxyEnvironment = await networkEnvironment();
        await new Promise((resolve, reject) => {
        const env = { HOME: os.homedir(), PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', NVM_DIR: staging, TERM: 'dumb', NVM_NO_COLORS: '1' };
        Object.assign(env, proxyEnvironment);
        const child = spawn('/bin/bash', ['--noprofile', '--norc', '-c', '. "$1" --no-use; nvm install -b --skip-default-packages --no-progress "$2"', 'gui-nvm-install', nvmSource, task.version], { env, cwd: staging, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
        child.stdout.on('data', log); child.stderr.on('data', log);
        let killTimer;
        const stop = () => {
          try { process.kill(-child.pid, 'SIGTERM'); } catch {}
          killTimer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 3000);
          killTimer.unref();
        };
        signal.addEventListener('abort', stop, { once: true });
        if (signal.aborted) stop();
        child.on('error', reject);
        child.on('close', code => {
          clearTimeout(killTimer);
          signal.removeEventListener('abort', stop);
          if (signal.aborted) reject(new AppError('安装已取消'));
          else code === 0 ? resolve() : reject(new AppError('安装失败，请查看任务日志'));
        });
        });
      }
      if (signal.aborted) throw new AppError('安装已取消');
      const source = path.join(staging, 'versions/node', task.version);
      if (!(await fs.stat(path.join(source, 'bin/node'))).isFile()) throw new AppError('安装结果校验失败');
      const target = path.join(this.nvmDir, 'versions/node', task.version);
      await fs.mkdir(path.dirname(target), { recursive: true });
      try { await fs.lstat(target); throw new AppError('目标版本已被其他进程安装，请刷新'); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      await fs.rename(source, target);
      task.state = 'complete'; task.phase = '安装完成';
    } catch (error) { task.state = signal.aborted ? 'cancelled' : 'failed'; task.error = error.message; task.phase = error.message; }
    finally { task.endedAt = new Date().toISOString(); if (staging) await fs.rm(staging, { recursive: true, force: true }).catch(error => { task.log += `\n临时目录清理失败：${error.message}`; }); }
  }
  cancel(id) { if (this.active?.task.id !== id) throw new AppError('任务未在运行'); this.active.controller.abort(); }
  async close() { this.closed = true; this.syncController?.abort(); await this.syncing; if (this.active) { this.active.controller.abort(); await this.active.operation; } }
}
