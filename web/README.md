# Retrace web

The Retrace website: a single landing page at `/` whose job is the **Download for Mac** link (`https://github.com/karppa404/HackUTD-2026/releases/download/v0.1.0-alpha.4/Retrace-macOS-arm64.zip`, macOS 14+ on Apple Silicon). It is pinned to a tag because every release is a prerelease, so `releases/latest/download/...` returns 404; bump `VERSION` in `app/page.tsx` on each release. Next.js App Router, React, TypeScript. It is fully static and never calls the Retrace API.

There is no web dashboard any more. Apps, the agent trace, API docs, Export UI flow and the FigJam board link live in the Mac app's menu bar panel (see `macos/`).

## Run it locally

Node 22.23.4+, 24.22.1+ or 26.12.1+.

```sh
cd web
npm ci
npm run dev -- --hostname 127.0.0.1                # http://127.0.0.1:3000

npm test            # vitest: demo player (jsdom)
npm run typecheck
npm run build
```

## Deploying to Vercel

Import the repository into Vercel with `web` as the root directory and deploy with the Next.js defaults. Enable **Web Analytics** and **Speed Insights** in the project dashboard. Download clicks are tracked by location; custom events require a Pro or Enterprise plan.

GitHub Actions runs **Web CI** (install, tests, typecheck and production build) on pushes and pull requests. Once the repository is connected to Vercel, Vercel creates preview deployments for branch pushes and deploys the configured production branch automatically. These run independently of the GitHub check; require **Web CI / web** in GitHub branch protection if merges should wait for it.

### GoDaddy DNS

Add `getforked.lol` and `www.getforked.lol` under Vercel **Settings → Domains**, and choose the primary domain and redirect. In GoDaddy **Domain Portfolio → DNS → DNS Records**, disable domain forwarding and configure the records Vercel displays: an A record for `@` and a CNAME for `www`. Remove conflicting records for those names. Vercel's general-purpose examples are `76.76.21.21` for the A record and `cname.vercel-dns-0.com` for the CNAME, but use the project-specific values shown by Vercel. Add a verification TXT record if Vercel requests one. Keep existing mail and other unrelated DNS records. Vercel verifies DNS and provisions the certificate after the records propagate.

## Landing page and demo video

`/` is made of static server components. Its only client code is the demo player. The player shows `public/demo/poster.webp` and mounts `public/demo/retrace-demo.mp4` (`controls`, `playsInline`, `preload="none"`) only after you press **Play demo**, so the page downloads no video until then. If either file is missing at build time, the section says so instead of showing a broken player. Fonts are system fonts, and nothing loads from a remote host.

## Rebuild the edited demo

`web/public/demo/retrace-demo.mp4` is a silent 22-second H.264 edit with fast-start metadata, a WebP poster, and English captions. It combines reviewed native UI captures, an actual app-scoped Mail settings frame, and a clearly labeled separate synthetic fixture analyzed by Nemotron. Mail evidence was not sent to inference. The original UI captures remain in the ignored `release/demo-source/` directory.

To reproduce on macOS with FFmpeg installed: `uv run --with pillow python scripts/edit-demo.py release/demo-source` from the repository root. The renderer checks codec, size and duration with ffprobe. Rebuild Next.js after replacing the assets.
