"use client";

import Link from "next/link";
import { deployed } from "@/config";
import { useMarketStatus } from "@/hooks/useMarketStatus";
import { useProducts, type ProductView } from "@/hooks/useProducts";
import { fmtLeverage, fmtPctWad, fmtUsdCompact, fmtUsdWad, fmtWad, signClass } from "@/lib/format";
import { Badge, DirectionPill, MarketBadge, NotDeployed, driftFromTarget, outsideBand } from "@/components/ui";

export default function ProductsPage() {
  const market = useMarketStatus();
  const { data, isLoading, error, dataUpdatedAt } = useProducts();
  const products = (data ?? []) as readonly ProductView[];
  const tvl = products.reduce((acc, p) => (p.priceOk ? acc + p.equity : acc), 0n);

  return (
    <div className="space-y-6">
      <section className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-zinc-50 sm:text-3xl">Leveraged stock tokens</h1>
          <p className="mt-1 max-w-2xl text-sm text-zinc-400">
            Auto-rebalancing 3x/2x long and 1x/2x short tokens on tokenized stocks. Leverage resets daily at the US
            close, so returns over more than one day differ from a multiple of the stock&apos;s return.{" "}
            <Link href="/learn" className="text-brand-300 underline underline-offset-2">
              Learn why
            </Link>
            .
          </p>
        </div>
        <div className="flex flex-col items-start gap-2 sm:items-end">
          <MarketBadge status={market} />
          {deployed && products.length > 0 && (
            <span className="text-xs text-zinc-500">
              Total TVL <span className="font-mono text-zinc-300">{fmtUsdCompact(tvl)}</span>
            </span>
          )}
        </div>
      </section>

      {!deployed ? (
        <NotDeployed />
      ) : isLoading ? (
        <div className="card animate-pulse text-sm text-zinc-500">Loading products…</div>
      ) : error ? (
        <div className="card border-rose-500/40 text-sm text-rose-300">
          Could not load products from the NAV calculator. The RPC may be rate limited; retrying automatically.
          <div className="mt-1 break-all font-mono text-xs text-zinc-500">{error.message.split("\n")[0]}</div>
        </div>
      ) : products.length === 0 ? (
        <div className="card text-sm text-zinc-400">No products have been created yet.</div>
      ) : (
        <>
          {/* Desktop table */}
          <div className="card hidden overflow-x-auto p-0 lg:block">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-ink-700 text-left text-xs uppercase tracking-wide text-zinc-500">
                  <th className="px-4 py-3 font-medium">Token</th>
                  <th className="px-4 py-3 font-medium">Direction</th>
                  <th className="px-4 py-3 text-right font-medium">NAV / share</th>
                  <th className="px-4 py-3 text-right font-medium">Leverage (target)</th>
                  <th className="px-4 py-3 text-right font-medium">Today vs underlying</th>
                  <th className="px-4 py-3 text-right font-medium">TVL</th>
                  <th className="px-4 py-3 text-right font-medium">Status</th>
                </tr>
              </thead>
              <tbody>
                {products.map((p) => (
                  <ProductRow key={p.product} p={p} marketOpen={market.mintRedeemOpen} />
                ))}
              </tbody>
            </table>
          </div>
          {/* Mobile cards */}
          <div className="grid gap-3 lg:hidden">
            {products.map((p) => (
              <ProductCard key={p.product} p={p} marketOpen={market.mintRedeemOpen} />
            ))}
          </div>
          <p className="text-xs text-zinc-500">
            Live on-chain data, refreshed every 15s
            {dataUpdatedAt ? ` · last update ${new Date(dataUpdatedAt).toLocaleTimeString()}` : ""}. &quot;Today&quot; is
            measured from the last daily close snapshot.
          </p>
        </>
      )}
    </div>
  );
}

function levClass(p: ProductView) {
  if (!p.priceOk) return "text-zinc-500";
  if (outsideBand(p.leverage, p.minLeverage, p.maxLeverage)) return "text-rose-400";
  if (driftFromTarget(p.leverage, p.targetLeverage)) return "text-amber-300";
  return "text-zinc-100";
}

