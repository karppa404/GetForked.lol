import "./how-it-works.css";

const steps = [
  { title: "Choose an application", purpose: "Select the application whose workflow you want to understand.", action: "Connect a local workspace and choose a target app.", network: "Local workspace connection; target application requests depend on what it does." },
  { title: "Record a workflow", purpose: "Capture the screens and actions that make up a user story.", action: "Start recording, work through the task, then stop.", network: "Only requests captured by the optional network helper can be attributed to the recording; capture may be incomplete." },
  { title: "Review and upload", purpose: "Remove sensitive evidence and decide what to share.", action: "Review frames and interactions, then explicitly upload.", network: "Upload sends the reviewed session to the configured workspace. No upload occurs until you choose it." },
  { title: "Explore the story", purpose: "Understand the sequence of screens, actions and observed calls before rebuilding.", action: "Inspect the workflow and its evidence, then hand the spec to a coding agent.", network: "Analysis and graph requests go to the workspace. Calls near an action are timing-based associations, not proof of causation." },
] as const;

export function HowItWorks() {
  return (
    <section className="lp-section hw" id="how" aria-labelledby="how-title">
      <h2 id="how-title" className="lp-h2">From a workflow to a rebuild plan</h2>
      <p className="lp-sub">A user story for the recorder and workspace. Network details are evidence-dependent.</p>
      <ol className="hw-steps" aria-label="Recording workflow">
        {steps.map((step, i) => <li className="hw-step" key={step.title}>
          <header className="hw-step-head">
            <p className="hw-step-label"><span>{String(i + 1).padStart(2, "0")}</span>User story</p>
            <h3>{step.title}</h3>
            <p className="hw-step-copy">{step.purpose}</p>
          </header>
          <div className="hw-report">
            <p className="hw-report-head"><span>Action</span><span>{step.action}</span></p>
            <p className="hw-step-copy"><strong>Network:</strong> {step.network}</p>
          </div>
        </li>)}
      </ol>
      <p className="hw-step-copy"><a href="#spec">See the spec sheet ↓</a></p>
    </section>
  );
}
