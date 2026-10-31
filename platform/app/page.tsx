import Link from 'next/link';
import { listCourses } from '@/lib/content';
import { getSolvedMap, challengeKey } from '@/lib/db';
import { ProgressBar, Pill, DifficultyBadge } from '@/components/ui';

export const dynamic = 'force-dynamic';

export default function Home() {
  const courses = listCourses();
  const solved = getSolvedMap();

  const totalModules = courses.reduce((n, c) => n + c.modules.length, 0);
  const totalChallenges = courses.reduce((n, c) => n + c.challenges.length, 0);

  return (
    <div>
      <section className="hero-rise mb-16 text-center">
        <div
          className="drift glass mx-auto mb-7 grid h-16 w-16 place-items-center rounded-2xl text-3xl text-white"
          style={{
            background: 'linear-gradient(180deg,#4b82ef,#326ce5)',
            boxShadow: 'inset 0 1px 0 rgba(255,255,255,.45), 0 16px 36px -14px rgba(50,108,229,.75)',
          }}
        >
          ⎈
        </div>
        <h1
          className="mx-auto max-w-2xl text-balance text-4xl font-semibold leading-tight tracking-tight text-ink sm:text-5xl"
          style={{ fontFamily: 'var(--font-display)' }}
        >
          Learn Kubernetes by running it
        </h1>
        <p className="mx-auto mt-5 max-w-xl text-pretty text-base leading-relaxed text-dim">
          Read the guide, then do the real work in your own terminal against a disposable{' '}
          <code
            className="rounded px-1.5 py-0.5 text-sm"
            style={{ background: 'rgba(50,108,229,0.1)', color: 'var(--color-accent-ink)' }}
          >
            kind
          </code>{' '}
          cluster — and capture the flag.
        </p>
        <div className="mt-7 flex flex-wrap items-center justify-center gap-2.5">
          <Pill>{courses.length} courses</Pill>
          <Pill>{totalModules} modules</Pill>
          <Pill>{totalChallenges} challenges</Pill>
        </div>
      </section>

      {courses.length === 0 && (
        <div className="glass rounded-2xl p-8 text-center text-dim">
          No courses found. Keep the <code>courses/</code> directory next to{' '}
          <code>platform/</code>, or set <code>COURSES_DIR</code>.
        </div>
      )}

      <div className="grid gap-6 sm:grid-cols-2">
        {courses.map((c) => {
          const total = c.challenges.length;
          const done = c.challenges.filter((ch) => solved[challengeKey(c.id, ch.slug)]).length;
          const comingSoon = c.status === 'coming-soon';
          return (
            <Link
              key={c.id}
              href={`/courses/${c.slug}`}
              className={`glass float block rounded-[1.25rem] p-6 ${comingSoon ? 'opacity-70' : ''}`}
            >
              <div className="flex items-center justify-between">
                <span className="text-xs font-medium text-faint">Course {c.order}</span>
                {comingSoon ? <Pill>coming soon</Pill> : <DifficultyBadge difficulty={c.difficulty} />}
              </div>
              <h2
                className="mt-3 text-xl font-semibold leading-snug text-ink"
                style={{ fontFamily: 'var(--font-display)' }}
              >
                {c.title}
              </h2>
              <p className="mt-2 line-clamp-2 text-sm leading-relaxed text-dim">{c.description}</p>
              <div className="mt-4 flex flex-wrap gap-1.5">
                {c.tags.slice(0, 3).map((t) => (
                  <Pill key={t}>{t}</Pill>
                ))}
              </div>
              {total > 0 && (
                <div className="mt-6">
                  <ProgressBar value={done} total={total} />
                </div>
              )}
              <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-1 text-xs text-faint">
                <span>{c.modules.length} modules</span>
                <span>{total} challenges</span>
                {c.estHours && <span className="text-dim">{c.estHours}</span>}
              </div>
            </Link>
          );
        })}
      </div>
    </div>
  );
}