function StatusCell({ p, marketOpen }: { p: ProductView; marketOpen: boolean }) {
  if (p.paused) return <Badge tone="red">Paused</Badge>;
  if (!p.priceOk) return <Badge tone="amber">Price unavailable</Badge>;
  return marketOpen ? <Badge tone="green">Open</Badge> : <Badge tone="zinc">Closed</Badge>;
}

function Perf({ p }: { p: ProductView }) {
  if (!p.priceOk) return <span className="text-zinc-500">price unavailable</span>;
  if (p.snapshotNav === 0n) return <span className="text-zinc-500">no close snapshot yet</span>;
  return (
    <span className="whitespace-nowrap">
      <span className={`font-mono ${signClass(p.dailyReturn)}`}>{fmtPctWad(p.dailyReturn)}</span>
      <span className="text-zinc-500"> vs {p.underlyingSymbol} </span>
      <span className={`font-mono ${signClass(p.underlyingDailyReturn)}`}>{fmtPctWad(p.underlyingDailyReturn)}</span>
    </span>
  );
}

function ProductRow({ p, marketOpen }: { p: ProductView; marketOpen: boolean }) {
  const href = `/product/${p.product}`;
  return (
    <tr className="border-b border-ink-800 last:border-0 hover:bg-ink-850">
      <td className="px-4 py-3">
        <Link href={href} className="block">
          <div className="font-semibold text-zinc-50">{p.symbol}</div>
          <div className="text-xs text-zinc-500">
            {p.underlyingSymbol}
            {p.priceOk && <span className="font-mono"> · ${fmtWad(p.price, 2, 2)}</span>}
          </div>
        </Link>
      </td>
      <td className="px-4 py-3">
        <DirectionPill isLong={p.isLong} target={p.targetLeverage} />
      </td>
      <td className="px-4 py-3 text-right font-mono">{p.priceOk ? fmtUsdWad(p.navPerShare, 4) : <span className="text-zinc-500">price unavailable</span>}</td>
      <td className="px-4 py-3 text-right font-mono">
        <span className={levClass(p)}>{p.priceOk ? fmtLeverage(p.leverage) : "-"}</span>
        <span className="text-zinc-500"> ({fmtLeverage(p.targetLeverage, 1)})</span>
      </td>
      <td className="px-4 py-3 text-right">
        <Perf p={p} />
      </td>
      <td className="px-4 py-3 text-right font-mono">{p.priceOk ? fmtUsdCompact(p.equity) : "-"}</td>
      <td className="px-4 py-3 text-right">
        <div className="flex items-center justify-end gap-3">
          <StatusCell p={p} marketOpen={marketOpen} />
          <Link href={href} className="btn btn-ghost px-3 py-1.5 text-xs">
            Trade
          </Link>
        </div>
      </td>
    </tr>
  );
}

function ProductCard({ p, marketOpen }: { p: ProductView; marketOpen: boolean }) {
  return (
    <Link href={`/product/${p.product}`} className="card block hover:border-zinc-500">
      <div className="flex items-start justify-between gap-2">
        <div>
          <div className="text-lg font-semibold text-zinc-50">{p.symbol}</div>
          <div className="mt-0.5 flex items-center gap-2 text-xs text-zinc-500">
            <DirectionPill isLong={p.isLong} target={p.targetLeverage} />
            {p.underlyingSymbol}
          </div>
        </div>
        <StatusCell p={p} marketOpen={marketOpen} />
      </div>
      <div className="mt-4 grid grid-cols-2 gap-3 text-sm">
        <div>
          <div className="label">NAV / share</div>
          <div className="font-mono">{p.priceOk ? fmtUsdWad(p.navPerShare, 4) : <span className="text-zinc-500">price unavailable</span>}</div>
        </div>
        <div>
          <div className="label">Leverage</div>
          <div className="font-mono">
            <span className={levClass(p)}>{p.priceOk ? fmtLeverage(p.leverage) : "-"}</span>
            <span className="text-zinc-500"> / {fmtLeverage(p.targetLeverage, 1)}</span>
          </div>
        </div>
        <div>
          <div className="label">Today</div>
          <Perf p={p} />
        </div>
        <div>
          <div className="label">TVL</div>
          <div className="font-mono">{p.priceOk ? fmtUsdCompact(p.equity) : "-"}</div>
        </div>
      </div>
    </Link>
  );
}
