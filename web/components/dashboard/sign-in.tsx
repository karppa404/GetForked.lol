"use client";

import { useEffect, useRef, useState } from "react";
import { signInForDevelopment, signInWithGoogle } from "@/lib/dashboard/backend";
import type { DashboardEnvironment } from "@/lib/dashboard/config";
import { createApiClient, describeError } from "@/lib/dashboard/http";
import type { AuthSession } from "@/lib/dashboard/types";
import { Brand, Spinner } from "./ui";

interface GoogleIdentity {
  accounts: {
    id: {
      initialize(config: { client_id: string; callback: (r: { credential?: string }) => void; ux_mode?: "popup"; auto_select?: boolean }): void;
      renderButton(el: HTMLElement, options: Record<string, unknown>): void;
      cancel(): void;
    };
  };
}

const GIS_SRC = "https://accounts.google.com/gsi/client";
let gisPromise: Promise<GoogleIdentity> | null = null;

function loadGoogleIdentity(): Promise<GoogleIdentity> {
  const existing = (window as unknown as { google?: GoogleIdentity }).google;
  if (existing?.accounts?.id) return Promise.resolve(existing);
  gisPromise ??= new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = GIS_SRC;
    script.async = true;
    script.onload = () => {
      const g = (window as unknown as { google?: GoogleIdentity }).google;
      if (g?.accounts?.id) resolve(g);
      else reject(new Error("Google Identity Services did not initialize"));
    };
    script.onerror = () => {
      gisPromise = null;
      reject(new Error("Couldn’t load Google sign-in. Check your connection or content blockers."));
    };
    document.head.appendChild(script);
  });
  return gisPromise;
}

export function SignIn({ env, notice, onSignedIn, onOpenPreview }: { env: DashboardEnvironment; notice?: string; onSignedIn: (a: AuthSession) => void; onOpenPreview: () => void }) {
  const [busy, setBusy] = useState<null | "google" | "dev">(null);
  const [error, setError] = useState<string | null>(null);
  const [googleState, setGoogleState] = useState<"loading" | "ready" | "failed">("loading");
  const googleButton = useRef<HTMLDivElement>(null);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => () => abortRef.current?.abort(), []);

  const client = env.apiBaseUrl ? createApiClient({ baseUrl: env.apiBaseUrl }) : null;

  useEffect(() => {
    if (!env.googleClientId || !env.apiBaseUrl) return;
    let cancelled = false;
    loadGoogleIdentity().then(
      (google) => {
        if (cancelled || !googleButton.current) return;
        google.accounts.id.initialize({
          client_id: env.googleClientId!,
          ux_mode: "popup",
          callback: async ({ credential }) => {
            if (!credential) return setError("Google didn’t return a credential. Try again.");
            abortRef.current?.abort();
            const controller = (abortRef.current = new AbortController());
            setBusy("google");
            setError(null);
            try {
              onSignedIn(await signInWithGoogle(createApiClient({ baseUrl: env.apiBaseUrl! }), credential, controller.signal));
            } catch (e) {
              if (!controller.signal.aborted) setError(describeError(e));
            } finally {
              if (!controller.signal.aborted) setBusy(null);
            }
          },
        });
        google.accounts.id.renderButton(googleButton.current, { theme: "outline", size: "large", text: "continue_with", shape: "rectangular", width: 300 });
        setGoogleState("ready");
      },
      (e: Error) => {
        if (!cancelled) {
          setGoogleState("failed");
          setError(e.message);
        }
      },
    );
    return () => {
      cancelled = true;
    };
  }, [env.googleClientId, env.apiBaseUrl, onSignedIn]);

  async function devSignIn() {
    if (!client) return;
    abortRef.current?.abort();
    const controller = (abortRef.current = new AbortController());
    setBusy("dev");
    setError(null);
    try {
      onSignedIn(await signInForDevelopment(client, controller.signal));
    } catch (e) {
      if (!controller.signal.aborted) setError(describeError(e));
    } finally {
      if (!controller.signal.aborted) setBusy(null);
    }
  }

  return (
    <div className="rd-signin">
      <header className="rd-signin-top">
        <Brand />
        <a href="/" className="rd-topbar-link">← Back to site</a>
      </header>
      <div className="rd-signin-body">
        <section className="rd-signin-copy">
          <p className="rd-eyebrow"><span aria-hidden="true" /> YOUR WORKSPACE</p>
          <h1>Pick up where<br /><em>the evidence</em> left off.</h1>
          <p>Projects, recorded sessions, and the workflow and API maps Retrace builds from them — with every connection traceable to a screenshot, a click, or a request.</p>
        </section>
        <section className="rd-signin-panel" aria-labelledby="rd-signin-title">
          <h2 id="rd-signin-title">Sign in</h2>
          {notice && <p className="rd-signin-notice" role="status">{notice}</p>}
          <div className="rd-signin-methods">
            {env.googleClientId && (
              <div className="rd-google">
                <div ref={googleButton} className="rd-google-button" aria-busy={googleState === "loading"} />
                {googleState === "loading" && <span className="rd-muted"><Spinner label="Loading Google sign-in" /> Loading Google sign-in…</span>}
              </div>
            )}
            {env.devAuthAvailable && (
              <div className="rd-dev-auth">
                <button type="button" className="rd-btn rd-btn--primary rd-btn--wide" onClick={devSignIn} disabled={busy !== null}>
                  {busy === "dev" ? <><Spinner label="Signing in" /> Signing in…</> : <>Developer sign-in <span aria-hidden="true">↗</span></>}
                </button>
                <p className="rd-fine">Local development only. Uses <code>POST /v1/auth/dev</code> on <code>{env.apiBaseUrl}</code>; the API must be running on this machine.</p>
              </div>
            )}
            {!env.googleClientId && !env.devAuthAvailable && <p className="rd-muted">No sign-in method is configured for this deployment.</p>}
            {env.googleClientId === null && env.devAuthAvailable && <p className="rd-fine">Google sign-in appears here once <code>NEXT_PUBLIC_GOOGLE_CLIENT_ID</code> is configured.</p>}
          </div>
          {busy === "google" && <p className="rd-muted" role="status"><Spinner label="Signing in" /> Verifying with the Retrace API…</p>}
          {error && <p className="rd-form-error" role="alert">{error}</p>}
          <div className="rd-divider"><span>or</span></div>
          <button type="button" className="rd-btn rd-btn--ghost rd-btn--wide" onClick={onOpenPreview}>Explore the preview workspace</button>
          <p className="rd-fine">Sample projects and graphs only — no sign-in, recording, or analysis.</p>
        </section>
      </div>
    </div>
  );
}
