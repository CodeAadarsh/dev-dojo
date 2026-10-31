import { CopyButton } from './CopyButton';

export function CommandBlock({ title, command }: { title?: string; command: string }) {
  return (
    <div className="overflow-hidden rounded-lg border border-border bg-[#0d1420]">
      <div className="flex items-center justify-between border-b border-border bg-panel2 px-3 py-1.5">
        <span className="text-xs text-dim">{title ?? 'terminal'}</span>
        <CopyButton text={command} />
      </div>
      <pre className="overflow-x-auto px-4 py-3 text-sm">
        <code className="mono text-green">{command}</code>
      </pre>
    </div>
  );
}
