# Solution: Middleware Auth Guard

## The implementation

```typescript
// src/middleware.ts
export function middleware(req: {
  url: string;
  cookies: { get(name: string): { value: string } | undefined };
}): { redirect: string } | { next: true } {
  const { pathname } = new URL(req.url);

  // Static assets and Next.js internals — never guard these.
  // Guarding /_next/ causes an infinite redirect loop as the browser tries to
  // load the JS bundle that contains the page that contains the redirect logic.
  if (
    pathname.startsWith("/_next/") ||
    pathname.startsWith("/api/") ||
    pathname === "/favicon.ico"
  ) {
    return { next: true };
  }

  // Explicitly public pages
  const publicPaths = ["/", "/login", "/signup"];
  if (publicPaths.includes(pathname)) {
    return { next: true };
  }

  // Protected prefixes
  const protectedPrefixes = ["/dashboard", "/settings", "/account", "/admin"];
  const isProtected = protectedPrefixes.some(
    (prefix) => pathname === prefix || pathname.startsWith(prefix + "/")
  );

  if (isProtected) {
    const session = req.cookies.get("session");
    if (!session?.value) {
      return { redirect: "/login" };
    }
  }

  return { next: true };
}
```

## Why each decision

**`/_next/` first.** The router itself delivers JS, CSS, and image-optimised assets under `/_next/`. If you redirect those, the browser will 307 the bundle file and the page never loads — a silent infinite loop in the browser devtools. Always skip static assets before any auth logic.

**`/api/` skip.** API routes have their own auth (Bearer tokens, NextAuth callbacks, etc.). Running cookie-based middleware on them is either redundant or breaks OAuth flows where the callback lands on `/api/auth/callback` before the session is set.

**Prefix match with the `/` suffix check.** `pathname.startsWith("/settings")` matches both `/settings` and `/settingsX`. The `=== prefix || startsWith(prefix + "/")` pattern avoids false matches on paths that happen to share a prefix string but are not under that route tree.

**Return `{ redirect }` / `{ next: true }` not a `NextResponse`.** The challenge tests the *logic* in isolation, decoupled from the Next.js runtime. In real middleware you would `return NextResponse.redirect(new URL("/login", req.url))` and `return NextResponse.next()`, but the shape is identical. This is intentional — testing the pure routing logic is faster and more portable than spinning up a full Next dev server.

## Edge cases to watch in production

- **Middleware matcher config.** In a real `middleware.ts` you also export a `config.matcher` to tell Next.js which paths to run middleware on. Without it, middleware runs on every request including API routes, which can slow down SSG. The typical pattern:
  ```typescript
  export const config = {
    matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
  };
  ```
  With this matcher, the runtime never even calls your function for static assets — you get defence-in-depth.

- **Token validation vs. existence check.** This challenge checks for cookie *presence*. Production middleware should verify the JWT signature (or validate against your session store) because an attacker can trivially set a `session` cookie with an arbitrary value. `next-auth`'s `withAuth` or a JWT `verify()` call belongs here.

- **Redirect loops.** Always test `/login` and `/` with your guard active. A redirect of `/login` → `/login` burns out the browser after ~20 hops and shows a generic "ERR_TOO_MANY_REDIRECTS" — one of the most confusing prod incidents to debug.
