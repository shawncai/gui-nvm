import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Runtime } from './runtime.mjs';
import { AppError, discover, projectId, projectRecord, makePreview, readRegular, writeAtomic } from './files.mjs';

export class Store {
  constructor({ dataDir = path.join(os.homedir(), 'Library/Application Support/gui-nvm'), nvmDir, roots, runtime } = {}) {
    this.dataDir = dataDir;
    this.runtime = runtime || new Runtime({ dataDir, nvmDir });
    this.initialRoots = roots;
    this.roots = [];
    this.paths = [];
    this.manualPaths = [];
    this.scan = { state: 'idle', visited: 0, found: 0, errors: [] };
    this.queue = Promise.resolve();
  }
  async init({ sync = true } = {}) {
    await fs.mkdir(this.dataDir, { recursive: true, mode: 0o700 });
    let previous;
    try { previous = JSON.parse(await readRegular(path.join(this.dataDir, 'state.json'))); } catch {}
    const candidates = this.initialRoots || previous?.roots || [fileURLToPath(new URL('../../../', import.meta.url))];
    for (const root of candidates) {
      try { const real = await this.directory(root); if (!this.roots.includes(real)) this.roots.push(real); } catch {}
    }
    this.paths = Array.isArray(previous?.projects) ? previous.projects.filter(p => typeof p === 'string' && path.isAbsolute(p)) : [];
    this.manualPaths = Array.isArray(previous?.manualPaths) ? previous.manualPaths.filter(p => typeof p === 'string' && path.isAbsolute(p)) : [];
    await this.runtime.loadCache();
    this.startScan();
    if (sync) this.runtime.syncCatalog();
  }
  transaction(fn) {
    const operation = this.queue.then(fn);
    this.queue = operation.catch(() => {});
    return operation;
  }
  async directory(value) {
    if (typeof value !== 'string' || !value.trim() || value.includes('\0')) throw new AppError('目录路径无效');
    const real = await fs.realpath(value.startsWith('~/') ? path.join(os.homedir(), value.slice(2)) : value);
    if (!(await fs.stat(real)).isDirectory()) throw new AppError('请选择目录');
    return real;
  }
  async persist() { await writeAtomic(path.join(this.dataDir, 'state.json'), JSON.stringify({ roots: this.roots, projects: this.paths, manualPaths: this.manualPaths }, null, 2)); }
  async addRoot(value) {
    const real = await this.directory(value);
    await this.transaction(async () => { if (!this.roots.includes(real)) this.roots.push(real); await this.persist(); });
    this.startScan();
    return real;
  }
  async addProject(value) {
    const real = await this.directory(value);
    if (!(await Promise.all(['package.json', '.nvmrc', '.node-version'].map(name => readRegular(path.join(real, name))))).some(item => item !== null)) throw new AppError('目录中没有 Node 项目声明');
    await this.transaction(async () => { if (!this.paths.includes(real)) this.paths.push(real); if (!this.manualPaths.includes(real)) this.manualPaths.push(real); await this.persist(); });
    return projectId(real);
  }
  startScan() {
    if (this.scanning) { this.scanAgain = true; return; }
    this.controller = new AbortController();
    this.scan = { state: 'running', visited: 0, found: 0, errors: [], startedAt: new Date().toISOString() };
    this.scanning = discover(this.roots, { signal: this.controller.signal, onProgress: update => Object.assign(this.scan, update) })
      .then(result => this.transaction(async () => {
        // Keep manually added projects; recompute scanned projects on every pass.
        const accessible = [];
        for (const directory of this.manualPaths) {
          try { if (await this.directory(directory) === directory) accessible.push(directory); } catch {}
        }
        this.paths = [...new Set([...result.projects, ...accessible])].sort();
        this.scan = { ...this.scan, ...result, projects: undefined, state: result.limited ? 'limited' : 'complete', endedAt: new Date().toISOString() };
        await this.persist();
      })).catch(error => { this.scan.state = this.controller.signal.aborted ? 'cancelled' : 'failed'; this.scan.error = error.message; })
      .finally(() => { this.scanning = null; if (this.scanAgain && !this.closing) { this.scanAgain = false; this.startScan(); } });
  }
  async projects(installed) {
    return Promise.all(this.paths.map(directory => projectRecord(directory, installed, this.runtime.nvmDir, v => this.runtime.phaseOf(v))));
  }
  async snapshot() {
    const installed = await this.runtime.installed();
    const projects = await this.projects(installed);
    return { mode: 'local', home: os.homedir(), architecture: `${os.platform()} · ${os.arch()}`, nvmDir: this.runtime.nvmDir,
      roots: this.roots, projects, installed, releases: this.runtime.releases(installed), default: await this.runtime.defaultVersion(),
      scan: this.scan, tasks: this.runtime.tasks, catalogAt: this.runtime.catalogAt, catalogError: this.runtime.catalogError, syncing: Boolean(this.runtime.syncing) };
  }
  async preview({ id, destination, requested }) {
    const directory = this.paths.find(p => projectId(p) === id);
    if (!directory) throw new AppError('项目不存在，请重新扫描', 404);
    return makePreview({ path: directory }, destination, requested, await this.runtime.installed(), this.runtime.nvmDir);
  }
  async save(body) {
    return this.transaction(async () => {
      if (typeof body.expected !== 'string') throw new AppError('请先预览文件变更');
      const preview = await this.preview(body);
      if (preview.expected !== body.expected) throw new AppError('文件已被外部修改，请重新预览', 409);
      await writeAtomic(preview.file, preview.after, body.expected);
      return { saved: true, file: preview.file };
    });
  }
  async browse(value) {
    const directory = await this.directory(value || os.homedir());
    const entries = await fs.readdir(directory, { withFileTypes: true });
    return { path: directory, parent: path.dirname(directory), directories: entries.filter(e => e.isDirectory() && !e.name.startsWith('.')).map(e => ({ name: e.name, path: path.join(directory, e.name) })).sort((a, b) => a.name.localeCompare(b.name)) };
  }
  async close() {
    this.closing = true;
    this.controller?.abort();
    await this.scanning;
    await this.queue;
    await this.runtime.close();
  }
}
