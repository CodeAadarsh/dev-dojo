import { listCourses } from '@/lib/content';
import { getSolvedMap, challengeKey } from '@/lib/db';
import { Pill } from '@/components/ui';
import { CourseBrowser, type CourseLite } from '@/components/CourseBrowser';

export const dynamic = 'force-dynamic';

export default function Home() {
  const courses = listCourses();
  const solved = getSolvedMap();

  const lite: CourseLite[] = courses.map((c) => ({
    id: c.id,
    slug: c.slug,
    title: c.title,
    order: c.order,
    difficulty: c.difficulty,
    description: c.description,
    tags: c.tags,
    status: c.status,
    estHours: c.estHours,
    modules: c.modules.length,
    challenges: c.challenges.length,
    done: c.challenges.filter((ch) => solved[challengeKey(c.id, ch.slug)]).length,
  }));

  const totalModules = lite.reduce((n, c) => n + c.modules, 0);
  const totalChallenges = lite.reduce((n, c) => n + c.challenges, 0);

  return (
    <div>
      <section className="hero-rise relative z-10 mb-12 text-center">
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
          {lite.length} hands-on courses — from Kubernetes and databases to backend, security, MLOps and AI.
          Read the guide, do the real work in <strong className="text-ink">your own terminal</strong>, capture the flag.
        </p>
        <div className="mt-7 flex flex-wrap items-center justify-center gap-2.5">
          <Pill>{lite.length} courses</Pill>
          <Pill>{totalModules} modules</Pill>
          <Pill>{totalChallenges} challenges</Pill>
        </div>
      </section>

      {lite.length === 0 ? (
        <div className="glass rounded-2xl p-8 text-center text-dim">
          No courses found. Keep the <code>courses/</code> directory next to <code>platform/</code>.
        </div>
      ) : (
        <CourseBrowser courses={lite} />
      )}
    </div>
  );
}
