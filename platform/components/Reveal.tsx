'use client';

import { useState } from 'react';

export function Reveal({
  label,
  children,
  danger,
}: {
  label: string;
  children: React.ReactNode;
  danger?: boolean;
}) {
  const [open, setOpen] = useState(false);
  return (
    <div className="glass overflow-hidden rounded-xl">
      <button
        onClick={() => setOpen(!open)}
        className="flex w-full items-center justify-between px-5 py-3.5 text-left transition-colors hover:text-ink"
        style={{ color: danger ? 'var(--color-amber)' : 'var(--color-dim)' }}
      >
        <span className="text-sm font-medium">{label}</span>
        <span className="mono text-base">{open ? '−' : '+'}</span>
      </button>
      {open && (
        <div className="px-6 py-5" style={{ borderTop: '1px solid var(--color-border)' }}>
          {children}
        </div>
      )}
    </div>
  );
}
