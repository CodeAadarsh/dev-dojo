import { createHash } from 'node:crypto';

/**
 * Canonical flag hashing. A challenge stores only the sha256 of its flag
 * (flag.sha256), never the plaintext — so the repo can be public without
 * leaking answers. Submitted flags are trimmed and lower-cased on the token
 * nothing else, then hashed and compared.
 */
export function hashFlag(flag: string): string {
  return createHash('sha256').update(flag.trim()).digest('hex');
}
