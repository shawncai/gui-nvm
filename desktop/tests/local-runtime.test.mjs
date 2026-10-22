import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { discover, findDeclaration, resolveVersion, makePreview, writeAtomic, readRegular, digest } from '../server/files.mjs';
import { Runtime, releasePhase } from '../server/runtime.mjs';
import { Store } from '../server/store.mjs';
import { createApp } from '../server/index.mjs';
import { systemProxy } from '../server/network.mjs';

async function fixture(t) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'gui-nvm-test-')));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const write = async (relative, value) => { const file = path.join(root, relative); await fs.mkdir(path.dirname(file), { recursive: true }); await fs.writeFile(file, value); return file; };
  const nvmDir = path.join(root, 'nvm');
  const dataDir = path.join(root, 'data');
  await fs.mkdir(dataDir);
  for (const version of ['v22.22.3', 'v24.17.0']) await write(`nvm/versions/node/${version}/bin/node`, 'fixture');
  await write('nvm/alias/default', '22.22.3\n');
  const runtime = new Runtime({ nvmDir, dataDir });
  t.after(() => runtime.close());
  return { root, write, nvmDir, dataDir, runtime, installed: await runtime.installed() };
}

test('system proxy parsing accepts enabled valid endpoints without shell interpolation', () => {
  assert.equal(systemProxy('HTTPSEnable : 1\n HTTPSProxy : 127.0.0.1\n HTTPSPort : 7890'), 'http://127.0.0.1:7890');
  assert.equal(systemProxy('HTTPSEnable : 0\n HTTPSProxy : 127.0.0.1\n HTTPSPort : 7890'), null);
  assert.equal(systemProxy('HTTPSEnable : 1\n HTTPSProxy : $(touch bad)\n HTTPSPort : 7890'), null);
  assert.equal(systemProxy('HTTPSEnable : 1\n HTTPSProxy : localhost\n HTTPSPort : 99999'), null);
});

test('scan discovers nested workspaces, de-duplicates roots, and skips dependencies and symlinks', async t => {
  const f = await fixture(t);
  await f.write('projects/mono/package.json', '{}');
  await f.write('projects/mono/packages/ui/package.json', '{}');
  await f.write('projects/mono/node_modules/dep/package.json', '{}');
  await f.write('projects/mono/dist/package.json', '{}');
  await f.write('outside/secret/package.json', '{}');
  await fs.symlink(path.join(f.root, 'outside'), path.join(f.root, 'projects/link'));
  const result = await discover([path.join(f.root, 'projects'), path.join(f.root, 'projects/mono')]);
  assert.deepEqual(result.projects.map(p => path.relative(f.root, p)), ['projects/mono', 'projects/mono/packages/ui']);
  assert.equal((await discover([f.root], { maxDirectories: 1 })).limited, true);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(discover([f.root], { signal: controller.signal }), /取消/);
});

test('nearest declaration wins, then .nvmrc before .node-version before engines.node', async t => {
  const f = await fixture(t);
  await f.write('projects/.nvmrc', '22.22.3\n');
  await f.write('projects/web/package.json', '{"engines":{"node":">=24 <25"}}');
  const project = path.join(f.root, 'projects/web');
  assert.equal((await findDeclaration(project)).source, 'package.json');
  await f.write('projects/web/.node-version', '24.17.0\n');
  assert.equal((await findDeclaration(project)).source, '.node-version');
  await f.write('projects/web/.nvmrc', '22.22.3 # pinned\n');
  assert.equal((await findDeclaration(project)).requested, '22.22.3');
  await f.write('projects/web/child/package.json', '{}');
  assert.equal((await findDeclaration(path.join(project, 'child'))).inherited, true);
  await f.write('projects/web/.nvmrc', '22\n24\n');
  await assert.rejects(findDeclaration(project), /无效/);
});

