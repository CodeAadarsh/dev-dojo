import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getCourse } from '@/lib/content';
import { getSolvedMap, challengeKey } from '@/lib/db';
import { DifficultyBadge, Pill, ProgressBar } from '@/components/ui';

export const dynamic = 'force-dynamic';

export default async function CoursePage({ params }: { params: Promise<{ course: string }> }) {
  const { course: slug } = await params;
  const course = getCourse(slug);
  if (!course) notFound();

  const solved = getSolvedMap();
  const done = course.challenges.filter((ch) => solved[challengeKey(course.id, ch.slug)]).length;

  return (
    <div className="mx-auto max-w-5xl space-y-10">
      <div>
        <Link href="/" className="text-sm text-dim transition-colors hover:text-accent">
          ← All courses
        </Link>
        <div className="mt-4 flex items-center gap-3">
          <span className="text-xs font-medium text-faint">Course {course.order}</span>
          <DifficultyBadge difficulty={course.difficulty} />
        </div>
        <h1
          className="mt-3 text-3xl font-semibold tracking-tight text-ink sm:text-4xl"
          style={{ fontFamily: 'var(--font-display)' }}
        >
          {course.title}
        </h1>
        <p className="mt-3 max-w-2xl text-pretty leading-relaxed text-dim">{course.description}</p>
        <div className="mt-4 flex flex-wrap gap-1.5">
          {course.tags.map((t) => (
            <Pill key={t}>{t}</Pill>
          ))}
        </div>
      </div>

      {(course.estHours || course.prereqs.length > 0) && (
        <div className="glass grid gap-6 rounded-2xl p-6 sm:grid-cols-[auto_1fr] sm:gap-10">
          {course.estHours && (
            <div>
              <div className="text-xs font-medium uppercase tracking-wide text-faint">Estimated time</div>
              <div className="mt-1 font-medium text-ink">{course.estHours}</div>
            </div>
          )}
          {course.prereqs.length > 0 && (
            <div>
              <div className="text-xs font-medium uppercase tracking-wide text-faint">Prerequisites</div>
              <ul className="mt-1.5 space-y-1 text-sm text-dim">
                {course.prereqs.map((p) => (
                  <li key={p} className="flex gap-2">
                    <span className="text-teal">▸</span>
                    <span>{p}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}

      {course.challenges.length > 0 && (
        <div className="max-w-md">
          <ProgressBar value={done} total={course.challenges.length} />
        </div>
      )}

      <section>
        <h2 className="mb-4 text-lg font-semibold text-ink" style={{ fontFamily: 'var(--font-display)' }}>
          Guide
        </h2>
        <div className="grid gap-3">
          {course.modules.map((m) => (
            <Link
              key={m.id}
              href={`/courses/${course.slug}/modules/${m.id}`}
              className="glass float flex items-center gap-4 rounded-xl px-5 py-3.5"
            >
              <span
                className="grid h-7 w-7 shrink-0 place-items-center rounded-lg text-xs font-semibold"
                style={{ background: 'rgba(50,108,229,0.1)', color: 'var(--color-accent-ink)' }}
              >
                {String(m.order).padStart(2, '0')}
              </span>
              <span className="flex-1 font-medium text-ink">{m.title}</span>
              <span className="text-faint">→</span>
            </Link>
          ))}
          {course.modules.length === 0 && <p className="text-sm text-dim">Modules coming soon.</p>}
        </div>
      </section>

      <section>
        <h2 className="mb-4 text-lg font-semibold text-ink" style={{ fontFamily: 'var(--font-display)' }}>
          Challenges
        </h2>
        <div className="grid gap-3">
          {course.challenges.map((ch) => {
            const chSolved = solved[challengeKey(course.id, ch.slug)];
            return (
              <Link
                key={ch.slug}
                href={`/courses/${course.slug}/challenges/${ch.slug}`}
                className="glass float flex items-center gap-4 rounded-xl px-5 py-3.5"
              >
                <span
                  className="grid h-6 w-6 shrink-0 place-items-center rounded-full text-xs"
                  style={
                    chSolved
                      ? { background: 'rgba(15,157,143,0.15)', color: '#0b8277', border: '1px solid rgba(15,157,143,0.4)' }
                      : { border: '1px solid rgba(18,38,71,0.18)', color: 'transparent' }
                  }
                >
                  {chSolved ? '✓' : ''}
                </span>
                <span className="flex-1 font-medium text-ink">{ch.title}</span>
                <span className="hidden text-xs text-faint sm:inline">
                  {ch.flagType === 'verifier' ? 'verifier' : 'discovery'}
                </span>
                <DifficultyBadge difficulty={ch.difficulty} />
                <span className="text-xs font-medium text-faint">{ch.points} pts</span>
              </Link>
            );
          })}
          {course.challenges.length === 0 && <p className="text-sm text-dim">Challenges coming soon.</p>}
        </div>
      </section>
    </div>
  );
}
