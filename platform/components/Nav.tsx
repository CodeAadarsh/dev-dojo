import Link from 'next/link';

export function Nav() {
  return (
    <header className="sticky top-0 z-20 border-b border-border bg-panel2/90 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-5xl items-center justify-between px-5">
        <Link href="/" className="flex items-center gap-1.5 font-bold tracking-tight">
          <span className="text-green">⎈</span>
          <span className="text-white">KUBE</span>
          <span className="text-green">-DOJO</span>
        </Link>
        <nav className="flex gap-5 text-sm text-dim">
          <Link href="/" className="hover:text-white">Courses</Link>
          <a href="https://kubernetes.io/docs/reference/kubectl/" target="_blank" rel="noreferrer" className="hover:text-white">
            kubectl ref ↗
          </a>
        </nav>
      </div>
    </header>
  );
}
