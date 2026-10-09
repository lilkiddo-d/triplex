import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = { title: "Not available in your region" };

export default function BlockedPage() {
  return (
    <div className="mx-auto max-w-xl py-16 text-center">
      <h1 className="text-2xl font-bold text-zinc-50">Not available in your region</h1>
      <p className="mt-3 text-sm text-zinc-400">
        Triplex is not available to persons located in or residents of your jurisdiction. This interface cannot be
        used from your current location.
      </p>
      <p className="mt-6 text-xs text-zinc-500">
        <Link href="/risk" className="text-brand-300 underline">
          Risk disclosure
        </Link>
      </p>
    </div>
  );
}
