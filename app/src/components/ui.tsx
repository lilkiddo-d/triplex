"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import { maxUint256 } from "viem";
import { activeChain, deployment } from "@/config";
import { explorerAddress } from "@/config/chains";
import type { MarketStatus } from "@/hooks/useMarketStatus";
import { fmtWad, wadToNum } from "@/lib/format";

export function MarketBadge({ status }: { status: MarketStatus }) {
  if (status.loading) return <Badge tone="zinc">Checking market…</Badge>;
  if (!status.known) return <Badge tone="zinc">Market status unknown</Badge>;
  if (status.mintRedeemOpen) return <Badge tone="green">Market open · mint/redeem live</Badge>;
  if (status.marketOpen) return <Badge tone="amber">Market open · mint/redeem paused (open/close buffer)</Badge>;
  return <Badge tone="red">Market closed · mint/redeem 09:35–15:45 ET</Badge>;
}

export function Badge({ tone, children }: { tone: "green" | "amber" | "red" | "zinc" | "brand"; children: ReactNode }) {
  const tones = {
    green: "border-emerald-500/40 bg-emerald-500/10 text-emerald-300",
    amber: "border-amber-500/40 bg-amber-500/10 text-amber-300",
    red: "border-rose-500/40 bg-rose-500/10 text-rose-300",
    zinc: "border-zinc-600/50 bg-zinc-700/20 text-zinc-300",
    brand: "border-brand-500/40 bg-brand-500/10 text-brand-300",
  } as const;
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium ${tones[tone]}`}>
      {tone === "green" && <span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />}
      {children}
    </span>
  );
}

export function NotDeployed() {
  return (
    <div className="card border-amber-500/40 bg-amber-500/5">
      <h2 className="text-base font-semibold text-amber-200">Triplex is not deployed on {activeChain.name} yet</h2>
      <p className="mt-1 text-sm text-zinc-400">
        No factory address is configured for chain id {activeChain.id} in{" "}
        <code className="font-mono text-zinc-300">src/config/deployments/{activeChain.id}.json</code>. The deploy script
        writes this file; products will appear here once it has run.
      </p>
      <p className="mt-2 text-sm text-zinc-400">
        Meanwhile, read <Link className="text-brand-300 underline" href="/learn">how leveraged tokens work</Link> and the{" "}
        <Link className="text-brand-300 underline" href="/risk">risk disclosure</Link>.
      </p>
    </div>
  );
}

export function Stat({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return (
    <div className="min-w-0">
      <div className="label">{label}</div>
      <div className="mt-1 truncate font-mono text-lg text-zinc-100">{value}</div>
      {sub && <div className="mt-0.5 text-xs text-zinc-500">{sub}</div>}
    </div>
  );
}

export function ExplorerLink({ address, children }: { address: string; children?: ReactNode }) {
  return (
    <a
      href={explorerAddress(address)}
      target="_blank"
      rel="noopener noreferrer"
      className="font-mono text-brand-300 hover:underline"
    >
      {children ?? `${address.slice(0, 6)}…${address.slice(-4)}`}
    </a>
  );
}

export function DirectionPill({ isLong, target }: { isLong: boolean; target: bigint }) {
  return (
    <span
      className={`rounded-md px-2 py-0.5 text-xs font-semibold ${
        isLong ? "bg-emerald-500/15 text-emerald-300" : "bg-rose-500/15 text-rose-300"
      }`}
    >
      {fmtWad(target, 1)}x {isLong ? "Long" : "Short"}
    </span>
  );
}

/** True when real leverage is outside [min, max] (or there is no equity). */
export function outsideBand(lev: bigint, min: bigint, max: bigint): boolean {
  return lev === maxUint256 || lev < min || lev > max;
}

/** True when real leverage deviates more than 10% from target (inside the band). */
export function driftFromTarget(lev: bigint, target: bigint): boolean {
  if (target === 0n) return false;
  const diff = lev > target ? lev - target : target - lev;
  return diff * 10n > target;
}

/** Leverage band: min .. max with target tick and current marker. */
export function LeverageBand({
  min,
  target,
  max,
  current,
}: {
  min: bigint;
  target: bigint;
  max: bigint;
  current?: bigint;
}) {
  // Display range: a little beyond the band on both sides.
  const lo = wadToNum(min) * 0.85;
  const hi = wadToNum(max) * 1.1;
  const pos = (v: number) => Math.min(100, Math.max(0, ((v - lo) / (hi - lo)) * 100));
  const minN = wadToNum(min);
  const maxN = wadToNum(max);
  const tgtN = wadToNum(target);
  const noEquity = current === maxUint256;
  const curN = current !== undefined && !noEquity ? wadToNum(current) : undefined;
  const out = current !== undefined && outsideBand(current, min, max);

  return (
    <div>
      <div className="relative h-10">
        <div className="absolute top-4 h-2 w-full rounded-full bg-rose-500/20" />
        <div
          className="absolute top-4 h-2 rounded-full bg-emerald-500/30"
          style={{ left: `${pos(minN)}%`, width: `${pos(maxN) - pos(minN)}%` }}
        />
        <div className="absolute top-2.5 h-5 w-0.5 bg-zinc-300" style={{ left: `${pos(tgtN)}%` }} title="Target" />
        {(curN !== undefined || noEquity) && (
          <div
            className="absolute top-0 -translate-x-1/2"
            style={{ left: `${noEquity ? 100 : pos(curN as number)}%` }}
            title="Current leverage"
          >
            <div className={`h-0 w-0 border-x-[6px] border-t-[8px] border-x-transparent ${out ? "border-t-rose-400" : "border-t-brand-400"}`} />
          </div>
        )}
      </div>
      <div className="relative h-5 text-[11px] text-zinc-500">
        <span className="absolute -translate-x-1/2" style={{ left: `${pos(minN)}%` }}>
          min {minN.toFixed(2)}x
        </span>
        <span className="absolute -translate-x-1/2 text-zinc-300" style={{ left: `${pos(tgtN)}%` }}>
          {tgtN.toFixed(2)}x
        </span>
        <span className="absolute -translate-x-1/2" style={{ left: `${pos(maxN)}%` }}>
          max {maxN.toFixed(2)}x
        </span>
      </div>
    </div>
  );
}

export function ChainNote() {
  return deployment.chainId !== activeChain.id ? (
    <p className="text-xs text-amber-300">Deployment file chain id mismatch.</p>
  ) : null;
}
