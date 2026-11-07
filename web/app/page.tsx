import Link from "next/link";
import { WorkflowPreview } from "@/components/workflow-preview";
import { DemoLibrary } from "@/components/demo-library";

function Brand() {
  return <Link className="brand" href="/" aria-label="Retrace home"><span className="brand-mark" aria-hidden="true">↶</span>retrace<span className="brand-period">.</span></Link>;
}

export default function Home() {
  return (
    <>
      <a className="skip-link" href="#main">Skip to content</a>
      <header className="site-header page-width">
        <Brand />
        <nav aria-label="Main navigation"><a href="#product">The product</a><a href="#how-it-works">How it works</a><a href="#demos">Demos <span className="soon-dot" /></a></nav>
        <Link href="/dashboard" className="nav-signin">Sign in <span aria-hidden="true">↗</span></Link>
      </header>
      <main id="main">
        <section className="hero page-width" id="product">
          <div className="hero-copy">
            <div className="eyebrow"><span /> FROM CLICK TO CLARITY</div>
            <h1>Understand it.<br />Then <em>rebuild it.</em></h1>
            <p className="hero-description">The best starting point for your next build?<br className="desktop-break" /> The app that already exists.</p>
            <p className="hero-detail">Show Retrace how it works. Turn everyday interactions into workflows and API maps your team can build from.</p>
            <div className="hero-actions"><Link href="/dashboard" className="button button-primary">Get started <span aria-hidden="true">↗</span></Link><a className="text-link" href="#how-it-works"><span className="play-icon" aria-hidden="true">▶</span> How it works</a></div>
            <div className="hero-footnote"><span aria-hidden="true">⌘</span> Made for macOS. Built for your next chapter.</div>
          </div>
          <WorkflowPreview />
        </section>
        <section className="principles page-width" aria-label="Product principles"><span>A clearer picture.<br /><b>A better place to start.</b></span><div><span aria-hidden="true">↖</span> Learn by demonstrating</div><div><span aria-hidden="true">⌘</span> Keep the evidence</div><div><span aria-hidden="true">⌁</span> Connect the dots</div></section>
        <section id="how-it-works" className="how-section page-width">
          <div className="section-intro"><div><div className="eyebrow">THE PROCESS</div><h2>From “how does this work?”<br />to “here’s how.”</h2></div><p>You know what the app does.<br />Retrace helps you understand how.</p></div>
          <div className="steps">
            <article><div className="step-top"><span>01 / SHOW</span><span aria-hidden="true">↖</span></div><h3>Do what you already do.</h3><p>Pick an app. Demonstrate a task. The macOS recorder observes the clicks, screens, and available network activity along the way.</p><div className="step-tag"><span /> Your workflow, in context</div></article>
            <article><div className="step-top"><span>02 / UNDERSTAND</span><span aria-hidden="true">⌁</span></div><h3>See the connections.</h3><p>Review your recording, then upload for analysis. Get a workflow grounded in evidence, plus API dependencies when they’re observed.</p><div className="step-tag"><span /> Every relationship has a source</div></article>
            <article><div className="step-top"><span>03 / REBUILD</span><span aria-hidden="true">↗</span></div><h3>Give your team a map.</h3><p>Review the findings together. Correct the details. Export an editable FigJam workflow to plan what comes next.</p><div className="step-tag"><span /> Shared understanding, less guessing</div></article>
          </div>
          <p className="development-note"><span /> Retrace is in development. The workflow above illustrates the experience we’re building.</p>
        </section>
        <section className="demo-section" id="demos"><div className="page-width"><div className="section-intro"><div><div className="eyebrow">A CLOSER LOOK</div><h2>A little show.<br />A lot less tell.</h2></div><p>Walkthroughs from the first click<br />to the finished workflow. Coming soon.</p></div><DemoLibrary /></div></section>
        <section className="closing-section page-width"><div className="closing-symbol" aria-hidden="true">↶</div><div><h2>The next version starts<br />with understanding this one.</h2><p>Give your rebuild a starting point.</p></div><Link href="/dashboard" className="button button-primary">Open workspace <span aria-hidden="true">↗</span></Link></section>
      </main>
      <footer className="site-footer page-width"><Brand /><span>Good software deserves a next chapter.</span><a href="#main">Back to top ↑</a><span className="footer-year">© {new Date().getFullYear()} Retrace</span></footer>
    </>
  );
}