test('resolves installed semver ranges and safe aliases without evaluating shell text', async t => {
  const f = await fixture(t);
  assert.equal(await resolveVersion('>=22 <25', f.installed, f.nvmDir), 'v24.17.0');
  assert.equal(await resolveVersion('default', f.installed, f.nvmDir), 'v22.22.3');
  assert.equal(await resolveVersion('lts/*', f.installed, f.nvmDir), 'v24.17.0');
  assert.equal(await resolveVersion('$(touch /tmp/injected)', f.installed, f.nvmDir), null);
  await f.write('nvm/alias/loop', 'loop\n');
  assert.equal(await resolveVersion('loop', f.installed, f.nvmDir), null);
});

test('configuration preview preserves manifest fields and refuses shadowed, unavailable or injected versions', async t => {
  const f = await fixture(t);
  await f.write('web/package.json', '{\n  "name": "web",\n  "engines": { "pnpm": ">=8" },\n  "scripts": { "dev": "vite" }\n}\n');
  const project = { path: path.join(f.root, 'web') };
  const preview = await makePreview(project, 'package.json', '>=22 <25', f.installed, f.nvmDir);
  assert.deepEqual(JSON.parse(preview.after), { name: 'web', engines: { pnpm: '>=8', node: '>=22 <25' }, scripts: { dev: 'vite' } });
  assert.equal(JSON.parse(await fs.readFile(preview.file, 'utf8')).engines.node, undefined);
  await f.write('web/.nvmrc', '22.22.3\n');
  await assert.rejects(makePreview(project, 'package.json', '22', f.installed, f.nvmDir), /优先级/);
  await assert.rejects(makePreview(project, '../outside', '22', f.installed, f.nvmDir), /不支持/);
  await assert.rejects(makePreview(project, '.nvmrc', '28.0.0', f.installed, f.nvmDir), /尚未安装/);
  await assert.rejects(makePreview(project, '.nvmrc', '22\nmalicious', f.installed, f.nvmDir), /无效/);
});

test('writes detect external edits and reject symlink targets and oversized declarations', async t => {
  const f = await fixture(t);
  const file = await f.write('web/.nvmrc', '22.22.3\n');
  const expected = digest(await readRegular(file));
  await fs.writeFile(file, '24.17.0\n');
  await assert.rejects(writeAtomic(file, '22\n', expected), /外部修改/);
  assert.equal(await fs.readFile(file, 'utf8'), '24.17.0\n');
  await fs.symlink(file, path.join(f.root, 'linked'));
  await assert.rejects(writeAtomic(path.join(f.root, 'linked'), 'overwrite'), /符号链接/);
  const large = await f.write('large', 'x'.repeat(9000));
  await assert.rejects(readRegular(large, 8192), /大小/);
});

test('default version changes require an installed version and current file revision', async t => {
  const f = await fixture(t);
  const initial = await f.runtime.defaultVersion();
  await f.runtime.setDefault('v24.17.0', initial.expected);
  assert.equal((await f.runtime.defaultVersion()).value, 'v24.17.0');
  await assert.rejects(f.runtime.setDefault('v22.22.3', initial.expected), /外部修改/);
  await assert.rejects(f.runtime.setDefault('v29.0.0', initial.expected), /已安装/);
});

const binaryTarget = (os.platform() === 'darwin' ? 'osx' : os.platform()) + '-' + os.arch() + (os.platform() === 'darwin' ? '-tar' : '');
test('installation publishes a complete runtime while keeping default and old versions intact', async t => {
  const f = await fixture(t);
  f.runtime.catalog = [{ version: 'v26.12.0', files: [binaryTarget], date: '2026-10-14' }];
  f.runtime.installer = async ({ staging, version }) => { const bin = path.join(staging, 'versions/node', version, 'bin'); await fs.mkdir(bin, { recursive: true }); await fs.writeFile(path.join(bin, 'node'), 'complete'); };
  const task = await f.runtime.install('v26.12.0');
  await f.runtime.active.operation;
  assert.equal(task.state, 'complete');
  assert.equal((await f.runtime.defaultVersion()).value, '22.22.3');
  assert.equal((await f.runtime.installed()).length, 3);
  assert.equal((await fs.readdir(f.nvmDir)).some(name => name.startsWith('.gui-nvm-install-')), false);
});

