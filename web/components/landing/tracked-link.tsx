"use client";

import Link from "next/link";
import { track } from "@vercel/analytics";
import type { ComponentProps } from "react";

/** A next/link that also sends a Vercel Web Analytics custom event on click. */
export function TrackedLink({ event, location, onClick, ...props }: ComponentProps<typeof Link> & { event: string; location: string }) {
  return <Link {...props} onClick={(e) => { track(event, { location }); onClick?.(e); }} />;
}
