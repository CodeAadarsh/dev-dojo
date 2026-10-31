import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import rehypeHighlight from 'rehype-highlight';

/**
 * Server-rendered Markdown. We deliberately use react-markdown (not MDX) so
 * that `{` braces in flags (KUBE{...}), JSON and Go templates render as
 * literal text instead of being parsed as JSX expressions.
 */
export function MarkdownView({ source }: { source: string }) {
  return (
    <div className="prose">
      <Markdown remarkPlugins={[remarkGfm]} rehypePlugins={[rehypeHighlight]}>
        {source}
      </Markdown>
    </div>
  );
}
