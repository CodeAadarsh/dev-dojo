export function DifficultyBadge({ difficulty }: { difficulty: string }) {
  const d = difficulty.toLowerCase();
  const cls = d.includes('insane')
    ? 'text-red border-red'
    : d.includes('hard')
      ? 'text-amber border-amber'
      : d.includes('medium')
        ? 'text-cyan border-cyan'
        : 'text-green border-green';
  return (
    <span className={`rounded border px-2 py-0.5 text-xs ${cls} bg-black/20`}>{difficulty}</span>
  );
}

export function Pill({ children }: { children: React.ReactNode }) {
  return (
    <span className="rounded border border-border bg-panel px-2 py-0.5 text-xs text-dim">{children}</span>
  );
}

export function ProgressBar({ value, total }: { value: number; total: number }) {
  const pct = total ? Math.round((value / total) * 100) : 0;
  return (
    <div className="w-full">
      <div className="mb-1 flex justify-between text-xs text-dim">
        <span>{value}/{total} solved</span>
        <span>{pct}%</span>
      </div>
      <div className="h-1.5 overflow-hidden rounded border border-border bg-panel">
        <div className="h-full bg-green" style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}
