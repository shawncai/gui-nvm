import { useEffect, useRef, useState, useCallback } from 'react';
import { IconFileText, IconFolder, IconHexagon, IconDownload, IconSearch, IconFilter, IconRefresh, IconPlus, IconSettings, IconChevronRight, IconX, IconLoader2, IconAlertTriangle, IconArrowsSort } from '@tabler/icons-react';
import { api } from './api.js';
import { IconButton, Badge, Empty, Modal, displayPath, taskLabels } from './ui.jsx';
import { Inspector } from './Inspector.jsx';
import { Versions, DirectoryPicker, Settings } from './Views.jsx';

export function App() {
  const [state, setState] = useState(null);
  const [connectionError, setConnectionError] = useState('');
  const [route, setRoute] = useState('projects');
  const [selectedId, setSelectedId] = useState(undefined);
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState('all');
  const [rootFilter, setRootFilter] = useState('');
  const [filterOpen, setFilterOpen] = useState(false);
  const [picker, setPicker] = useState(null);
  const [confirmation, setConfirmation] = useState(null);
  const [toast, setToast] = useState('');
  const [pending, setPending] = useState('');
  const searchRef = useRef(null);
  const refresh = useCallback(async () => {
    try {
      const result = await api('state');
      setState(result); setConnectionError('');
      setSelectedId(id => id === undefined ? (window.innerWidth > 1100 ? result.projects[0]?.id : null) : id);
      return result;
    } catch (error) { setConnectionError(error.message); }
  }, []);
  useEffect(() => { let stopped = false; let timer; const poll = async () => { await refresh(); if (!stopped) timer = setTimeout(poll, 3000); }; poll(); return () => { stopped = true; clearTimeout(timer); }; }, [refresh]);
  useEffect(() => { if (!toast) return; const timer = setTimeout(() => setToast(''), 4500); return () => clearTimeout(timer); }, [toast]);
  function focusSearch() {
    if (!['projects', 'versions'].includes(route)) setRoute('projects');
    requestAnimationFrame(() => searchRef.current?.focus());
  }
  useEffect(() => { const key = event => { if ((event.metaKey || event.ctrlKey) && event.key === 'k') { event.preventDefault(); focusSearch(); } }; window.addEventListener('keydown', key); return () => window.removeEventListener('keydown', key); }, [route]);
  async function act(name, body, success) {
    setPending(name);
    try { const result = await api(name, body); await refresh(); if (success) setToast(success); return result || true; }
    catch (error) { setToast(error.message); return false; }
    finally { setPending(''); }
  }
  const selected = state?.projects.find(project => project.id === selectedId);
  function navigate(next) { setRoute(next); setSearch(''); setFilterOpen(false); }
  function install(release) { setConfirmation({ type: 'install', version: release.version, description: release.description }); }
  const visible = state?.projects.filter(project => {
    const term = search.toLowerCase();
    return (!term || (project.name + ' ' + project.path + ' ' + project.requested).toLowerCase().includes(term))
      && (filter === 'all' || (filter === 'attention' ? ['eol', 'invalid'].includes(project.status) : project.status === filter))
      && (!rootFilter || project.path === rootFilter || project.path.startsWith(rootFilter + '/'));
  }) || [];

  return <div className="app-shell">
    <header className="titlebar">
      <nav className="breadcrumbs" aria-label="当前位置">
        <button className="app-name" onClick={() => navigate('projects')}>gui-nvm</button>
        <span className="breadcrumb-separator" aria-hidden="true">/</span><span className="breadcrumb-machine">本机</span>
        <span className="breadcrumb-separator" aria-hidden="true">/</span><span aria-current="page">{({ projects: '项目', versions: 'Node 版本', tasks: '安装任务', settings: '设置' })[route]}</span>
      </nav>
      <div className="connection-status"><span className={'status-dot ' + (connectionError ? 'offline' : '')} /><span>{connectionError ? '连接中断' : state ? 'nvm 已连接' : '连接中'}</span><span className="header-default">默认 {state?.default.value || '未设置'}</span></div>
    </header>
    <aside className="sidebar" aria-label="主导航"><button className="sidebar-search" aria-label="搜索项目或版本" onClick={focusSearch}><IconSearch size={18} stroke={1.7} /><span>搜索…</span><kbd>⌘ K</kbd></button><nav>{[['projects', IconFileText, '项目', state?.projects.length], ['versions', IconHexagon, 'Node 版本', state?.installed.length], ['tasks', IconDownload, '安装任务', state?.tasks.filter(t => t.state === 'running').length || null]].map(([key, Icon, title, count]) => <button key={key} aria-label={title + (count !== null && count !== undefined ? " " + count : "")} title={title} className={'nav-item ' + (route === key ? 'active' : '')} aria-current={route === key ? 'page' : undefined} onClick={() => navigate(key)}><Icon size={24} stroke={1.6} /><span>{title}</span>{count !== null && count !== undefined && <span className="nav-count">{count}</span>}</button>)}</nav>
      <div className="scan-roots"><div className="section-label"><span>扫描目录</span><IconButton icon={IconPlus} label="添加扫描目录" onClick={() => setPicker('root')} /></div>{state?.roots.map(root => <button key={root} title={root} className={'root-item ' + (rootFilter === root ? 'chosen' : '')} onClick={() => { setRootFilter(rootFilter === root ? '' : root); navigate('projects'); }}><IconFolder size={23} stroke={1.6} /><span>{displayPath(root, state.home)}</span></button>)}</div>
      <div className="sidebar-bottom"><button aria-label="设置" title="设置" className={'nav-item ' + (route === 'settings' ? 'active' : '')} onClick={() => navigate('settings')} aria-current={route === 'settings' ? 'page' : undefined}><IconSettings size={24} stroke={1.6} /><span>设置</span></button></div>
    </aside>
    <main className={'workspace ' + (route === 'projects' && selected ? 'has-inspector' : '')}>
      {connectionError && <div className="connection-error" role="alert"><IconAlertTriangle size={18} />{connectionError}<button onClick={refresh}>重试</button></div>}
      {!state ? <div className="empty"><IconLoader2 className="spin" />连接本机</div> : route === 'projects' ? <>
        <section className="project-pane" aria-label="项目列表">
          <div className="pane-toolbar"><h1>项目</h1><div className="toolbar-actions">
            <button className="button scan-button" aria-label={state.scan.state === 'running' ? '取消扫描' : '重新扫描'} onClick={() => act(state.scan.state === 'running' ? 'scan/cancel' : 'scan', {})}><IconRefresh size={16} className={state.scan.state === 'running' ? 'spin' : ''} /><span>{state.scan.state === 'running' ? '取消扫描' : '重新扫描'}</span></button>
            <button className="button primary compact" aria-label="添加项目" onClick={() => setPicker('project')}><IconPlus size={16} /><span>添加项目</span></button>
          </div></div>
          <div className="project-controls">
            <label className="search-field"><IconSearch size={18} stroke={1.7} /><input ref={searchRef} aria-label="搜索项目" value={search} onChange={e => setSearch(e.target.value)} placeholder="搜索项目…" /></label>
            <div className="project-tabs" role="tablist" aria-label="项目状态">{[['all', '全部', state.projects.length], ['unconfigured', '待配置', state.projects.filter(p => p.status === 'unconfigured').length], ['missing', '版本缺失', state.projects.filter(p => p.status === 'missing').length]].map(([key, label, count]) => <button key={key} role="tab" aria-selected={filter === key} className={filter === key ? 'active' : ''} onClick={() => setFilter(key)}>{label}<span>{count}</span></button>)}</div>
            <div className="filter-anchor"><button aria-label="更多状态筛选" title="更多状态筛选" className={'icon-button filter-button ' + (filter === 'attention' ? 'selected-button' : '')} onClick={() => setFilterOpen(!filterOpen)} aria-expanded={filterOpen}><IconFilter size={16} /></button>{filterOpen && <div className="filter-menu"><button onClick={() => { setFilter('all'); setFilterOpen(false); }}>全部状态</button><button onClick={() => { setFilter('attention'); setFilterOpen(false); }}>已停止支持 / 配置无效</button></div>}</div>
          </div>
          {rootFilter && <div className="active-root"><button className="text-button" onClick={() => setRootFilter('')}>{rootFilter.split('/').at(-1)}<IconX size={14} /></button></div>}
          <div className="table-scroll"><table className="project-table"><thead><tr><th>项目 <IconArrowsSort className="sort-mark" size={13} aria-hidden="true" /></th><th>声明</th><th>解析版本</th><th>状态</th><th aria-label="详情" /></tr></thead><tbody>{visible.map(project => <tr key={project.id} tabIndex={0} aria-selected={selectedId === project.id} className={selectedId === project.id ? 'selected' : ''} onClick={() => setSelectedId(project.id)} onKeyDown={e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setSelectedId(project.id); } }}><td><div className="project-name"><IconFolder size={27} stroke={1.6} /><div><strong>{project.name}</strong><span title={project.path}>{displayPath(project.path, state.home)}</span></div></div></td><td className="mono declaration" title={project.requested}>{project.requested || '—'}</td><td className="mono">{project.resolved || (project.status === 'unconfigured' ? <span className="sans">默认</span> : '—')}</td><td><Badge status={project.status} /></td><td><IconChevronRight size={18} stroke={1.5} /></td></tr>)}</tbody></table>{!visible.length && <Empty label={search || filter !== 'all' ? '没有匹配的项目' : state.scan.state === 'running' ? '正在扫描目录' : '尚未添加项目'} action={<button className="button" onClick={() => setPicker('project')}>添加项目</button>} />}<div className="table-count">{visible.length} 个项目{state.scan.state === 'running' && <span><IconLoader2 size={14} className="spin" />已扫描 {state.scan.visited} 个目录</span>}{state.scan.state === 'limited' && <span>已达到 50,000 个目录上限</span>}{state.scan.errors?.length > 0 && <button onClick={() => navigate('settings')}>{state.scan.errors.length} 个目录无法读取</button>}</div></div>
        </section>{selected && <Inspector key={selected.id} project={selected} state={state} onClose={() => setSelectedId(null)} onRefresh={refresh} notify={setToast} onInstall={install} onBrowse={() => navigate('versions')} onReveal={() => act('projects/reveal', { id: selected.id })} />}
      </> : route === 'versions' ? <Versions state={state} search={search} setSearch={setSearch} searchRef={searchRef} onInstall={install} onDefault={version => setConfirmation({ type: 'default', version })} onSync={() => act('releases/sync', {}, '版本库已同步')} syncing={pending === 'releases/sync' || state.syncing} />
      : route === 'tasks' ? <section className="full-pane"><div className="pane-toolbar"><h1>安装任务 <span>{state.tasks.length}</span></h1></div><div className="tasks-list">{!state.tasks.length ? <Empty label="暂无安装任务" action={<button className="button" onClick={() => navigate('versions')}>浏览版本库</button>} /> : state.tasks.map(task => <article className="task-row" key={task.id}><div className="task-heading"><IconDownload size={22} /><strong className="mono">{task.version}</strong><span className={'task-state ' + task.state}>{taskLabels[task.state]}</span><span className="muted">{new Date(task.startedAt).toLocaleTimeString('zh-CN')}</span>{task.state === 'running' && <button className="button" onClick={() => act('tasks/cancel', { id: task.id })}>取消安装</button>}</div><div className="task-phase">{task.state === 'running' && <IconLoader2 size={15} className="spin" />}{task.phase}</div><details><summary>安装日志</summary><pre>{task.log || '等待输出'}</pre></details></article>)}</div></section>
      : <Settings state={state} onAddRoot={() => setPicker('root')} onDefault={version => setConfirmation({ type: 'default', version })} />}
    </main>
    <footer className="statusbar"><span className="statusbar-right"><span>{state?.mode === 'demo' ? '演示数据' : `本机版本 ${state?.installed.length ?? '—'} · ${state?.projects.length ?? '—'} 个项目`}</span><span className="status-divider" aria-hidden="true">|</span><span>{new Date().toLocaleDateString('sv-SE')}</span></span></footer>
    {toast && <div className="toast" role="status">{toast}<IconButton icon={IconX} label="关闭通知" onClick={() => setToast('')} /></div>}
    {picker && <DirectoryPicker kind={picker} onClose={() => setPicker(null)} onAdd={async directory => { const result = await act(picker === 'root' ? 'roots' : 'projects', { path: directory }, picker === 'root' ? '扫描目录已添加' : '项目已添加'); if (result) { setPicker(null); navigate('projects'); if (result.id) setSelectedId(result.id); } return Boolean(result); }} />}
    {confirmation && <Modal title={confirmation.type === 'install' ? '安装 Node' : '设置默认版本'} onClose={() => setConfirmation(null)}><div className="confirm-version mono">{confirmation.version}</div><dl className="confirm-details"><dt>架构</dt><dd>{state.architecture}</dd><dt>{confirmation.type === 'install' ? '安装目录' : '配置文件'}</dt><dd className="mono">{displayPath(state.nvmDir, state.home)}/{confirmation.type === 'install' ? `versions/node/${confirmation.version}` : 'alias/default'}</dd>{confirmation.description && <><dt>支持状态</dt><dd>{confirmation.description}</dd></>}</dl><div className="modal-actions"><button className="button" onClick={() => setConfirmation(null)}>取消</button><button className="button primary" disabled={Boolean(pending)} onClick={async () => { const ok = await act(confirmation.type === 'install' ? 'releases/install' : 'default', { version: confirmation.version, expected: state.default.expected }, confirmation.type === 'install' ? '安装任务已创建' : '默认版本已更新'); if (ok) { if (confirmation.type === 'install') navigate('tasks'); setConfirmation(null); } }}>{pending ? '处理中…' : confirmation.type === 'install' ? '安装' : '设为默认'}</button></div></Modal>}
  </div>;
}
