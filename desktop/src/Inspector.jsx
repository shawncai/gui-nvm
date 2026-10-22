import { useEffect, useRef, useState } from 'react';
import { IconArrowUpRight, IconX, IconChevronDown, IconChevronRight, IconCheck, IconSearch, IconPencil } from '@tabler/icons-react';
import { api } from './api.js';
import { IconButton, shortVersion, phaseLabel } from './ui.jsx';

export function Inspector({ project, state, onClose, onRefresh, notify, onInstall, onBrowse, onReveal }) {
  const [destination, setDestination] = useState(project.source || '.nvmrc');
  const [requested, setRequested] = useState(project.requested || shortVersion(state.installed[0]?.version));
  const [open, setOpen] = useState(false);
  const [custom, setCustom] = useState(false);
  const [preview, setPreview] = useState(null);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [revision, setRevision] = useState(0);
  const comboRef = useRef(null);
  const baseline = useRef({ requested: project.requested, source: project.source });
  const previewController = useRef(null);
  useEffect(() => {
    const old = baseline.current;
    if (old.requested === project.requested && old.source === project.source) return;
    if (requested === old.requested && destination === old.source) {
      setRequested(project.requested);
      setDestination(project.source || '.nvmrc');
    } else if (requested !== project.requested || destination !== project.source) {
      previewController.current?.abort();
      setPreview(null);
      setError('配置已被外部修改，请重新预览');
    }
    baseline.current = { requested: project.requested, source: project.source };
  }, [project.requested, project.source]);
  useEffect(() => { if (!open) return; const close = event => { if (!comboRef.current?.contains(event.target)) setOpen(false); }; document.addEventListener('pointerdown', close); return () => document.removeEventListener('pointerdown', close); }, [open]);
  useEffect(() => {
    const controller = new AbortController();
    previewController.current = controller;
    setPreview(null); setError('');
    const timer = setTimeout(() => api('config/preview', { id: project.id, destination, requested }, controller.signal).then(setPreview).catch(e => { if (e.name !== 'AbortError') setError(e.message); }), 180);
    return () => { clearTimeout(timer); controller.abort(); };
  }, [project.id, destination, requested, revision]);
  const changed = project.requested !== requested || destination !== project.source;
  const targetRelease = state.installed.find(row => row.version === preview?.resolved || shortVersion(row.version) === shortVersion(requested));
  const available = state.releases.filter(row => !row.installed && row.compatible && row.phase !== 'EOL');
  const majorReleases = [available.find(row => row.phase.includes('LTS')), available.find(row => row.phase === 'Current')].filter(Boolean);
  const choices = [...state.installed].sort((a, b) => {
    const score = row => row.phase === 'Current' ? 0 : row.phase.includes('LTS') ? 1 : row.lts ? 2 : 3;
    return score(a) - score(b);
  });
  async function save() {
    setSaving(true);
    try { await api('config/save', { id: project.id, destination, requested, expected: preview.expected }); await onRefresh(); notify('配置已保存'); }
    catch (e) { setError(e.message); setPreview(null); }
    finally { setSaving(false); }
  }
  return <aside className="inspector" aria-label="版本配置">
    <div className="inspector-heading"><h2 title={project.name}>{project.name}</h2><IconButton icon={IconArrowUpRight} label="在访达中打开项目" onClick={onReveal} /><IconButton className="close-inspector" icon={IconX} label="关闭版本配置" onClick={onClose} /></div>
    <div className="inspector-scroll"><section className="configuration"><dl className="config-fields"><dt>当前版本</dt><dd className="mono" title={project.file}>{project.resolved || '—'}</dd><dt>目标版本<IconButton className="edit-version" icon={IconPencil} label="自定义版本或别名" onClick={() => { setOpen(false); setCustom(true); }} /></dt><dd className="version-picker" ref={comboRef}>
      {custom ? <div className="custom-version"><input autoFocus aria-label="自定义版本" value={requested} onChange={e => setRequested(e.target.value)} placeholder={destination === 'package.json' ? '>=22 <23' : '22.22.3 / lts/*'} /><IconButton icon={IconChevronDown} label="选择已安装版本" onClick={() => { setCustom(false); setOpen(true); }} /></div> : <button className={'version-trigger ' + (open ? 'is-open' : '')} aria-label="目标版本" aria-expanded={open} aria-haspopup="listbox" onClick={() => setOpen(!open)} onKeyDown={e => { if (e.key === 'Escape') setOpen(false); if (e.key === 'ArrowDown') { e.preventDefault(); setOpen(true); requestAnimationFrame(() => comboRef.current?.querySelector('[role="option"]')?.focus()); } }}><span className="mono">{requested ? /^v?\d+\.\d+\.\d+$/.test(requested) ? 'v' + shortVersion(requested) : requested : '选择版本'}</span><IconChevronDown size={18} /></button>}
      {open && <div className="version-menu"><div role="listbox" aria-label="已安装的版本" className="version-options" onKeyDown={e => { const options = [...e.currentTarget.querySelectorAll('[role="option"]')]; const index = options.indexOf(document.activeElement); if (['ArrowDown', 'ArrowUp'].includes(e.key)) { e.preventDefault(); options[(index + (e.key === 'ArrowDown' ? 1 : options.length - 1)) % options.length]?.focus(); } if (e.key === 'Escape') { setOpen(false); comboRef.current?.querySelector('button')?.focus(); } }}>{choices.map(row => <button role="option" aria-selected={shortVersion(row.version) === shortVersion(requested)} className={shortVersion(row.version) === shortVersion(requested) ? 'chosen' : ''} key={row.version} onClick={() => { setRequested(shortVersion(row.version)); setOpen(false); }}><span className="mono">{row.version}</span><small>{phaseLabel(row)} · {row.description}</small>{shortVersion(row.version) === shortVersion(requested) && <IconCheck size={16} />}</button>)}</div><button className="menu-footer" onClick={onBrowse}><IconSearch size={18} />浏览版本库…</button></div>}
      {targetRelease && <div className="target-support">{phaseLabel(targetRelease)} · {targetRelease.description}</div>}
    </dd></dl>
    <div className="configuration-bottom"><dl className="config-fields"><dt>写入文件</dt><dd><select aria-label="写入文件" value={destination} onChange={e => setDestination(e.target.value)}>{['.nvmrc', '.node-version', 'package.json'].map(file => <option key={file}>{file}</option>)}</select></dd></dl><div className="preview-label">{changed && <span>待保存</span>}</div><div className="code-preview" aria-label="文件预览"><span>1</span><code>{destination === 'package.json' ? `"node": "${requested}"` : requested || '—'}</code></div>{project.inherited && <div className="inline-note">写入当前项目 · {destination}</div>}{error && <div className="inline-error" role="alert">{error}<button className="text-button" onClick={() => setRevision(revision + 1)}>重新预览</button></div>}{project.error && <div className="inline-error">{project.error}</div>}<div className="save-actions"><button className="button" disabled={saving} onClick={() => { setRequested(project.requested || shortVersion(state.installed[0]?.version)); setDestination(project.source || '.nvmrc'); setCustom(false); setOpen(false); setRevision(revision + 1); }}>取消</button><button className="button primary" disabled={!preview || !changed || saving} onClick={save}>{saving ? '保存中…' : '保存配置'}</button></div></div>
    </section><section className="updates"><h3>可安装</h3>{majorReleases.map(row => <div key={row.version} className="update-row"><strong className="mono">{row.version}</strong><span>{phaseLabel(row)} · {row.description}</span><button className="button subtle" onClick={() => onInstall(row)}>安装</button></div>)}{!majorReleases.length && <button className="text-button" onClick={onBrowse}>浏览版本库 <IconChevronRight size={16} /></button>}</section></div>
  </aside>;
}
