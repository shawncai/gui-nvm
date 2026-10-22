import { AppError, digest, resolveVersion } from './files.mjs';
import { releasePhase } from './runtime.mjs';

const versions = ['26.5.0', '24.17.0', '23.11.1', '22.22.3', '21.0.0', '20.19.5', '20.16.0', '18.17.0', '16.18.0', '16.16.0', '14.15.3', '14.10.0', '13.14.0'];
const phase = version => releasePhase(version, undefined, '2026-10-21');
export class DemoStore {
  constructor() {
    this.data = { mode: 'demo', home: '/Users/demo', architecture: 'darwin · arm64', nvmDir: '/Users/demo/.nvm', roots: ['/Users/demo/Projects', '/Users/demo/Workspace'], default: { value: 'v16.16.0', expected: digest('16.16.0\n') }, scan: { state: 'complete', found: 8, visited: 68, errors: [] }, catalogAt: '2026-10-21T00:00:00Z', tasks: [],
      installed: versions.map(v => ({ version: 'v' + v, ...phase(v), lts: Number(v.split('.')[0]) % 2 === 0 && Number(v.split('.')[0]) < 26, installed: true })),
      releases: ['24.22.0', '26.12.0', '22.23.3', '20.20.2'].map(v => ({ version: 'v' + v, ...phase(v), compatible: true, date: '2026-10-14' })),
      projects: [
        ['atlas-web', 'Projects', '22.22.3', 'v22.22.3', '.nvmrc', 'ready'],
        ['studio-api', 'Projects', '>=24 <25', 'v24.17.0', 'package.json', 'ready'],
        ['docs-site', 'Projects', '24.22.0', null, '.nvmrc', 'missing'],
        ['mobile-console', 'Projects', '20.19.5', 'v20.19.5', '.nvmrc', 'eol'],
        ['shared-ui', 'Workspace', 'lts/*', 'v24.17.0', '.nvmrc', 'ready'],
        ['legacy-admin', 'Workspace', '16.16.0', 'v16.16.0', '.nvmrc', 'eol'],
        ['dev-tools', 'Projects', '', null, '', 'unconfigured'],
        ['playground', 'Workspace', '', null, '', 'unconfigured'],
      ].map(([name, root, requested, resolved, source, status], index) => ({ id: String(index), name, path: `/Users/demo/${root}/${name}`, requested, resolved, source, status })) };
    this.runtime = {
      syncCatalog: async () => {},
      setDefault: async version => { this.data.default = { value: version, expected: digest(version) }; },
      install: async version => {
        this.data.installed.unshift({ version, ...phase(version), installed: true });
        this.data.releases.find(r => r.version === version).installed = true;
        this.data.tasks.unshift({ id: version, version, state: 'complete', phase: '安装完成', startedAt: new Date().toISOString(), log: '演示任务 · 未操作本机' });
      }, cancel: () => {},
    };
  }
  async init() {}
  async snapshot() { return this.data; }
  async preview({ id, destination, requested }) {
    const project = this.data.projects.find(p => p.id === id);
    if (!project) throw new AppError('项目不存在');
    const resolved = await resolveVersion(requested === 'default' ? this.data.default.value : requested, this.data.installed, this.data.nvmDir);
    if (!resolved) throw new AppError('目标版本尚未安装');
    return { file: project.path + '/' + destination, before: project.requested + '\n', after: requested + '\n', expected: digest(project.requested), resolved, destination, requested };
  }
  async save(body) {
    const preview = await this.preview(body);
    Object.assign(this.data.projects.find(p => p.id === body.id), { requested: body.requested, resolved: preview.resolved, source: body.destination, status: phase(preview.resolved).phase === 'EOL' ? 'eol' : 'ready' });
    return { saved: true };
  }
  startScan() { this.data.scan.endedAt = new Date().toISOString(); }
  async addRoot() { throw new AppError('演示模式下不能扫描本机'); }
  async addProject() { throw new AppError('演示模式下不能添加本机项目'); }
  async browse() { return { path: '/Users/demo', parent: '/', directories: [] }; }
  async close() {}
}
