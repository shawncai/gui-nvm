const sessionKey = 'gui-nvm-session-token';
const sessionError = '会话缺失或已失效，请重新打开终端中的启动链接';
const validToken = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
function remember(value) {
  try {
    if (value) sessionStorage.setItem(sessionKey, value);
    else sessionStorage.removeItem(sessionKey);
  } catch { /* The current page can still work when browser storage is disabled. */ }
}
function launchToken() {
  const fragment = new URLSearchParams(location.hash.slice(1));
  let value;
  if (fragment.has('token')) {
    value = fragment.getAll('token').length === 1 ? fragment.get('token') : null;
    history.replaceState(history.state, '', location.pathname + location.search);
    remember(validToken(value) ? value : null);
  } else {
    try { value = sessionStorage.getItem(sessionKey); } catch { /* No saved session. */ }
  }
  return validToken(value) ? value : null;
}
let credential = launchToken();
let session;
async function result(response) {
  const value = await response.json();
  if (!response.ok) {
    if (response.status === 403 && value.code === 'SESSION_REQUIRED') {
      credential = null;
      session = null;
      remember(null);
      throw new Error(sessionError);
    }
    throw new Error(value.error || '操作失败');
  }
  return value;
}
async function token() {
  if (!credential) throw new Error(sessionError);
  if (!session) session = fetch('/api/bootstrap', { headers: { 'X-Gui-Nvm-Token': credential } })
    .then(result).then(() => credential)
    .catch(error => { session = null; throw error; });
  return session;
}
export async function api(route, data, signal) {
  const response = await fetch('/api/' + route, {
    method: data === undefined ? 'GET' : 'POST', signal,
    headers: { 'X-Gui-Nvm-Token': await token(), ...(data === undefined ? {} : { 'Content-Type': 'application/json' }) },
    ...(data === undefined ? {} : { body: JSON.stringify(data) }),
  });
  return result(response);
}
