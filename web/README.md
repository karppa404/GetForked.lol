# Retrace web

Next.js App Router, React, TypeScript. Node 22.23.4+, 24.22.1+, or 26.12.1+ is recommended by the SpacetimeDB SDK.

```sh
cd web
npm ci
npm run dev
npm run build
npm run typecheck
```

The landing page is at `/`. Sign in currently routes to `/dashboard`; Google authentication is not implemented yet. The dashboard is intentionally blank in this initial landing-page milestone and will be replaced in the next milestone.

The workflow graphic is illustrative. Demo cards are placeholders for future videos, not playable recordings. No recording evidence or personal information is collected by the landing page.

Deployment: run `vercel --prod` from this directory. Existing Vercel project: `retrace-hackutd-2026`.
