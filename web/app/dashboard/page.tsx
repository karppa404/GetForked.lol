import type { Metadata } from "next";
import "./dashboard.css";
import { DashboardApp } from "@/components/dashboard/dashboard-app";

export const metadata: Metadata = {
  title: "Workspace · Retrace",
  robots: { index: false, follow: false },
};

export default function Dashboard() {
  return <DashboardApp />;
}
