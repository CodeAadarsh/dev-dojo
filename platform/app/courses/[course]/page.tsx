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
    <div className="space-y-8">
      <div>
        <Link href="/" className="text-sm text-dim hover:text-green">← all courses</Link>
        <h1 className="mt-2 text-3xl font-bold text-white">{course.title}</h1>
        <p className="mt-2 max-w-2xl text-dim">{course.description}</p>
        <div className="mt-3 flex flex-wrap gap-1.5">
          {course.tags.map((t) => (
            <Pill key={t}>{t}</Pill>
          ))}
        </div>
      </div>

      {(course.estHours || course.prereqs.length > 0) && (
        <div className="space-y-2 rounded-lg border border-border bg-panel p-4 text-sm">
          {course.estHours && (
            <div>
              <span className="text-dim">⏱ Estimated time: </span>
              <span className="text-white">{course.estHours}</span>
            </div>
          )}
          {course.prereqs.length > 0 && (
            <div>
              <span className="text-dim">Prerequisites:</span>
              <ul className="mt-1 list-disc pl-5 text-dim">
                {course.prereqs.map((p) => (
                  <li key={p}>{p}</li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}

      {course.challenges.length > 0 && (
        <div className="max-w-sm">
          <ProgressBar value={done} total={course.challenges.length} />
        </div>
      )}

      <section>
        <h2 className="mb-3 text-lg font-semibold text-white">Guide</h2>
        <div className="grid gap-2">
          {course.modules.map((m) => (
            <Link
              key={m.id}
              href={`/courses/${course.slug}/modules/${m.id}`}
              className="flex items-center gap-3 rounded-lg border border-border bg-panel px-4 py-3 hover:border-green"
            >
              <span className="mono text-sm text-greendim">{String(m.order).padStart(2, '0')}</span>
              <span className="text-white">{m.title}</span>
            </Link>
          ))}
          {course.modules.length === 0 && <p className="text-sm text-dim">Modules coming soon.</p>}
        </div>
      </section>

      <section>
        <h2 className="mb-3 text-lg font-semibold text-white">Challenges</h2>
        <div className="grid gap-2">
          {course.challenges.map((ch) => {
            const chSolved = solved[challengeKey(course.id, ch.slug)];
            return (
              <Link
                key={ch.slug}
                href={`/courses/${course.slug}/challenges/${ch.slug}`}
                className="flex items-center gap-3 rounded-lg border border-border bg-panel px-4 py-3 hover:border-green"
              >
                <span className={`w-4 text-center ${chSolved ? 'text-green' : 'text-dim'}`}>
                  {chSolved ? '✓' : '○'}
                </span>
                <span className="flex-1 text-white">{ch.title}</span>
                <span className="hidden text-xs text-dim sm:inline">{ch.flagType}</span>
                <DifficultyBadge difficulty={ch.difficulty} />
                <span className="mono text-xs text-greendim">{ch.points}pt</span>
              </Link>
            );
          })}
          {course.challenges.length === 0 && <p className="text-sm text-dim">Challenges coming soon.</p>}
        </div>
      </section>
    </div>
  );
}
