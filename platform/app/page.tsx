import Link from 'next/link';
import { listCourses } from '@/lib/content';
import { getSolvedMap, challengeKey } from '@/lib/db';
import { ProgressBar, Pill } from '@/components/ui';

export const dynamic = 'force-dynamic';

export default function Home() {
  const courses = listCourses();
  const solved = getSolvedMap();

  return (
    <div>
      <section className="mb-10">
        <h1 className="text-3xl font-bold text-white">The Kubernetes Dojo</h1>
        <p className="mt-2 max-w-2xl text-dim">
          Production Docker, Kubernetes &amp; ArgoCD — learn by breaking and fixing real clusters.
          Pick a course, read the guide, then work in <strong className="text-white">your own terminal</strong>{' '}
          against a local <code className="text-green">kind</code> cluster and capture the flag.
        </p>
      </section>

      {courses.length === 0 && (
        <div className="rounded-xl border border-border bg-panel p-6 text-dim">
          No courses found. Make sure the <code className="text-green">courses/</code> directory sits next
          to <code className="text-green">platform/</code>, or set <code>COURSES_DIR</code>.
        </div>
      )}

      <div className="grid gap-4 sm:grid-cols-2">
        {courses.map((c) => {
          const total = c.challenges.length;
          const done = c.challenges.filter((ch) => solved[challengeKey(c.id, ch.slug)]).length;
          const comingSoon = c.status === 'coming-soon';
          return (
            <Link
              key={c.id}
              href={`/courses/${c.slug}`}
              className={`block rounded-xl border border-border bg-panel p-5 transition hover:border-green ${
                comingSoon ? 'opacity-70' : ''
              }`}
            >
              <div className="flex items-center justify-between">
                <span className="mono text-xs text-greendim">
                  COURSE {String(c.order).padStart(2, '0')}
                </span>
                {comingSoon ? <Pill>coming soon</Pill> : <span className="text-xs text-dim">{c.difficulty}</span>}
              </div>
              <h2 className="mt-2 text-lg font-semibold text-white">{c.title}</h2>
              <p className="mt-1 line-clamp-2 text-sm text-dim">{c.description}</p>
              <div className="mb-4 mt-3 flex flex-wrap gap-1.5">
                {c.tags.slice(0, 4).map((t) => (
                  <Pill key={t}>{t}</Pill>
                ))}
              </div>
              {total > 0 && <ProgressBar value={done} total={total} />}
              <div className="mt-3 text-xs text-dim">
                {c.modules.length} modules · {total} challenges
                {c.estHours ? ` · ⏱ ${c.estHours}` : ''}
              </div>
            </Link>
          );
        })}
      </div>
    </div>
  );
}
