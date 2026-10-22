import { useEffect, useRef, useId } from 'react';
import { IconFolder, IconX } from '@tabler/icons-react';
export const statusLabels = { ready: '就绪', missing: '未安装', eol: '已停止支持', unconfigured: '待配置', invalid: '配置无效' };
export const taskLabels = { running: '进行中', complete: '已完成', failed: '失败', cancelled: '已取消' };
export const shortVersion = v => v?.replace(/^v/, '') || '';
export const phaseLabel = row => row.phase === 'Maintenance LTS' ? 'LTS' : row.phase;
export function displayPath(value, home) { return value === home ? '~' : value?.startsWith(home + '/') ? '~' + value.slice(home.length) : value; }
export function IconButton({ icon: Icon, label, className = '', ...props }) { return <button type="button" className={'icon-button ' + className} aria-label={label} title={label} {...props}><Icon size={20} stroke={1.7} /></button>; }
export function Badge({ status }) { return <span className={'status ' + status}><span className="status-dot" />{statusLabels[status] || status}</span>; }
export function Empty({ label, action }) { return <div className="empty"><IconFolder size={30} stroke={1.3} /><span>{label}</span>{action}</div>; }
export function Modal({ title, children, onClose, className = '' }) {
  const ref = useRef(null);
  const titleId = useId();
  useEffect(() => { const dialog = ref.current; dialog.showModal(); return () => dialog.close(); }, []);
  return <dialog ref={ref} aria-labelledby={titleId} className={'modal ' + className} onCancel={onClose} onClick={e => { if (e.target === ref.current) onClose(); }}><div className="modal-heading"><h2 id={titleId}>{title}</h2><IconButton icon={IconX} label="关闭" onClick={onClose} /></div>{children}</dialog>;
}
