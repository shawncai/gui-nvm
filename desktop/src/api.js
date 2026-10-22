let session;
async function token() {
  if (!session) session = fetch('/api/bootstrap').then(async response => {
    if (!response.ok) throw new Error('无法连接本地服务');
    return (await response.json()).token;
  }).catch(error => { session = null; throw error; });
  return session;
}
export async function api(route, data, signal) {
  const response = await fetch('/api/' + route, {
    method: data === undefined ? 'GET' : 'POST', signal,
    headers: { 'X-Gui-Nvm-Token': await token(), ...(data === undefined ? {} : { 'Content-Type': 'application/json' }) },
    ...(data === undefined ? {} : { body: JSON.stringify(data) }),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || '操作失败');
  return result;
}
