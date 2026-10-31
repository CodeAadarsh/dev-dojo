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
          /* clipboard unavailable — no-op */
        }
      }}
      className="rounded-md border border-white/10 px-2.5 py-1 text-xs text-[#8aa0bf] transition-colors hover:border-white/25 hover:text-white"
    >
      {copied ? 'copied' : 'copy'}
    </button>
  );
}
