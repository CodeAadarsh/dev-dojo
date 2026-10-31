'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';

export function FlagForm({
  courseId,
  challengeId,
  solved,
}: {
  courseId: string;
  challengeId: string;
  solved: boolean;
}) {
  const [flag, setFlag] = useState('');
  const [status, setStatus] = useState<'idle' | 'loading' | 'ok' | 'bad'>(solved ? 'ok' : 'idle');
  const router = useRouter();

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!flag.trim()) return;
    setStatus('loading');
    try {
      const res = await fetch('/api/verify', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ courseId, challengeId, flag }),
      });
      const data = await res.json();
      if (data.correct) {
        setStatus('ok');
        router.refresh();
      } else {
        setStatus('bad');
      }
    } catch {
      setStatus('bad');
    }
  }

  if (status === 'ok') {
    return (
      <div
        className="flex items-center gap-2 rounded-xl px-4 py-3 font-medium"
        style={{ color: '#0b8277', background: 'rgba(15,157,143,0.12)', border: '1px solid rgba(15,157,143,0.35)' }}
      >
        <span>✓</span> Flag accepted — challenge solved.
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <form onSubmit={onSubmit} className="flex flex-col gap-3 sm:flex-row">
        <input
          value={flag}
          onChange={(e) => setFlag(e.target.value)}
          placeholder="KUBE{...}"
          spellCheck={false}
          autoComplete="off"
          className="mono flex-1 rounded-xl px-4 py-2.5 text-sm text-ink outline-none transition-shadow placeholder:text-faint focus:ring-2"
          style={{
            background: 'rgba(255,255,255,0.7)',
            border: '1px solid var(--color-border)',
            boxShadow: 'inset 0 1px 2px rgba(18,38,71,0.05)',
          }}
        />
        <button type="submit" disabled={status === 'loading'} className="btn-primary px-6 py-2.5 text-sm font-medium disabled:opacity-50">
          {status === 'loading' ? 'Checking…' : 'Submit flag'}
        </button>
      </form>
      {status === 'bad' && (
        <p className="text-sm" style={{ color: 'var(--color-red)' }}>
          Not quite — keep digging.
        </p>
      )}
    </div>
  );
}
