import type { Metadata } from "next";
import "@xyflow/react/dist/style.css";
import "./dashboard.css";
import { DashboardApp } from "@/components/dashboard/dashboard-app";

export const metadata: Metadata = {
  title: "Dashboard — Retrace",
  robots: { index: false, follow: false },
};

export default function Dashboard() {
  return <DashboardApp />;
}
