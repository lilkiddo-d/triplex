/** Original Triplex mark: three ascending bars inside a rounded square, plus the wordmark. */
export function Logo({ className = "" }: { className?: string }) {
  return (
    <span className={`inline-flex items-center gap-2 ${className}`}>
      <svg width="28" height="28" viewBox="0 0 32 32" aria-hidden="true">
        <defs>
          <linearGradient id="tpx-g" x1="0" y1="1" x2="1" y2="0">
            <stop offset="0" stopColor="#6a48f0" />
            <stop offset="1" stopColor="#22d3ee" />
          </linearGradient>
        </defs>
        <rect x="1" y="1" width="30" height="30" rx="8" fill="#12151d" stroke="url(#tpx-g)" strokeWidth="2" />
        <rect x="8" y="17" width="4" height="8" rx="1.5" fill="url(#tpx-g)" />
        <rect x="14" y="12" width="4" height="13" rx="1.5" fill="url(#tpx-g)" />
        <rect x="20" y="7" width="4" height="18" rx="1.5" fill="url(#tpx-g)" />
      </svg>
      <span className="text-lg font-bold tracking-tight text-zinc-50">
        Triple<span className="text-brand-400">x</span>
      </span>
    </span>
  );
}
