// Static HTML illustration of the workspace (no images, no client JS). Fictional content.
const EVENTS = [
  ["00:02", "Click · New invoice", "AXButton"],
  ["00:03", "Screenshot", "Invoice editor"],
  ["00:05", "GET /api/clients", "200 · api.ledgerly.test"],
  ["00:07", "Click · Add line", "AXButton"],
  ["00:08", "POST /api/invoices", "201 · api.ledgerly.test"],
];

export function WorkspaceShowcase() {
  return (
    <figure className="lp-show">
      <div className="lp-window" aria-hidden="true">
        <div className="lp-window-bar"><i /><i /><i /><span>Ledgerly · Nov 3, 3:12 PM</span></div>
        <div className="lp-window-body">
          <div className="lp-w-side">
            <b>Projects</b>
            <span className="is-on">Local workspace</span>
            <span>Field Notes</span>
          </div>
          <div className="lp-w-tl">
            <b>Evidence</b>
            {EVENTS.map(([t, a, d], i) => (
              <div key={t} className={i === 3 ? "is-on" : undefined}><em>{t}</em><span>{a}<small>{d}</small></span></div>
            ))}
          </div>
          <div className="lp-w-graph">
            <div className="lp-w-tabs"><span className="is-on">Workflow</span><span>API &amp; network</span></div>
            <div className="lp-w-canvas">
              <span className="lp-gn" style={{ left: "8%", top: "18%" }}>Invoices<small>Screen · 2 sources</small></span>
              <span className="lp-gn lp-gn--action" style={{ left: "34%", top: "46%" }}>Add line item<small>Action · 3 sources</small></span>
              <span className="lp-gn" style={{ left: "62%", top: "18%" }}>Invoice draft<small>Screen · 1 source</small></span>
              <svg viewBox="0 0 100 100" preserveAspectRatio="none"><path d="M24 30 C30 30 30 56 36 56" /><path d="M58 56 C64 56 62 30 66 30" /></svg>
            </div>
          </div>
          <div className="lp-w-insp">
            <b>Action</b>
            <strong>Add line item</strong>
            <span className="lp-w-tag">Observed</span>
            <small>Supporting evidence · 3</small>
            <div className="lp-w-shot" />
            <div className="lp-w-shot lp-w-shot--b" />
          </div>
        </div>
      </div>
      <figcaption>Illustration with sample data</figcaption>
    </figure>
  );
}
