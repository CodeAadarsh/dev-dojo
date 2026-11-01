import Link from 'next/link';
import { listCourses } from '@/lib/content';
import { getSolvedMap, challengeKey } from '@/lib/db';
import { Pill, DifficultyBadge } from '@/components/ui';

export const dynamic = 'force-dynamic';

const WIDE = new Set([5, 11, 17]); // a few wide tiles for bento rhythm

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

export default function Home() {
  const courses = listCourses();
  const solved = getSolvedMap();
  const totalModules = courses.reduce((n, c) => n + c.modules.length, 0);
  const totalChallenges = courses.reduce((n, c) => n + c.challenges.length, 0);

  return (
    <div>
      <section className="hero-rise relative z-10 mb-14 text-center">
        <div
          className="drift mx-auto mb-6 grid h-16 w-16 place-items-center rounded-2xl text-3xl text-white"
          style={{
            background: 'linear-gradient(180deg,#4b82ef,#326ce5)',
            boxShadow: 'inset 0 1px 0 rgba(255,255,255,.45), 0 16px 36px -14px rgba(50,108,229,.75)',
          }}
        >
          ⛩
        </div>
        <h1
          className="mx-auto max-w-2xl text-balance text-4xl font-semibold leading-tight tracking-tight text-ink sm:text-5xl"
          style={{ fontFamily: 'var(--font-display)' }}
        >
          Master the stack, one flag at a time
        </h1>
        <p className="mx-auto mt-5 max-w-xl text-pretty text-base leading-relaxed text-dim">
          {courses.length} hands-on courses — from Kubernetes and databases to backend, security and AI.
          Read the guide, do the real work in <strong className="text-ink">your own terminal</strong>, and
          capture the flag.
        </p>
        <div className="mt-7 flex flex-wrap items-center justify-center gap-2.5">
          <Pill>{courses.length} courses</Pill>
          <Pill>{totalModules} modules</Pill>
          <Pill>{totalChallenges} challenges</Pill>
        </div>
      </section>

      {courses.length === 0 && (
        <div className="glass rounded-2xl p-8 text-center text-dim">
          No courses found. Keep the <code>courses/</code> directory next to <code>platform/</code>.
        </div>
      )}

      <div
        className="stagger relative z-10 grid grid-cols-2 gap-px overflow-hidden rounded-2xl border [grid-auto-flow:dense] sm:auto-rows-[8.5rem] sm:grid-cols-3 lg:grid-cols-4"
        style={{ background: 'var(--line)', borderColor: 'var(--line)' }}
      >
        {courses.map((c, i) => {
          const total = c.challenges.length;
          const done = c.challenges.filter((ch) => solved[challengeKey(c.id, ch.slug)]).length;
          const comingSoon = c.status === 'coming-soon';
          const featured = i === 0;
          const span = featured ? 'sm:col-span-2 sm:row-span-2' : WIDE.has(i) ? 'sm:col-span-2' : '';
          return (
            <Link
              key={c.id}
              href={`/courses/${c.slug}`}
              className={`bento-tile group flex flex-col p-4 ${span} ${comingSoon ? 'opacity-70' : ''}`}
              style={{ animationDelay: `${Math.min(i * 35, 650)}ms` }}
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
                {total > 0 && <MiniProgress done={done} total={total} />}
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

      <p className="relative z-10 mt-10 text-center text-sm text-dim">
        Pick a course, or see the full plan in{' '}
        <a href="https://github.com/CodeAadarsh/dev-dojo#readme" className="text-green hover:underline">the setup guide</a>.
      </p>
    </div>
  );
}
