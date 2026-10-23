import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { Store } from './store.mjs';
import { DemoStore } from './demo.mjs';
import { AppError, inside, projectId } from './files.mjs';

const appRoot = fileURLToPath(new URL('../', import.meta.url));
const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2' };
function json(res, status, value) { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); }
async function body(req) {
  if (req.headers['content-type']?.split(';')[0] !== 'application/json') throw new AppError('需要 JSON 请求', 415);
  let size = 0;
  const chunks = [];
  for await (const chunk of req) { size += chunk.length; if (size > 65536) throw new AppError('请求过大', 413); chunks.push(chunk); }
  try { const value = JSON.parse(Buffer.concat(chunks).toString()); if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(); return value; }
  catch { throw new AppError('JSON 格式无效'); }
}
export async function createApp({ port = 4783, dev = false, demo = false, store = demo ? new DemoStore() : new Store(), initialize = true } = {}) {
  if (initialize) await store.init();
  const token = crypto.randomBytes(32).toString('hex');
  let vite;
  let actualPort;
  const server = http.createServer(async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', `default-src 'self'; script-src 'self'${dev ? " 'unsafe-inline'" : ''}; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'${dev ? ' ws://127.0.0.1:* ws://localhost:*' : ''}; frame-ancestors 'none'; base-uri 'self'; form-action 'self'`);
    try {
      const hosts = [`127.0.0.1:${actualPort}`, `localhost:${actualPort}`];
      if (!hosts.includes(req.headers.host)) throw new AppError('Host 不受支持', 403);
      const origin = req.headers.origin;
      if (origin && !hosts.map(h => 'http://' + h).includes(origin)) throw new AppError('拒绝跨站请求', 403);
      if (req.headers['sec-fetch-site'] && !['same-origin', 'none'].includes(req.headers['sec-fetch-site'])) throw new AppError('拒绝跨站请求', 403);
      const url = new URL(req.url, `http://${req.headers.host}`);
      if (url.pathname.startsWith('/api/')) {
        if (req.headers['x-gui-nvm-token'] !== token) return json(res, 403, { code: 'SESSION_REQUIRED', error: '会话缺失或已失效，请重新打开终端中的启动链接' });
        if (url.pathname === '/api/bootstrap' && req.method === 'GET') return json(res, 200, { ok: true });
        if (req.method === 'GET') {
          if (url.pathname === '/api/state') return json(res, 200, await store.snapshot());
          if (url.pathname === '/api/directories') return json(res, 200, await store.browse(url.searchParams.get('path')));
        }
        if (req.method === 'POST') {
          if (!origin) throw new AppError('请求缺少来源', 403);
          const data = await body(req);
          let result = { ok: true };
          switch (url.pathname) {
            case '/api/scan': store.startScan(); break;
            case '/api/scan/cancel': store.controller?.abort(); break;
            case '/api/roots': result = { path: await store.addRoot(data.path) }; break;
            case '/api/projects': result = { id: await store.addProject(data.path) }; break;
            case '/api/config/preview': result = await store.preview(data); break;
            case '/api/config/save': result = await store.save(data); break;
            case '/api/releases/sync': await store.runtime.syncCatalog(); if (store.runtime.catalogError) throw new AppError(store.runtime.catalogError, 502); break;
            case '/api/releases/install': result = await store.runtime.install(data.version) || result; break;
            case '/api/tasks/cancel': store.runtime.cancel(data.id); break;
            case '/api/default': await store.runtime.setDefault(data.version, data.expected); break;
            case '/api/projects/reveal': {
              const directory = store.paths?.find(p => projectId(p) === data.id);
              if (!directory || await fs.realpath(directory) !== directory) throw new AppError('项目目录不存在');
              if (process.platform !== 'darwin') throw new AppError('此操作仅支持 macOS');
              const child = spawn('/usr/bin/open', [directory], { stdio: 'ignore' });
              child.on('error', () => {});
              break;
            }
            default: throw new AppError('接口不存在', 404);
          }
          return json(res, 200, result);
        }
        throw new AppError('接口不存在', 404);
      }
      if (!['GET', 'HEAD'].includes(req.method)) throw new AppError('请求方法不受支持', 405);
      if (url.pathname.includes('__open-in-editor')) throw new AppError('接口不存在', 404);
      if (vite) return vite.middlewares(req, res, () => { res.writeHead(404); res.end(); });
      const base = path.join(appRoot, 'dist/client');
      let file = path.resolve(base, '.' + decodeURIComponent(url.pathname));
      if (!inside(base, file)) throw new AppError('路径无效', 403);
      if (!path.extname(file) || url.pathname === '/') file = path.join(base, 'index.html');
      let contents;
      try { contents = await fs.readFile(file); } catch { throw new AppError('页面未构建，请先运行 pnpm --dir desktop build', 404); }
      res.writeHead(200, { 'Content-Type': mime[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
      res.end(req.method === 'HEAD' ? undefined : contents);
    } catch (error) {
      if (!res.headersSent) json(res, error.status || (error.code === 'ENOENT' ? 404 : 500), { error: error.status || error.code === 'ENOENT' ? error.message : '本地服务错误，请检查终端' });
      else res.end();
      if (!error.status && error.code !== 'ENOENT') console.error(error);
    }
  });
  if (dev) {
    const { createServer } = await import('vite');
    vite = await createServer({ root: appRoot, server: { middlewareMode: true, hmr: { server }, host: '127.0.0.1' } });
  }
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  actualPort = server.address().port;
  const url = `http://127.0.0.1:${actualPort}`;
  const launchURL = `${url}/#token=${token}`;
  return { url, launchURL, server, store, async close() { await store.close(); await vite?.close(); await new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }); } };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const app = await createApp({ port: Number(process.env.GUI_NVM_PORT || 4783), dev: process.argv.includes('--dev'), demo: process.argv.includes('--demo') });
  console.log(`gui-nvm: ${app.launchURL}${process.argv.includes('--demo') ? ' (演示模式)' : ''}`);
  if (process.argv.includes('--open') && process.platform === 'darwin') spawn('/usr/bin/open', [app.launchURL], { stdio: 'ignore' });
  let closing = false;
  const close = async () => { if (closing) return; closing = true; await app.close(); process.exit(0); };
  process.on('SIGTERM', close);
  process.on('SIGINT', close);
}
