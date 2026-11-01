import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getModule } from '@/lib/content';
import { MarkdownView } from '@/lib/markdown';

export const dynamic = 'force-dynamic';

export default async function ModulePage({
  params,
}: {
  params: Promise<{ course: string; module: string }>;
}) {
  const { course, module } = await params;
  const data = getModule(course, module);
  if (!data) notFound();

  return (
    <article className="mx-auto max-w-3xl space-y-8">
      <Link href={`/courses/${course}`} className="text-sm text-dim transition-colors hover:text-accent">
        ← {data.course.title}
      </Link>

      <div className="glass-strong rounded-2xl px-6 py-8 sm:px-10 sm:py-10">
        <MarkdownView source={data.content} />
      </div>

      <nav className="flex flex-col gap-3 sm:flex-row sm:justify-between">
        {data.prev ? (
          <Link
            href={`/courses/${course}/modules/${data.prev.id}`}
            className="glass float rounded-xl px-5 py-3 text-sm"
          >
            <span className="block text-xs text-faint">Previous</span>
            <span className="font-medium text-ink">{data.prev.title}</span>
          </Link>
        ) : (
          <span />
        )}
        {data.next ? (
          <Link
            href={`/courses/${course}/modules/${data.next.id}`}
            className="glass float rounded-xl px-5 py-3 text-right text-sm"
          >
            <span className="block text-xs text-faint">Next</span>
            <span className="font-medium text-ink">{data.next.title}</span>
          </Link>
        ) : (
          <span />
        )}
      </nav>
    </article>
  );
}
