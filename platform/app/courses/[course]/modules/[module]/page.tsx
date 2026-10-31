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
    <article className="space-y-6">
      <Link href={`/courses/${course}`} className="text-sm text-dim hover:text-green">
        ← {data.course.title}
      </Link>
      <MarkdownView source={data.content} />
      <nav className="flex justify-between border-t border-border pt-4 text-sm">
        {data.prev ? (
          <Link href={`/courses/${course}/modules/${data.prev.id}`} className="text-green hover:underline">
            ← {data.prev.title}
          </Link>
        ) : (
          <span />
        )}
        {data.next ? (
          <Link href={`/courses/${course}/modules/${data.next.id}`} className="text-green hover:underline">
            {data.next.title} →
          </Link>
        ) : (
          <span />
        )}
      </nav>
    </article>
  );
}
