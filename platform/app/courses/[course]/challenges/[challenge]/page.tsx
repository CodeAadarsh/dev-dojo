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

function Step({ n, title }: { n: number; title: string }) {
  return (
    <div className="mb-3 flex items-center gap-3">
      <span
        className="grid h-7 w-7 place-items-center rounded-full text-xs font-semibold text-white"
        style={{ background: 'linear-gradient(180deg,#4b82ef,#326ce5)', boxShadow: '0 6px 14px -6px rgba(50,108,229,.7)' }}
      >
        {n}
      </span>
      <h2 className="text-lg font-semibold text-ink" style={{ fontFamily: 'var(--font-display)' }}>
        {title}
      </h2>
    </div>
  );
}

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

  const root = path.resolve(COURSES_DIR, '..');
  const rel = path.relative(root, ch.dir);
  const setupCmd = `bash ${rel}/setup.sh`;
  const verifyCmd = `bash ${rel}/verify.sh`;

  let step = 0;

  return (
    <div className="space-y-10">
      <Link href={`/courses/${course}`} className="text-sm text-dim transition-colors hover:text-accent">
        ← {data.course.title}
      </Link>

      <header className="space-y-4">
        <div className="flex flex-wrap items-center gap-3">
          <h1 className="text-3xl font-semibold tracking-tight text-ink" style={{ fontFamily: 'var(--font-display)' }}>
            {ch.title}
          </h1>
          <DifficultyBadge difficulty={ch.difficulty} />
          {solved && (
            <span
              className="rounded-full px-2.5 py-0.5 text-xs font-semibold"
              style={{ color: '#0b8277', background: 'rgba(15,157,143,0.14)', border: '1px solid rgba(15,157,143,0.4)' }}
            >
              ✓ Solved
            </span>
          )}
        </div>
        {ch.objective && <p className="max-w-2xl text-pretty leading-relaxed text-dim">{ch.objective}</p>}
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
        <section>
          <Step n={(step += 1)} title="Deploy the scenario" />
          <p className="mb-3 text-sm text-dim">
            From the <code className="rounded bg-[rgba(50,108,229,0.1)] px-1.5 py-0.5 text-[var(--color-accent-ink)]">kube-dojo</code>{' '}
            root, plant this scenario into your kind cluster:
          </p>
          <CommandBlock title="setup" command={setupCmd} />
        </section>
      )}

      <section>
        <Step n={(step += 1)} title="Mission brief" />
        <div className="glass-strong rounded-2xl px-6 py-7 sm:px-8">
          <MarkdownView source={brief} />
        </div>
      </section>

      {ch.flagType === 'verifier' && hasVerify && (
        <section>
          <Step n={(step += 1)} title="Earn your flag" />
          <p className="mb-3 text-sm text-dim">
            When the cluster is in the target state, run the verifier. It inspects your live cluster and prints the
            flag only if you got it right:
          </p>
          <CommandBlock title="verify" command={verifyCmd} />
        </section>
      )}

      <section>
        <Step n={(step += 1)} title="Submit flag" />
        <div className="glass rounded-2xl p-6">
          <FlagForm courseId={ch.courseId} challengeId={key} solved={solved} />
        </div>
      </section>

      {hints.length > 0 && (
        <section className="space-y-3">
          <h2 className="text-lg font-semibold text-ink" style={{ fontFamily: 'var(--font-display)' }}>
            Hints
          </h2>
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
