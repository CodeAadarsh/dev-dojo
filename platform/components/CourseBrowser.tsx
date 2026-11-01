'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import { Pill, DifficultyBadge } from './ui';

export type CourseLite = {
  id: string;
  slug: string;
  title: string;
  order: number;
  difficulty: string;
  description: string;
  tags: string[];
  status: string;
  estHours: string;
  modules: number;
  challenges: number;
  done: number;
};

const WIDE = new Set([5, 11, 17]);

function diffRank(d: string): number {
  const s = d.toLowerCase();
  let r = 2;
  if (s.includes('intermediate')) r = 2;
  if (s.includes('advanced')) r = 3;
  if (s.includes('intermediate') && s.includes('advanced')) r = 2.5;
  if (s.includes('insane')) r = 4;
  return r;
}

type SortKey = 'order' | 'title' | 'difficulty' | 'challenges' | 'progress';
const SORTS: Record<SortKey, { label: string; fn: (a: CourseLite, b: CourseLite) => number }> = {
  order: { label: 'Course order', fn: (a, b) => a.order - b.order },
  title: { label: 'Title A–Z', fn: (a, b) => a.title.localeCompare(b.title) },
  difficulty: { label: 'Difficulty ↑', fn: (a, b) => diffRank(a.difficulty) - diffRank(b.difficulty) || a.order - b.order },
  challenges: { label: 'Most challenges', fn: (a, b) => b.challenges - a.challenges || a.order - b.order },
  progress: {
    label: 'Progress',
    fn: (a, b) =>
      (b.challenges ? b.done / b.challenges : 0) - (a.challenges ? a.done / a.challenges : 0) || a.order - b.order,
  },
};

function MiniProgress({ done, total }: { done: number; total: number }) {
  const pct = total ? Math.round((done / total) * 100) : 0;
  return (
    <div>
      <div className="h-1 overflow-hidden rounded-full" style={{ background: 'rgba(18,38,71,0.1)' }}>
        <div className="h-full rounded-full" style={{ width: `${pct}%`, background: 'linear-gradient(90deg,#326ce5,#0f9d8f)' }} />
      </div>
      <div className="mt-1 text-[10px] text-faint">{done}/{total} solved</div>
    </div>
  );
}

export function CourseBrowser({ courses }: { courses: CourseLite[] }) {
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState<SortKey>('order');

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    const list = q
      ? courses.filter((c) =>
          `${c.title} ${c.description} ${c.difficulty} ${c.tags.join(' ')}`.toLowerCase().includes(q),
        )
      : courses;
    return [...list].sort(SORTS[sort].fn);
  }, [courses, query, sort]);

  return (
    <div>
      <div className="relative z-10 mb-5 flex flex-col gap-3 sm:flex-row sm:items-center">
        <div className="relative flex-1">
          <span className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-faint">⌕</span>
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search courses — topic, tag, difficulty…"
            spellCheck={false}
            className="w-full rounded-xl py-2.5 pl-9 pr-3 text-sm text-ink outline-none transition-shadow placeholder:text-faint focus:ring-2"
            style={{ background: 'rgba(255,255,255,0.72)', border: '1px solid var(--color-border)', boxShadow: 'inset 0 1px 2px rgba(18,38,71,0.05)' }}
          />
        </div>
        <div className="flex items-center gap-2">
          <label htmlFor="sort" className="text-sm text-dim">Sort</label>
          <select
            id="sort"
            value={sort}
            onChange={(e) => setSort(e.target.value as SortKey)}
            className="rounded-xl px-3 py-2.5 text-sm text-ink outline-none focus:ring-2"
            style={{ background: 'rgba(255,255,255,0.72)', border: '1px solid var(--color-border)' }}
          >
            {(Object.keys(SORTS) as SortKey[]).map((k) => (
              <option key={k} value={k}>{SORTS[k].label}</option>
            ))}
          </select>
          <span className="ml-1 whitespace-nowrap text-xs text-faint">{filtered.length} / {courses.length}</span>
        </div>
      </div>

      {filtered.length === 0 ? (
        <div className="glass rounded-2xl p-10 text-center text-dim">
          No courses match “{query}”. <button onClick={() => setQuery('')} className="text-green hover:underline">Clear</button>
        </div>
      ) : (
        <div
          key={`${sort}:${query}`}
          className="stagger relative z-10 grid grid-cols-2 gap-px overflow-hidden rounded-2xl border [grid-auto-flow:dense] sm:auto-rows-[8.5rem] sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5"
          style={{ background: 'var(--line)', borderColor: 'var(--line)' }}
        >
          {filtered.map((c, i) => {
            const comingSoon = c.status === 'coming-soon';
            const featured = i === 0;
            const span = featured ? 'sm:col-span-2 sm:row-span-2' : WIDE.has(i) ? 'sm:col-span-2' : '';
            return (
              <Link
                key={c.id}
                href={`/courses/${c.slug}`}
                className={`bento-tile group flex flex-col p-4 ${span} ${comingSoon ? 'opacity-70' : ''}`}
                style={{ animationDelay: `${Math.min(i * 30, 600)}ms` }}
              >
                <div className="flex items-center justify-between">
                  <span className="mono text-[11px] text-faint">{String(c.order).padStart(2, '0')}</span>
                  {comingSoon ? <Pill>soon</Pill> : <DifficultyBadge difficulty={c.difficulty} />}
                </div>
                <h2
                  className={`mt-2 font-semibold leading-snug text-ink ${featured ? 'text-2xl' : 'text-[0.95rem]'}`}
                  style={{ fontFamily: 'var(--font-display)' }}
                >
                  {c.title}
                </h2>
                {featured && <p className="mt-2 line-clamp-4 text-sm leading-relaxed text-dim">{c.description}</p>}
                <div className="mt-auto pt-3">
                  {c.challenges > 0 && <MiniProgress done={c.done} total={c.challenges} />}
                  {featured && (
                    <div className="mt-3 flex flex-wrap gap-1.5">
                      {c.tags.slice(0, 4).map((t) => (
                        <Pill key={t}>{t}</Pill>
                      ))}
                    </div>
                  )}
                </div>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}
