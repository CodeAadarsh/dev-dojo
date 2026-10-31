const DIFF = {
  insane: { color: '#d84a5f', bg: 'rgba(216,74,95,0.12)', border: 'rgba(216,74,95,0.28)' },
  hard: { color: '#b0710f', bg: 'rgba(192,125,20,0.13)', border: 'rgba(192,125,20,0.3)' },
  medium: { color: '#1e4fb0', bg: 'rgba(50,108,229,0.11)', border: 'rgba(50,108,229,0.26)' },
  easy: { color: '#0b8277', bg: 'rgba(15,157,143,0.13)', border: 'rgba(15,157,143,0.3)' },
};

export function DifficultyBadge({ difficulty }: { difficulty: string }) {
  const d = difficulty.toLowerCase();
  const s = d.includes('insane')
    ? DIFF.insane
    : d.includes('hard')
      ? DIFF.hard
      : d.includes('medium')
        ? DIFF.medium
        : DIFF.easy;
  return (
    <span
      className="rounded-full px-2.5 py-0.5 text-xs font-medium"
      style={{ color: s.color, background: s.bg, border: `1px solid ${s.border}` }}
    >
      {difficulty}
    </span>
  );
}

export function Pill({ children }: { children: React.ReactNode }) {
  return <span className="chip">{children}</span>;
}

export function ProgressBar({ value, total }: { value: number; total: number }) {
  const pct = total ? Math.round((value / total) * 100) : 0;
  return (
    <div className="w-full">
      <div className="mb-1.5 flex items-baseline justify-between text-xs text-dim">
        <span>{value} of {total} solved</span>
        <span className="font-semibold text-ink">{pct}%</span>
      </div>
      <div
        className="h-2 overflow-hidden rounded-full"
        style={{ background: 'rgba(18,38,71,0.08)', boxShadow: 'inset 0 1px 2px rgba(18,38,71,0.12)' }}
      >
        <div
          className="h-full rounded-full transition-[width] duration-500"
          style={{ width: `${pct}%`, background: 'linear-gradient(90deg,#326ce5,#0f9d8f)' }}
        />
      </div>
    </div>
  );
}
