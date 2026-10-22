import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);
const proxyNames = ['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'all_proxy', 'no_proxy'];

export function systemProxy(text) {
  const value = key => text.match(new RegExp('^\\s*' + key + ' : ([^\\r\\n]+)', 'm'))?.[1].trim();
  for (const protocol of ['HTTPS', 'HTTP']) {
    const host = value(protocol + 'Proxy');
    const port = value(protocol + 'Port');
    if (value(protocol + 'Enable') === '1' && /^[a-z0-9.-]+$/i.test(host || '') && /^\d+$/.test(port || '') && Number(port) > 0 && Number(port) < 65536) return `http://${host}:${port}`;
  }
  return null;
}
export async function networkEnvironment() {
  const env = {};
  for (const name of proxyNames) if (process.env[name]) env[name] = process.env[name];
  if (['HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'https_proxy', 'http_proxy', 'all_proxy'].some(name => env[name])) return env;
  if (process.platform === 'darwin') {
    try {
      const { stdout } = await run('/usr/sbin/scutil', ['--proxy'], { timeout: 2000, maxBuffer: 32768 });
      const proxy = systemProxy(stdout);
      if (proxy) Object.assign(env, { HTTPS_PROXY: proxy, HTTP_PROXY: proxy, https_proxy: proxy, http_proxy: proxy });
    } catch {}
  }
  return env;
}
export async function fetchIndex(url, { signal } = {}) {
  // Fixed official HTTPS URL only. curl follows the same proxy policy as nvm downloads.
  if (url !== 'https://nodejs.org/dist/index.json') throw new Error('不支持的版本索引地址');
  const { stdout } = await run('/usr/bin/curl', ['--fail', '--silent', '--show-error', '--location', '--proto', '=https', '--proto-redir', '=https', '--max-time', '20', url], {
    signal, timeout: 22000, maxBuffer: 8 * 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', ...await networkEnvironment() },
  });
  return new Response(stdout);
}
