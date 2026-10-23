import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';

const sessionKey = 'gui-nvm-session-token';
let moduleId = 0;
const freshToken = () => randomBytes(32).toString('hex');
const json = (value, status = 200) => new Response(JSON.stringify(value), { status });
const expired = () => json({ code: 'SESSION_REQUIRED', error: '会话已失效' }, 403);

async function browser(t, { href = 'http://127.0.0.1:4783/', storage = new Map(), storageDisabled = false, respond = () => json({ ok: true }) } = {}) {
  const requests = [];
  const replacements = [];
  const location = new URL(href);
  const history = {
    state: { screen: 'projects' },
    replaceState(state, title, url) {
      replacements.push({ state, title, url });
      this.state = state;
      location.href = new URL(url, location).href;
    },
  };
  const globals = {
    location, history,
    sessionStorage: {
      getItem(key) { if (storageDisabled) throw new Error('storage disabled'); return storage.get(key) ?? null; },
      setItem(key, value) { if (storageDisabled) throw new Error('storage disabled'); storage.set(key, value); },
      removeItem(key) { if (storageDisabled) throw new Error('storage disabled'); storage.delete(key); },
    },
    fetch: async (url, options) => {
      const request = { url, ...options };
      requests.push(request);
      return respond(request, requests.length);
    },
  };
  for (const [key, value] of Object.entries(globals)) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, key);
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
    t.after(() => {
      if (previous) Object.defineProperty(globalThis, key, previous);
      else delete globalThis[key];
    });
  }
  const reload = () => import(`../src/api.js?session-test=${++moduleId}`);
  return { ...(await reload()), reload, location, history, storage, requests, replacements };
}

test('client consumes the launch fragment once, scrubs it, and authenticates bootstrap and API calls', async t => {
  const token = freshToken();
  const client = await browser(t, { href: `http://127.0.0.1:4783/projects?view=all#token=${token}` });
  assert.equal(client.location.href, 'http://127.0.0.1:4783/projects?view=all');
  assert.deepEqual(client.replacements, [{ state: { screen: 'projects' }, title: '', url: '/projects?view=all' }]);
  assert.equal(client.storage.get(sessionKey), token);
  assert.equal(client.requests.length, 0);
  const controller = new AbortController();
  await Promise.all([client.api('state'), client.api('directories?path=%2Ftmp')]);
  await client.api('config/preview', { id: 'project' }, controller.signal);
  assert.deepEqual(client.requests.map(request => request.url), ['/api/bootstrap', '/api/state', '/api/directories?path=%2Ftmp', '/api/config/preview']);
  assert.ok(client.requests.every(request => request.headers['X-Gui-Nvm-Token'] === token));
  assert.ok(client.requests.every(request => !request.url.includes(token)));
  assert.equal(client.requests[3].method, 'POST');
  assert.equal(client.requests[3].headers['Content-Type'], 'application/json');
  assert.equal(client.requests[3].body, '{"id":"project"}');
  assert.equal(client.requests[3].signal, controller.signal);
  client.location.hash = '#token=' + freshToken();
  await client.api('state');
  assert.equal(client.requests.at(-1).headers['X-Gui-Nvm-Token'], token);
  assert.equal(client.replacements.length, 1);
});

test('a reload restores the same tab session after the fragment has been removed', async t => {
  const token = freshToken();
  const client = await browser(t, { href: `http://127.0.0.1:4783/#token=${token}` });
  await client.api('state');
  const reloaded = await client.reload();
  await reloaded.api('state');
  assert.equal(client.location.hash, '');
  assert.equal(client.replacements.length, 1);
  assert.equal(client.requests.filter(request => request.url === '/api/bootstrap').length, 2);
  assert.ok(client.requests.every(request => request.headers['X-Gui-Nvm-Token'] === token));
});

test('a fresh tab or static preview without a capability makes no management requests', async t => {
  const client = await browser(t, { href: 'https://preview.example.test/' });
  await assert.rejects(client.api('state'), /重新打开终端中的启动链接/);
  await assert.rejects(client.api('state'), /重新打开终端中的启动链接/);
  assert.equal(client.requests.length, 0);
  assert.equal(client.storage.size, 0);
});

