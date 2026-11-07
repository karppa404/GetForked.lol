import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Dashboard — Retrace",
  robots: { index: false, follow: false },
};

// shortcut: This is an intentionally blank destination until Google sign-in and the dashboard are implemented.
export default function Dashboard() {
  return <main aria-label="Retrace dashboard" className="blank-dashboard" />;
}
