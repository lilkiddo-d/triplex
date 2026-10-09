"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import { useCallback } from "react";
import { isAddress, maxUint256, type Address } from "viem";
import { HistoryTable } from "@/components/HistoryTable";
import { TradePanel } from "@/components/TradePanel";
import {
  Badge,
  DirectionPill,
  ExplorerLink,
  LeverageBand,
  MarketBadge,
  NotDeployed,
  Stat,
  driftFromTarget,
  outsideBand,
} from "@/components/ui";
import { deployed } from "@/config";
import { useMarketStatus } from "@/hooks/useMarketStatus";
import { useProduct, type ProductView } from "@/hooks/useProducts";
import {
  fmtLeverage,
  fmtPctWad,
  fmtTime,
  fmtUsdCompact,
  fmtUsdWad,
  fmtWad,
  signClass,
} from "@/lib/format";

export default function ProductPage() {
  const params = useParams<{ address: string }>();
  const raw = params?.address ?? "";
  const valid = isAddress(raw);
  const address = valid ? (raw as Address) : undefined;
  const market = useMarketStatus();
  const { data, isLoading, error, refetch } = useProduct(address);
  const onTraded = useCallback(() => void refetch(), [refetch]);

  if (!deployed) return <NotDeployed />;
  if (!valid) return <Message title="Invalid product address" />;
  if (isLoading) return <div className="card animate-pulse text-sm text-zinc-500">Loading product…</div>;
  if (error || !data)
    return (
      <Message
        title="Product not found"
        body="This address is not a Triplex product on the active network, or the RPC is temporarily unavailable."
      />
    );

  const p = data as ProductView;
  return (
    <div className="space-y-6">
      <Link href="/" className="text-sm text-zinc-400 hover:text-zinc-200">
        ← All products
      </Link>
      <section className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-3">
            <h1 className="text-2xl font-bold text-zinc-50 sm:text-3xl">{p.symbol}</h1>
            <DirectionPill isLong={p.isLong} target={p.targetLeverage} />
            {p.paused && <Badge tone="red">Paused</Badge>}
            {!p.priceOk && <Badge tone="amber">Price unavailable</Badge>}
          </div>
          <p className="mt-1 text-sm text-zinc-400">
            {fmtWad(p.targetLeverage, 1)}x daily {p.isLong ? "long" : "short"} exposure to {p.underlyingSymbol} ·{" "}
            <ExplorerLink address={p.product} />
          </p>
        </div>
        <MarketBadge status={market} />
      </section>

      <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
        <div className="space-y-6">
          <div className="card grid grid-cols-2 gap-5 sm:grid-cols-3">
            <Stat label="NAV / share" value={p.priceOk ? fmtUsdWad(p.navPerShare, 4) : "price unavailable"} />
            <Stat
              label={`${p.underlyingSymbol} price`}
              value={p.priceOk ? fmtUsdWad(p.price, 2) : "price unavailable"}
              sub="Chainlink, in USDG"
            />
            <Stat
              label="Today"
              value={
                p.priceOk && p.snapshotNav !== 0n ? (
                  <span className={signClass(p.dailyReturn)}>{fmtPctWad(p.dailyReturn)}</span>
                ) : (
                  "-"
                )
              }
              sub={
                p.priceOk && p.snapshotPrice !== 0n ? (
                  <>
                    vs {p.underlyingSymbol}{" "}
                    <span className={signClass(p.underlyingDailyReturn)}>{fmtPctWad(p.underlyingDailyReturn)}</span>
                  </>
                ) : (
                  "no close snapshot yet"
                )
              }
            />
            <Stat label="TVL (equity)" value={p.priceOk ? fmtUsdCompact(p.equity) : "-"} />
            <Stat label="Exposure" value={p.priceOk ? fmtUsdCompact(p.exposure) : "-"} />
            <Stat
              label="Supply"
              value={fmtWad(p.totalSupply, 2)}
              sub={p.supplyCapEquity !== 0n ? `Cap ${fmtUsdCompact(p.supplyCapEquity)} equity` : "No cap"}
            />
          </div>

          <div className="card">
            <div className="flex items-baseline justify-between">
              <h2 className="text-base font-semibold text-zinc-100">Leverage</h2>
              <div className="font-mono text-sm">
                <span className={levTone(p)}>{p.priceOk ? fmtLeverage(p.leverage) : "-"}</span>
                <span className="text-zinc-500"> real · target {fmtLeverage(p.targetLeverage, 2)}</span>
              </div>
            </div>
            <div className="mt-4">
              <LeverageBand
                min={p.minLeverage}
                target={p.targetLeverage}
                max={p.maxLeverage}
                current={p.priceOk ? p.leverage : undefined}
              />
            </div>
            <p className="mt-3 text-xs text-zinc-500">
              Leverage drifts as the price moves during the day and is reset to target near the US close. If it leaves the
              band [{fmtLeverage(p.minLeverage)}, {fmtLeverage(p.maxLeverage)}] an emergency rebalance runs immediately.
            </p>
            <div className="mt-4 grid grid-cols-2 gap-4 border-t border-ink-700 pt-4 sm:grid-cols-4">
              <Stat label="Collateral" value={p.priceOk ? fmtUsdCompact(p.collateralValue) : "-"} />
              <Stat label="Debt" value={p.priceOk ? fmtUsdCompact(p.debtValue) : "-"} />
              <Stat label="LTV" value={p.priceOk ? `${fmtWad(p.ltv * 100n, 2)}%` : "-"} />
              <Stat label="Liquidation LTV" value={`${fmtWad(p.lltv * 100n, 1)}%`} sub="Morpho Blue" />
            </div>
            <p className="mt-3 text-xs text-zinc-500">
              Last close snapshot: {p.snapshotTime ? fmtTime(p.snapshotTime) : "none yet"}
              {p.snapshotNav !== 0n && ` · NAV ${fmtUsdWad(p.snapshotNav, 4)}`}
            </p>
          </div>

          <HistoryTable product={p.product} />
        </div>

        <div className="lg:sticky lg:top-20 lg:self-start">
          <TradePanel p={p} market={market} onTraded={onTraded} />
        </div>
      </div>
    </div>
  );
}

function levTone(p: ProductView) {
  if (!p.priceOk) return "text-zinc-500";
  if (p.leverage === maxUint256 || outsideBand(p.leverage, p.minLeverage, p.maxLeverage)) return "text-rose-400";
  if (driftFromTarget(p.leverage, p.targetLeverage)) return "text-amber-300";
  return "text-zinc-100";
}

function Message({ title, body }: { title: string; body?: string }) {
  return (
    <div className="card">
      <h1 className="text-lg font-semibold text-zinc-100">{title}</h1>
      {body && <p className="mt-1 text-sm text-zinc-400">{body}</p>}
      <Link href="/" className="mt-3 inline-block text-sm text-brand-300 underline">
        Back to products
      </Link>
    </div>
  );
}
