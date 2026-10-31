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
    <div className="overflow-hidden rounded-lg border border-border">
      <button
        onClick={() => setOpen(!open)}
        className={`flex w-full items-center justify-between bg-panel2 px-4 py-2.5 text-left hover:text-white ${
          danger ? 'text-amber' : 'text-dim'
        }`}
      >
        <span className="text-sm font-medium">{label}</span>
        <span className="mono">{open ? '−' : '+'}</span>
      </button>
      {open && <div className="border-t border-border px-4 py-3">{children}</div>}
    </div>
  );
}
