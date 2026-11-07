import { existsSync } from "node:fs";
import path from "node:path";
import Link from "next/link";
import { DEMO_POSTER, DEMO_VIDEO } from "@/components/landing/demo-assets";
import { DemoVideo } from "@/components/landing/demo-video";
import { WorkspaceShowcase } from "@/components/landing/showcase";
import "./landing.css";

const hasFile = (p: string) => existsSync(path.join(process.cwd(), "public", p));

const STEPS = [
  { n: "1", title: "Observe", body: "Pick an app on your Mac and keep working. The recorder captures interactions and screenshots. Network evidence can be imported from the separate capture helper." },
  { n: "2", title: "Review", body: "When you stop, go through the evidence and leave out anything sensitive. Nothing is uploaded until you choose to." },
  { n: "3", title: "Map", body: "Analysis builds a workflow and an API graph. Every node and edge links back to the evidence it came from." },
];

const DETAILS = [
  { title: "Local by default", body: "The workspace and API run on loopback. There’s no account to create and no remote access." },
  { title: "Explicit upload", body: "Recordings stay on disk until you review them and choose to analyze." },
  { title: "Honest network states", body: "Observed, none observed and not captured are three different things, and Retrace shows them that way." },
  { title: "Corrections that last", body: "Rename any node or edge. Your labels are stored separately and survive re-runs." },
  { title: "Live across windows", body: "SpacetimeDB subscriptions keep every open workspace in sync while you review." },
  { title: "FigJam-ready export", body: "Download validated Graph v1 JSON and import it with the Retrace FigJam plugin." },
];

export default function Home() {
  const demoAvailable = hasFile(DEMO_VIDEO) && hasFile(DEMO_POSTER);
  return (
    <div className="lp">
      <a className="lp-skip" href="#main">Skip to content</a>
      <header className="lp-nav">
        <div className="lp-nav-inner">
          <Link href="/" className="lp-wordmark">Retrace</Link>
          <nav aria-label="Sections" className="lp-nav-links">
            <a href="#demo">Demo</a>
            <a href="#how">How it works</a>
            <a href="#graphs">Graphs</a>
            <a href="#details">Details</a>
          </nav>
          <Link href="/dashboard" className="lp-btn lp-btn--light lp-btn--small">Open workspace</Link>
        </div>
      </header>

      <main id="main">
        <section className="lp-hero">
          <p className="lp-kicker">Runs locally on macOS</p>
          <h1>See how an app works<br />by using it.</h1>
          <p className="lp-lede">Retrace watches an app while you work, then maps its screens, actions and API calls. Every connection is backed by evidence you reviewed.</p>
          <div className="lp-actions">
            <Link href="/dashboard" className="lp-btn lp-btn--light">Open workspace</Link>
            <a href="#demo" className="lp-btn lp-btn--ghost">Watch the demo</a>
          </div>
          <WorkspaceShowcase />
        </section>

        <section className="lp-section" id="demo" aria-labelledby="demo-title">
          <div className="lp-head">
            <h2 id="demo-title">One recording, start to finish.</h2>
            <p>From choosing an app to a reviewed, evidence-linked workflow.</p>
          </div>
          <DemoVideo available={demoAvailable} />
        </section>

        <section className="lp-section" id="how" aria-labelledby="how-title">
          <div className="lp-head">
            <h2 id="how-title">Observe. Review. Map.</h2>
            <p>You do the work. Retrace keeps the record.</p>
          </div>
          <ol className="lp-steps">
            {STEPS.map((s) => (
              <li key={s.n}>
                <span className="lp-step-n" aria-hidden="true">{s.n}</span>
                <h3>{s.title}</h3>
                <p>{s.body}</p>
              </li>
            ))}
          </ol>
        </section>

        <section className="lp-section" id="graphs" aria-labelledby="graphs-title">
          <div className="lp-head">
            <h2 id="graphs-title">Two graphs, one source of truth.</h2>
            <p>Switch between the workflow you followed and the requests behind it.</p>
          </div>
          <div className="lp-rows">
            <article className="lp-row">
              <div className="lp-row-copy">
                <h3>Workflow</h3>
                <p>Screens and actions in the order you used them. Select any step to see the clicks and before/after screenshots behind it.</p>
              </div>
              <div className="lp-panel" aria-hidden="true">
                <div className="lp-flow">
                  <span className="lp-node">Invoices</span><i />
                  <span className="lp-node lp-node--action">New invoice</span><i />
                  <span className="lp-node">Invoice editor</span>
                </div>
              </div>
            </article>
            <article className="lp-row lp-row--flip">
              <div className="lp-row-copy">
                <h3>API &amp; network</h3>
                <p>Endpoints linked to actions observed near them. Links inferred from timing are marked as candidates, never presented as fact.</p>
              </div>
              <div className="lp-panel" aria-hidden="true">
                <ul className="lp-reqs">
                  <li><b>GET</b> /api/clients <span>observed</span></li>
                  <li><b>POST</b> /api/invoices <span>observed</span></li>
                  <li className="is-candidate"><b>GET</b> /api/invoices/{"{id}"}/pdf <span>candidate</span></li>
                </ul>
              </div>
            </article>
          </div>
        </section>

        <section className="lp-section" id="details" aria-labelledby="details-title">
          <div className="lp-head">
            <h2 id="details-title">Built to be trusted.</h2>
          </div>
          <ul className="lp-grid">
            {DETAILS.map((d) => (
              <li key={d.title}>
                <h3>{d.title}</h3>
                <p>{d.body}</p>
              </li>
            ))}
          </ul>
        </section>

        <section className="lp-cta" aria-labelledby="cta-title">
          <h2 id="cta-title">Start with the app you already have.</h2>
          <p>Start the API, then open the workspace on this Mac.</p>
          <pre className="lp-code"><code>cd backend && RETRACE_DEV_AUTH=1 uv run python -m retrace</code></pre>
          <Link href="/dashboard" className="lp-btn lp-btn--light">Open workspace</Link>
        </section>
      </main>

      <footer className="lp-footer">
        <span className="lp-wordmark">Retrace</span>
        <span className="lp-dim">Runs on this Mac. Nothing leaves it unless you upload.</span>
        <a href="#main">Back to top</a>
      </footer>
    </div>
  );
}
