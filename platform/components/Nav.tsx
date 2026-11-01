import Link from 'next/link';

export function Nav() {
  return (
    <div className="sticky top-4 z-30 px-4">
      <header className="glass-strong mx-auto flex h-14 max-w-7xl items-center justify-between rounded-2xl px-4 sm:px-5">
        <Link
          href="/"
          className="flex items-center gap-2.5 font-semibold tracking-tight text-ink"
          style={{ fontFamily: 'var(--font-display)' }}
        >
          <span
            className="grid h-8 w-8 place-items-center rounded-xl text-lg text-white"
            style={{
              background: 'linear-gradient(180deg,#4b82ef,#326ce5)',
              boxShadow: 'inset 0 1px 0 rgba(255,255,255,.4), 0 6px 16px -6px rgba(50,108,229,.7)',
            }}
          >
            ⛩
          </span>
          <span>Dev<span className="text-green">Dojo</span></span>
        </Link>
        <nav className="flex items-center gap-5 text-sm text-dim sm:gap-7">
          <Link href="/" className="transition-colors hover:text-ink">Courses</Link>
          <a
            href="https://kubernetes.io/docs/reference/kubectl/"
            target="_blank"
            rel="noreferrer"
            className="hidden transition-colors hover:text-ink sm:inline"
          >
            kubectl reference
          </a>
        </nav>
      </header>
    </div>
  );
}
