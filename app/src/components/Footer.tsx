import Link from "next/link";

export function Footer() {
  return (
    <footer className="mt-16 border-t border-ink-700">
      <div className="mx-auto flex max-w-6xl flex-col gap-2 px-4 py-6 text-xs text-zinc-500 sm:flex-row sm:items-center sm:justify-between">
        <p>
          <strong className="text-zinc-400">Not investment advice.</strong> Leveraged and inverse tokens are high-risk,
          short-term instruments and can lose most or all of their value.{" "}
          <Link href="/risk" className="text-brand-300 underline underline-offset-2">
            Read the risk disclosure
          </Link>
          .
        </p>
        <p className="shrink-0">Triplex · unaudited software · use at your own risk</p>
      </div>
    </footer>
  );
}
