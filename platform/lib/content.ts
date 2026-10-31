import fs from 'node:fs';
import path from 'node:path';

/**
 * Courses live OUTSIDE the web app (each is its own git repo under ../courses).
 * The platform is only a reader: it scans this directory at request time, so
 * adding/removing a course needs no code change — just a folder with a
 * course.json. Override the location with COURSES_DIR when needed.
 */
export const COURSES_DIR = process.env.COURSES_DIR
  ? path.resolve(process.env.COURSES_DIR)
  : path.resolve(process.cwd(), '..', 'courses');

export type CourseModule = {
  id: string;
  title: string;
  order: number;
  file: string;
};

export type FlagType = 'verifier' | 'discovery';

export type Challenge = {
  slug: string;
  courseId: string;
  courseSlug: string;
  title: string;
  order: number;
  difficulty: string;
  flagType: FlagType;
  points: number;
  tags: string[];
  objective: string;
  estMinutes: number;
  dir: string;
};

export type Course = {
  id: string;
  slug: string;
  title: string;
  order: number;
  difficulty: string;
  estHours: string;
  prereqs: string[];
  description: string;
  tags: string[];
  status: string;
  dir: string;
  modules: CourseModule[];
  challenges: Challenge[];
};

function safeReadJson(file: string): Record<string, unknown> | null {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function readFileSafe(file: string): string {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return '';
  }
}

function titleFromMarkdown(file: string, fallback: string): string {
  const txt = readFileSafe(file);
  for (const line of txt.split('\n')) {
    const m = line.match(/^#\s+(.*)/);
    if (m) return m[1].trim();
  }
  return fallback;
}

function prettify(name: string): string {
  return name
    .replace(/\.md$/, '')
    .replace(/^\d+[-_]?/, '')
    .replace(/[-_]/g, ' ')
    .trim();
}

function leadingNumber(name: string): number {
  const m = name.match(/^(\d+)/);
  return m ? parseInt(m[1], 10) : 999;
}

function readModules(courseDir: string): CourseModule[] {
  const modDir = path.join(courseDir, 'modules');
  if (!fs.existsSync(modDir)) return [];
  return fs
    .readdirSync(modDir)
    .filter((f) => f.endsWith('.md'))
    .map((f) => ({
      id: f.replace(/\.md$/, ''),
      title: titleFromMarkdown(path.join(modDir, f), prettify(f)),
      order: leadingNumber(f),
      file: path.join(modDir, f),
    }))
    .sort((a, b) => a.order - b.order);
}

function readChallenges(courseDir: string, courseId: string, courseSlug: string): Challenge[] {
  const chDir = path.join(courseDir, 'challenges');
  if (!fs.existsSync(chDir)) return [];
  const out: Challenge[] = [];
  for (const d of fs.readdirSync(chDir, { withFileTypes: true })) {
    if (!d.isDirectory()) continue;
    const dir = path.join(chDir, d.name);
    const meta = safeReadJson(path.join(dir, 'challenge.json'));
    if (!meta) continue;
    out.push({
      slug: (meta.slug as string) ?? d.name,
      courseId,
      courseSlug,
      title: (meta.title as string) ?? d.name,
      order: (meta.order as number) ?? 999,
      difficulty: (meta.difficulty as string) ?? 'Medium',
      flagType: meta.flagType === 'verifier' ? 'verifier' : 'discovery',
      points: (meta.points as number) ?? 10,
      tags: (meta.tags as string[]) ?? [],
      objective: (meta.objective as string) ?? '',
      estMinutes: (meta.estMinutes as number) ?? 15,
      dir,
    });
  }
  return out.sort((a, b) => a.order - b.order);
}

export function listCourses(): Course[] {
  if (!fs.existsSync(COURSES_DIR)) return [];
  const courses: Course[] = [];
  for (const entry of fs.readdirSync(COURSES_DIR, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const dir = path.join(COURSES_DIR, entry.name);
    const meta = safeReadJson(path.join(dir, 'course.json'));
    if (!meta) continue;
    const id = (meta.id as string) ?? entry.name;
    const slug = (meta.slug as string) ?? entry.name;
    courses.push({
      id,
      slug,
      title: (meta.title as string) ?? entry.name,
      order: (meta.order as number) ?? 999,
      difficulty: (meta.difficulty as string) ?? '',
      estHours: (meta.estHours as string) ?? '',
      prereqs: (meta.prereqs as string[]) ?? [],
      description: (meta.description as string) ?? '',
      tags: (meta.tags as string[]) ?? [],
      status: (meta.status as string) ?? 'available',
      dir,
      modules: readModules(dir),
      challenges: readChallenges(dir, id, slug),
    });
  }
  return courses.sort((a, b) => a.order - b.order);
}

export function getCourse(slug: string): Course | null {
  return listCourses().find((c) => c.slug === slug || c.id === slug) ?? null;
}

export function getModule(courseSlug: string, moduleId: string) {
  const course = getCourse(courseSlug);
  if (!course) return null;
  const idx = course.modules.findIndex((m) => m.id === moduleId);
  if (idx === -1) return null;
  const module = course.modules[idx];
  return {
    course,
    module,
    content: readFileSafe(module.file),
    prev: idx > 0 ? course.modules[idx - 1] : null,
    next: idx < course.modules.length - 1 ? course.modules[idx + 1] : null,
  };
}

export function getChallenge(courseSlug: string, slug: string) {
  const course = getCourse(courseSlug);
  if (!course) return null;
  const challenge = course.challenges.find((c) => c.slug === slug);
  if (!challenge) return null;
  const hintsRaw = safeReadJson(path.join(challenge.dir, 'hints.json'));
  const hints = Array.isArray(hintsRaw) ? (hintsRaw as string[]) : [];
  return {
    course,
    challenge,
    brief: readFileSafe(path.join(challenge.dir, 'brief.md')),
    solution: readFileSafe(path.join(challenge.dir, 'solution.md')),
    hints,
    hasVerify: fs.existsSync(path.join(challenge.dir, 'verify.sh')),
    hasSetup: fs.existsSync(path.join(challenge.dir, 'setup.sh')),
  };
}

export function readFlagHash(courseSlug: string, slug: string): string | null {
  const course = getCourse(courseSlug);
  const challenge = course?.challenges.find((c) => c.slug === slug);
  if (!challenge) return null;
  const h = readFileSafe(path.join(challenge.dir, 'flag.sha256')).trim();
  return h || null;
}
