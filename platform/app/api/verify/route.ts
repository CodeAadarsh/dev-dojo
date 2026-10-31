import { NextRequest, NextResponse } from 'next/server';
import { readFlagHash } from '@/lib/content';
import { hashFlag } from '@/lib/flags';
import { recordAttempt } from '@/lib/db';

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => null);
  if (
    !body ||
    typeof body.flag !== 'string' ||
    typeof body.challengeId !== 'string' ||
    typeof body.courseId !== 'string'
  ) {
    return NextResponse.json({ error: 'bad request' }, { status: 400 });
  }

  // challengeId is `${courseId}:${slug}` — recover the slug to locate the flag file.
  const slug = body.challengeId.split(':').pop() as string;
  const stored = readFlagHash(body.courseId, slug);
  if (!stored) {
    return NextResponse.json({ error: 'no flag registered for this challenge' }, { status: 404 });
  }

  const correct = hashFlag(body.flag) === stored.toLowerCase();
  recordAttempt(body.courseId, body.challengeId, correct);
  return NextResponse.json({ correct });
}
