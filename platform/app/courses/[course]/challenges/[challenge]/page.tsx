import path from 'node:path';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getChallenge, COURSES_DIR } from '@/lib/content';
import { challengeKey, isSolved } from '@/lib/db';
import { MarkdownView } from '@/lib/markdown';
import { DifficultyBadge, Pill } from '@/components/ui';
import { FlagForm } from '@/components/FlagForm';
import { CommandBlock } from '@/components/CommandBlock';
import { Reveal } from '@/components/Reveal';

export const dynamic = 'force-dynamic';

export default async function ChallengePage({
  params,
}: {
  params: Promise<{ course: string; challenge: string }>;
}) {
  const { course, challenge } = await params;
  const data = getChallenge(course, challenge);
  if (!data) notFound();

  const { challenge: ch, brief, solution, hints, hasVerify, hasSetup } = data;
  const key = challengeKey(ch.courseId, ch.slug);
  const solved = isSolved(key);

  // Commands are relative to the kube-dojo workspace root (COURSES_DIR/..),
  // which is where the learner runs their terminal from.
  const root = path.resolve(COURSES_DIR, '..');
  const rel = path.relative(root, ch.dir);
  const setupCmd = `bash ${rel}/setup.sh`;
  const verifyCmd = `bash ${rel}/verify.sh`;

  return (
    <div className="space-y-6">
      <Link href={`/courses/${course}`} className="text-sm text-dim hover:text-green">
        ← {data.course.title}
      </Link>

      <header className="space-y-3">
        <div className="flex flex-wrap items-center gap-3">
          <h1 className="text-2xl font-bold text-white">{ch.title}</h1>
          <DifficultyBadge difficulty={ch.difficulty} />
          {solved && (
            <span className="rounded border border-green px-2 py-0.5 text-xs text-green">SOLVED</span>
          )}
        </div>
        {ch.objective && <p className="text-dim">{ch.objective}</p>}
        <div className="flex flex-wrap gap-1.5">
          <Pill>{ch.flagType === 'verifier' ? 'verifier flag' : 'discovery flag'}</Pill>
          <Pill>{ch.points} pts</Pill>
          <Pill>~{ch.estMinutes} min</Pill>
          {ch.tags.map((t) => (
            <Pill key={t}>{t}</Pill>
          ))}
        </div>
      </header>

      {hasSetup && (
        <section className="space-y-2">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-white">1 · Deploy the scenario</h2>
          <p className="text-sm text-dim">
            From the <code className="text-green">kube-dojo</code> root, plant this scenario into your kind cluster:
          </p>
          <CommandBlock title="setup" command={setupCmd} />
        </section>
      )}

      <section className="space-y-2">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-white">
          {hasSetup ? '2 · Mission brief' : 'Mission brief'}
        </h2>
        <MarkdownView source={brief} />
      </section>

      {ch.flagType === 'verifier' && hasVerify && (
        <section className="space-y-2">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-white">3 · Earn your flag</h2>
          <p className="text-sm text-dim">
            When the cluster is in the target state, run the verifier. It inspects your live cluster and
            prints the flag <strong className="text-white">only</strong> if you got it right:
          </p>
          <CommandBlock title="verify" command={verifyCmd} />
        </section>
      )}

      <section className="space-y-3">
        <h2 className="text-sm font-semibold uppercase tracking-wide text-white">Submit flag</h2>
        <FlagForm courseId={ch.courseId} challengeId={key} solved={solved} />
      </section>

      {hints.length > 0 && (
        <section className="space-y-2">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-white">Hints</h2>
          {hints.map((h, i) => (
            <Reveal key={i} label={`Hint ${i + 1}`}>
              <MarkdownView source={h} />
            </Reveal>
          ))}
        </section>
      )}

      {solution && (
        <Reveal label="Show full solution walkthrough" danger>
          <MarkdownView source={solution} />
        </Reveal>
      )}
    </div>
  );
}