test('unrelated fragments are preserved when restoring a saved capability', async t => {
  const token = freshToken();
  const client = await browser(t, { href: 'http://127.0.0.1:4783/#projects', storage: new Map([[sessionKey, token]]) });
  await client.api('state');
  assert.equal(client.location.hash, '#projects');
  assert.equal(client.replacements.length, 0);
  assert.ok(client.requests.every(request => request.headers['X-Gui-Nvm-Token'] === token));
});

test('a malformed or ambiguous launch token clears old credentials and is scrubbed', async t => {
  for (const [name, hash] of [['empty token', '#token='], ['malformed token', '#token=invalid'], ['duplicate token', '#token=' + freshToken() + '&token=' + freshToken()]]) {
    await t.test(name, async child => {
      const client = await browser(child, { href: 'http://127.0.0.1:4783/' + hash, storage: new Map([[sessionKey, freshToken()]]) });
      await assert.rejects(client.api('state'), /重新打开终端中的启动链接/);
      assert.equal(client.location.hash, '');
      assert.equal(client.storage.size, 0);
      assert.equal(client.requests.length, 0);
    });
  }
});

test('a new launch replaces a stale saved capability', async t => {
  const token = freshToken();
  const client = await browser(t, { href: `http://127.0.0.1:4783/#token=${token}`, storage: new Map([[sessionKey, freshToken()]]) });
  await client.api('state');
  assert.equal(client.storage.get(sessionKey), token);
  assert.ok(client.requests.every(request => request.headers['X-Gui-Nvm-Token'] === token));
});

test('credentials are not accepted from the request URL or from malformed saved state', async t => {
  const client = await browser(t, { href: `http://127.0.0.1:4783/?token=${freshToken()}`, storage: new Map([[sessionKey, 'invalid']]) });
  await assert.rejects(client.api('state'), /重新打开终端中的启动链接/);
  assert.equal(client.requests.length, 0);
});

test('an expired saved capability is discarded when bootstrap rejects it', async t => {
  const client = await browser(t, { storage: new Map([[sessionKey, freshToken()]]), respond: expired });
  await assert.rejects(client.api('state'), /重新打开终端中的启动链接/);
  assert.deepEqual(client.requests.map(request => request.url), ['/api/bootstrap']);
  assert.equal(client.storage.size, 0);
  await assert.rejects(client.api('state'), /重新打开终端中的启动链接/);
  assert.equal(client.requests.length, 1);
});

test('server restart invalidates a previously bootstrapped session without retry loops', async t => {
  const client = await browser(t, {
    storage: new Map([[sessionKey, freshToken()]]),
    respond: request => request.url === '/api/bootstrap' ? json({ ok: true }) : expired(),
  });
  await assert.rejects(client.api('state'), /重新打开终端中的启动链接/);
  assert.equal(client.storage.size, 0);
  await assert.rejects(client.api('state'), /重新打开终端中的启动链接/);
  assert.equal(client.requests.length, 2);
});

test('disabled session storage still permits the current launch, then requires a new launch after reload', async t => {
  const token = freshToken();
  const client = await browser(t, { href: `http://127.0.0.1:4783/#token=${token}`, storageDisabled: true });
  await client.api('state');
  assert.equal(client.location.hash, '');
  assert.ok(client.requests.every(request => request.headers['X-Gui-Nvm-Token'] === token));
  const reloaded = await client.reload();
  await assert.rejects(reloaded.api('state'), /重新打开终端中的启动链接/);
  assert.equal(client.requests.length, 2);
});

test('temporary bootstrap errors can retry without discarding the capability', async t => {
  const token = freshToken();
  const client = await browser(t, {
    storage: new Map([[sessionKey, token]]),
    respond: (_request, count) => { if (count === 1) throw new Error('offline'); return json({ ok: true }); },
  });
  await assert.rejects(client.api('state'), /offline/);
  await client.api('state');
  assert.equal(client.storage.get(sessionKey), token);
  assert.deepEqual(client.requests.map(request => request.url), ['/api/bootstrap', '/api/bootstrap', '/api/state']);
});

test('business errors do not discard a valid capability', async t => {
  const token = freshToken();
  const client = await browser(t, {
    storage: new Map([[sessionKey, token]]),
    respond: (_request, count) => count === 2 ? json({ error: '拒绝操作' }, 403) : json({ ok: true }),
  });
  await assert.rejects(client.api('state'), /拒绝操作/);
  await client.api('state');
  assert.equal(client.storage.get(sessionKey), token);
  assert.equal(client.requests.filter(request => request.url === '/api/bootstrap').length, 1);
});
