const demos = [
  { number: "01", label: "THE RECORDER", title: "A task. A few clicks. The full picture.", detail: "From opening the menu bar app to reviewing a session.", art: "recorder" },
  { number: "02", label: "THE WORKFLOW", title: "Follow the evidence, step by step.", detail: "See how screen states become an editable workflow.", art: "workflow" },
  { number: "03", label: "THE DEPENDENCIES", title: "Find what happens behind the screen.", detail: "Explore the requests observed during a task.", art: "network" },
];

export function DemoLibrary() {
  return <div className="demo-grid">{demos.map((demo) => <article className="demo-card" key={demo.number}>
    <div className={`demo-art demo-art-${demo.art}`} aria-hidden="true"><span className="demo-coming">WALKTHROUGH COMING SOON</span>{demo.art === "recorder" ? <div className="demo-recorder"><span>↶ retrace</span><div><i /> Acme Desktop <b>⌄</b></div><div className="demo-record-button"><i /> Start recording</div></div> : demo.art === "workflow" ? <div className="demo-flow"><span>Screen A</span><b>→</b><span className="orange-node">Action</span><b>→</b><span>Screen B</span></div> : <div className="demo-network"><span>App</span><b>↗<br />↘</b><div><span>/settings</span><span>/profile</span></div></div>}<span className="demo-number">{demo.number}</span></div>
    <div className="demo-card-copy"><span>{demo.label}</span><h3>{demo.title}</h3><p>{demo.detail}</p></div>
  </article>)}</div>;
}
