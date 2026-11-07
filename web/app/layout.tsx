import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Retrace — Understand what you're rebuilding",
  description: "Turn a demonstrated workflow into a map of screens, actions, and API dependencies. Understand an existing app before you rebuild it.",
  openGraph: {
    title: "Retrace — Understand what you're rebuilding",
    description: "Show the workflow. See the system. Build what comes next.",
    type: "website",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
