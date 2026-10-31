'use client';

import { useState } from 'react';

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(text);
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        } catch {
          /* clipboard unavailable (non-https / denied) — no-op */
        }
      }}
      className="rounded border border-border px-2 py-1 text-xs text-dim hover:border-green hover:text-white"
    >
      {copied ? 'copied' : 'copy'}
    </button>
  );
}
