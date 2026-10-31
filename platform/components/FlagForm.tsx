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
      <div className="rounded-lg border border-green bg-green/10 px-4 py-3 font-medium text-green">
        ✓ Solved — flag accepted.
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="flex flex-col gap-2 sm:flex-row">
      <input
        value={flag}
        onChange={(e) => setFlag(e.target.value)}
        placeholder="KUBE{...}"
        spellCheck={false}
        autoComplete="off"
        className="flex-1 rounded-lg border border-border bg-panel2 px-3 py-2 font-mono text-sm outline-none focus:border-green"
      />
      <button
        type="submit"
        disabled={status === 'loading'}
        className="rounded-lg bg-green px-5 py-2 font-semibold text-black hover:brightness-110 disabled:opacity-50"
      >
        {status === 'loading' ? 'Checking…' : 'Submit Flag'}
      </button>
      {status === 'bad' && (
        <span className="self-center text-sm text-red">Incorrect — keep digging.</span>
      )}
    </form>
  );
}
