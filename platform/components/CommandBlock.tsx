import { CopyButton } from './CopyButton';

export function CommandBlock({ title, command }: { title?: string; command: string }) {
  return (
    <div
      className="overflow-hidden rounded-xl"
      style={{ background: 'var(--color-terminal)', boxShadow: '0 22px 50px -26px rgba(15,27,45,0.7)' }}
    >
      <div
        className="flex items-center justify-between px-4 py-2.5"
        style={{ borderBottom: '1px solid rgba(255,255,255,0.07)' }}
      >
        <div className="flex items-center gap-1.5">
          <span className="h-2.5 w-2.5 rounded-full" style={{ background: '#ff6058' }} />
          <span className="h-2.5 w-2.5 rounded-full" style={{ background: '#ffbd2e' }} />
          <span className="h-2.5 w-2.5 rounded-full" style={{ background: '#28c941' }} />
          <span className="ml-2 text-xs" style={{ color: '#7d8aa5' }}>{title ?? 'terminal'}</span>
        </div>
        <CopyButton text={command} />
      </div>
      <pre className="overflow-x-auto px-5 py-4 text-sm leading-relaxed">
        <code className="mono" style={{ color: '#9ad1ff' }}>{command}</code>
      </pre>
    </div>
  );
}