test('parallel starts are rejected; cancellation never publishes partial runtimes', async t => {
  const f = await fixture(t);
  f.runtime.catalog = [{ version: 'v26.12.0', files: [binaryTarget], date: '2026-10-14' }];
  f.runtime.installer = ({ signal }) => new Promise((resolve, reject) => { if (signal.aborted) reject(new Error('cancel')); else signal.addEventListener('abort', () => reject(new Error('cancel')), { once: true }); });
  const results = await Promise.allSettled([f.runtime.install('v26.12.0'), f.runtime.install('v26.12.0')]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  const task = results.find(r => r.status === 'fulfilled').value;
  f.runtime.cancel(task.id);
  await f.runtime.close();
  assert.equal(task.state, 'cancelled');
  assert.equal((await f.runtime.installed()).length, 2);
  assert.equal((await fs.readdir(f.nvmDir)).some(name => name.startsWith('.gui-nvm-install-')), false);
});

test('catalog failure retains cached releases; lifecycle descriptions use release schedule', async t => {
  const f = await fixture(t);
  f.runtime.fetcher = async () => new Response(JSON.stringify([{ version: 'v26.12.0', files: [binaryTarget], date: '2026-10-14' }]));
  await f.runtime.syncCatalog();
  assert.equal(f.runtime.releases(f.installed)[0].compatible, true);
  f.runtime.fetcher = async () => { throw new Error('offline'); };
  await f.runtime.syncCatalog();
  assert.equal(f.runtime.catalog.length, 1);
  assert.match(f.runtime.catalogError, /offline/);
  assert.equal(releasePhase('v20.20.2', undefined, '2026-10-21').phase, 'EOL');
  assert.equal(releasePhase('v26.12.0', undefined, '2026-10-21').phase, 'Current');
});

test('HTTP API blocks foreign origins, untrusted hosts, missing sessions and unsafe saves', async t => {
  const f = await fixture(t);
  await f.write('projects/web/package.json', '{"name":"web"}');
  const store = new Store({ dataDir: f.dataDir, nvmDir: f.nvmDir, roots: [path.join(f.root, 'projects')], runtime: f.runtime });
  await store.init({ sync: false }); await store.scanning;
  const app = await createApp({ port: 0, store, initialize: false });
  t.after(() => app.close());
  assert.equal((await fetch(app.url + '/api/bootstrap', { headers: { Origin: 'https://evil.invalid' } })).status, 403);
  const foreignHostStatus = await new Promise((resolve, reject) => { http.get(app.url + '/api/bootstrap', { headers: { Host: 'evil.invalid' } }, response => { response.resume(); resolve(response.statusCode); }).on('error', reject); });
  assert.equal(foreignHostStatus, 403);
  assert.equal((await fetch(app.url + '/api/state')).status, 403);
  const { token } = await (await fetch(app.url + '/api/bootstrap')).json();
  const headers = { Origin: app.url, 'X-Gui-Nvm-Token': token, 'Content-Type': 'application/json' };
  const state = await (await fetch(app.url + '/api/state', { headers })).json();
  assert.equal(state.projects.length, 1);
  const payload = { id: state.projects[0].id, destination: '.nvmrc', requested: '24.17.0' };
  const post = (route, data, extra = {}) => fetch(app.url + '/api/' + route, { method: 'POST', headers: { ...headers, ...extra }, body: JSON.stringify(data) });
  assert.equal((await post('config/save', payload)).status, 400);
  assert.equal((await post('config/preview', { ...payload, id: '../nvm' })).status, 404);
  assert.equal((await post('config/preview', payload, { 'Content-Type': 'text/plain' })).status, 415);
  const preview = await (await post('config/preview', payload)).json();
  assert.equal((await post('config/save', { ...payload, expected: preview.expected })).status, 200);
  assert.equal(await fs.readFile(path.join(f.root, 'projects/web/.nvmrc'), 'utf8'), '24.17.0\n');
  assert.equal((await post('config/save', { ...payload, expected: preview.expected })).status, 409);
  assert.equal((await post('config/preview', { ...payload, requested: 'x'.repeat(70000) })).status, 413);
  assert.equal((await fetch(app.url + '/__open-in-editor?file=/etc/passwd')).status, 404);
});
