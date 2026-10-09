"use client";

import type { Address } from "viem";
import { explorerTx } from "@/config/chains";
import { useRebalanceHistory, type HistoryRow } from "@/hooks/useRebalanceHistory";
import { fmtLeverage, fmtTime, fmtUsdWad, fmtWad } from "@/lib/format";
import { Badge } from "./ui";

function Kind({ r }: { r: HistoryRow }) {
  if (r.kind === "snapshot") return <Badge tone="zinc">Close snapshot</Badge>;
  if (r.mode === 2) return <Badge tone="red">Emergency rebalance</Badge>;
  return <Badge tone="brand">Daily rebalance</Badge>;
}

export function HistoryTable({ product }: { product: Address }) {
  const { data, isLoading, error, refetch, isFetching } = useRebalanceHistory(product);

  return (
    <div className="card p-0">
      <div className="flex items-center justify-between px-4 pt-4 sm:px-5">
        <h2 className="text-base font-semibold text-zinc-100">Rebalance history</h2>
        <button className="text-xs text-brand-300 hover:underline disabled:opacity-50" onClick={() => refetch()} disabled={isFetching}>
          {isFetching ? "Loading…" : "Refresh"}
        </button>
      </div>
      {isLoading ? (
        <p className="px-5 py-6 text-sm text-zinc-500">Scanning on-chain logs…</p>
      ) : error ? (
        <p className="px-5 py-6 text-sm text-rose-300">Could not load logs: {error.message.split("\n")[0]}</p>
      ) : !data || data.rows.length === 0 ? (
        <p className="px-5 py-6 text-sm text-zinc-500">No rebalances or daily snapshots yet.</p>
      ) : (
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[640px] text-sm">
            <thead>
              <tr className="border-y border-ink-700 text-left text-xs uppercase tracking-wide text-zinc-500">
                <th className="px-4 py-2 font-medium">Time</th>
                <th className="px-4 py-2 font-medium">Event</th>
                <th className="px-4 py-2 text-right font-medium">Leverage</th>
                <th className="px-4 py-2 text-right font-medium">Traded exposure</th>
                <th className="px-4 py-2 text-right font-medium">NAV / share</th>
                <th className="px-4 py-2 text-right font-medium">Underlying</th>
                <th className="px-4 py-2 text-right font-medium">Tx</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map((r) => (
                <tr key={`${r.txHash}-${r.logIndex}`} className="border-b border-ink-800 last:border-0">
                  <td className="whitespace-nowrap px-4 py-2 text-zinc-400">
                    {r.timestamp ? fmtTime(r.timestamp) : `#${r.blockNumber.toString()}`}
                  </td>
                  <td className="px-4 py-2">
                    <Kind r={r} />
                  </td>
                  <td className="whitespace-nowrap px-4 py-2 text-right font-mono">
                    {r.kind === "rebalance" ? (
                      <>
                        {fmtLeverage(r.leverageBefore)} <span className="text-zinc-500">→</span> {fmtLeverage(r.leverageAfter)}
                      </>
                    ) : (
                      <span className="text-zinc-600">-</span>
                    )}
                  </td>
                  <td className="whitespace-nowrap px-4 py-2 text-right font-mono">
                    {r.kind === "rebalance" ? (
                      <span className={r.increase ? "text-emerald-300" : "text-amber-300"}>
                        {r.increase ? "+" : "−"}${fmtWad(r.chunkWad, 2)}
                      </span>
                    ) : (
                      <span className="text-zinc-600">-</span>
                    )}
                  </td>
                  <td className="px-4 py-2 text-right font-mono">{fmtUsdWad(r.navPerShare, 4)}</td>
                  <td className="px-4 py-2 text-right font-mono">{fmtUsdWad(r.price, 2)}</td>
                  <td className="px-4 py-2 text-right">
                    <a className="text-brand-300 hover:underline" href={explorerTx(r.txHash)} target="_blank" rel="noopener noreferrer">
                      View
                    </a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {data && (
        <p className="px-4 pb-4 pt-3 text-xs text-zinc-500 sm:px-5">
          Showing up to 50 most recent events from block {data.fromBlock.toString()} to {data.toBlock.toString()}
          {data.capped ? " (lookback capped to keep requests light; older events are on the explorer)" : ""}.
        </p>
      )}
    </div>
  );
}
