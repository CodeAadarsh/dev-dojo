import type { Metadata } from 'next';
import { Space_Grotesk, IBM_Plex_Sans, IBM_Plex_Mono } from 'next/font/google';
import './globals.css';
import { Nav } from '@/components/Nav';

const display = Space_Grotesk({
  subsets: ['latin'],
  weight: ['500', '600', '700'],
  variable: '--font-display-next',
  display: 'swap',
});
const sans = IBM_Plex_Sans({
  subsets: ['latin'],
  weight: ['400', '500', '600'],
  variable: '--font-sans-next',
  display: 'swap',
});
const mono = IBM_Plex_Mono({
  subsets: ['latin'],
  weight: ['400', '500'],
  variable: '--font-mono-next',
  display: 'swap',
});

export const metadata: Metadata = {
  title: 'DevDojo',
  description: 'The hands-on engineering dojo — 21 courses from Kubernetes to databases to AI. Read the guide, do the work in your terminal, capture the flag.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${display.variable} ${sans.variable} ${mono.variable}`}>
      <body>
        <div className="aurora" aria-hidden="true" />
        <div className="gridlines" aria-hidden="true">
          <span />
        </div>
        <Nav />
        <main className="relative z-10 mx-auto max-w-7xl px-5 pb-28 pt-10 sm:px-8">{children}</main>
      </body>
    </html>
  );
}
