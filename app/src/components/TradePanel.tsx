"use client";

import { useConnectModal } from "@rainbow-me/rainbowkit";
import Link from "next/link";
import { useCallback, useMemo, useState } from "react";
import { keccak256, toBytes, type Address } from "viem";
import { useAccount, useReadContracts, useSwitchChain } from "wagmi";
import { complianceRegistryAbi, erc20Abi, leveragedTokenAbi, projectTokenHooksAbi } from "@/abi";
import { activeChain, deployment, quoteToken } from "@/config";
import { explorerTx } from "@/config/chains";
import { isSet } from "@/config/deployments";
import { QUOTE_DECIMALS, QUOTE_SYMBOL, SHARE_DECIMALS } from "@/config/constants";
import type { MarketStatus } from "@/hooks/useMarketStatus";
import type { ProductView } from "@/hooks/useProducts";
import { useRiskAck } from "@/hooks/useRiskAck";
import { useTokenFeatures } from "@/hooks/useTokenFeatures";
import { useTx } from "@/hooks/useTx";
import { BPS, WAD, fmtBps, fmtUnits, fmtUsdWad, fmtWad, safeParseUnits } from "@/lib/format";

const ACTION_MINT = keccak256(toBytes("MINT"));
const ACTION_REDEEM = keccak256(toBytes("REDEEM"));
const QUOTE_TO_WAD = 10n ** BigInt(18 - QUOTE_DECIMALS);
const DEADLINE_SECS = 600;

/** Fee as charged on-chain: ceil(amount * bps * (BPS - discount) / BPS^2). */
function feeOf(amount: bigint, bps: bigint, discountBps: bigint): bigint {
  if (bps === 0n || discountBps >= BPS) return 0n;
  const num = amount * bps * (BPS - discountBps);
  const den = BPS * BPS;
  return (num + den - 1n) / den;
}

const deadline = () => BigInt(Math.floor(Date.now() / 1000) + DEADLINE_SECS);

export function TradePanel({
  p,
  market,
  onTraded,
}: {
  p: ProductView;
  market: MarketStatus;
  onTraded: () => void;
}) {
  const [tab, setTab] = useState<"mint" | "redeem">("mint");
  const [slippageBps, setSlippageBps] = useState(100);
  const { address, chainId, isConnected } = useAccount();
  const { active: tokenActive } = useTokenFeatures();

  const hooksSet = isSet(deployment.projectTokenHooks);
  const complianceSet = isSet(deployment.complianceRegistry);
  const user = address ?? "0x0000000000000000000000000000000000000000";

  const reads = useReadContracts({
    contracts: [
      { address: p.product, abi: leveragedTokenAbi, functionName: "balanceOf", args: [user] },
      { address: quoteToken, abi: erc20Abi, functionName: "balanceOf", args: [user] },
      { address: quoteToken, abi: erc20Abi, functionName: "allowance", args: [user, p.product] },
      { address: p.product, abi: leveragedTokenAbi, functionName: "mintBufferBps" },
      { address: p.product, abi: leveragedTokenAbi, functionName: "minMintQuote" },
      { address: deployment.projectTokenHooks, abi: projectTokenHooksAbi, functionName: "feeDiscountBps", args: [user] },
      { address: deployment.complianceRegistry, abi: complianceRegistryAbi, functionName: "isAllowed", args: [user, ACTION_MINT] },
      { address: deployment.complianceRegistry, abi: complianceRegistryAbi, functionName: "isAllowed", args: [user, ACTION_REDEEM] },
    ],
    query: { refetchInterval: 15_000 },
  });
  const r = reads.data;
  const val = <T,>(i: number, fallback: T): T => (r?.[i]?.status === "success" ? (r[i].result as T) : fallback);
  const shareBal = isConnected ? val<bigint | undefined>(0, undefined) : undefined;
  const quoteBal = isConnected ? val<bigint | undefined>(1, undefined) : undefined;
  const allowance = val<bigint>(2, 0n);
  const bufferBps = val<bigint>(3, 0n);
  const minMintQuote = val<bigint>(4, 0n);
  const discountBps = hooksSet && isConnected ? val<bigint>(5, 0n) : 0n;
  const mintAllowed = !complianceSet || !isConnected || val<boolean>(6, true);
  const redeemAllowed = !complianceSet || !isConnected || val<boolean>(7, true);

  const refetchAll = useCallback(() => {
    void reads.refetch();
    onTraded();
  }, [reads, onTraded]);

  const wrongChain = isConnected && chainId !== activeChain.id;

  return (
    <div className="card">
      <div className="mb-4 flex items-center justify-between">
        <div className="flex rounded-lg border border-ink-700 bg-ink-950 p-1">
          {(["mint", "redeem"] as const).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`rounded-md px-4 py-1.5 text-sm font-semibold capitalize ${
                tab === t ? "bg-ink-800 text-zinc-50" : "text-zinc-400 hover:text-zinc-200"
              }`}
            >
              {t}
            </button>
          ))}
        </div>
        <SlippageSetting value={slippageBps} onChange={setSlippageBps} />
      </div>

      {tab === "mint" ? (
        <MintForm
          p={p}
          market={market}
          slippageBps={slippageBps}
          quoteBal={quoteBal}
          allowance={allowance}
          bufferBps={bufferBps}
          minMintQuote={minMintQuote}
          discountBps={discountBps}
          allowed={mintAllowed}
          wrongChain={wrongChain}
          onDone={refetchAll}
        />
      ) : (
        <RedeemForm
          p={p}
          market={market}
          slippageBps={slippageBps}
          shareBal={shareBal}
          discountBps={discountBps}
          allowed={redeemAllowed}
          wrongChain={wrongChain}
          onDone={refetchAll}
        />
      )}

      <div className="mt-5 space-y-1.5 border-t border-ink-700 pt-4 text-xs text-zinc-400">
        <Row k="Your balance" v={shareBal === undefined ? "-" : `${fmtUnits(shareBal, SHARE_DECIMALS, 4)} ${p.symbol}`} />
        {shareBal !== undefined && p.priceOk && (
          <Row k="Position value" v={fmtUsdWad((shareBal * p.navPerShare) / WAD)} />
        )}
        <Row k={`${QUOTE_SYMBOL} balance`} v={quoteBal === undefined ? "-" : fmtUnits(quoteBal, QUOTE_DECIMALS, 2)} />
        <Row k="Mint fee" v={<FeeValue bps={p.mintFeeBps} discount={discountBps} show={tokenActive} />} />
        <Row k="Redeem fee" v={<FeeValue bps={p.redeemFeeBps} discount={discountBps} show={tokenActive} />} />
        <Row k="Management fee" v={`${fmtBps(p.mgmtFeeBps)} / year (streamed)`} />
        {tokenActive && (
          <p className="pt-1 text-zinc-500">
            Stake $TRPX for a fee discount{discountBps > 0n ? ` (you have ${fmtBps(discountBps)} off)` : ""}.{" "}
            <Link href="/stake" className="text-brand-300 underline">
              Stake
            </Link>
          </p>
        )}
      </div>
    </div>
  );
}

function FeeValue({ bps, discount, show }: { bps: bigint; discount: bigint; show: boolean }) {
  if (!show || discount === 0n || bps === 0n) return <>{fmtBps(bps)}</>;
  const eff = (bps * (BPS - (discount > BPS ? BPS : discount))) / BPS;
  return (
    <>
      <span className="text-zinc-500 line-through">{fmtBps(bps)}</span>{" "}
      <span className="text-emerald-300">{fmtBps(eff)}</span>
    </>
  );
}

function Row({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-3">
      <span>{k}</span>
      <span className="text-right font-mono text-zinc-200">{v}</span>
    </div>
  );
}

function SlippageSetting({ value, onChange }: { value: number; onChange: (v: number) => void }) {
  const [custom, setCustom] = useState("");
  return (
    <div className="flex items-center gap-1 text-xs text-zinc-400">
      <span className="mr-1 hidden sm:inline">Slippage</span>
      {[50, 100, 200].map((b) => (
        <button
          key={b}
          onClick={() => {
            onChange(b);
            setCustom("");
          }}
          className={`rounded-md border px-2 py-1 font-mono ${
            value === b && !custom ? "border-brand-500 text-brand-300" : "border-ink-700 hover:border-zinc-500"
          }`}
        >
          {b / 100}%
        </button>
      ))}
      <input
        aria-label="Custom slippage percent"
        inputMode="decimal"
        placeholder="%"
        value={custom}
        onChange={(e) => {
          const t = e.target.value;
          setCustom(t);
          const n = Number(t);
          if (t && Number.isFinite(n) && n > 0 && n <= 20) onChange(Math.round(n * 100));
        }}
        className="w-12 rounded-md border border-ink-700 bg-ink-950 px-1.5 py-1 font-mono text-zinc-200 outline-none focus:border-brand-500"
      />
    </div>
  );
}

function ActionGuard({
  wrongChain,
  children,
}: {
  wrongChain: boolean;
  children: React.ReactNode;
}) {
  const { isConnected } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { switchChain, isPending } = useSwitchChain();
  if (!isConnected)
    return (
      <button className="btn btn-primary w-full" onClick={() => openConnectModal?.()}>
        Connect wallet
      </button>
    );
  if (wrongChain)
    return (
      <button className="btn btn-primary w-full" disabled={isPending} onClick={() => switchChain({ chainId: activeChain.id })}>
        Switch to {activeChain.name}
      </button>
    );
  return <>{children}</>;
}

function TxStatus({ hash, pending, confirming, success, error }: {
  hash?: string;
  pending: boolean;
  confirming: boolean;
  success: boolean;
  error?: string;
}) {
  if (!hash && !error && !pending) return null;
  return (
    <div className="mt-2 text-xs">
      {pending && !confirming && <p className="text-zinc-400">Confirm in your wallet…</p>}
      {confirming && <p className="text-zinc-400">Waiting for confirmation…</p>}
      {success && <p className="text-emerald-300">Confirmed.</p>}
      {error && <p className="break-words text-rose-300">{error}</p>}
      {hash && (
        <a className="text-brand-300 underline" href={explorerTx(hash)} target="_blank" rel="noopener noreferrer">
          View transaction
        </a>
      )}
    </div>
  );
}

function blockers(p: ProductView, market: MarketStatus, allowed: boolean): string | undefined {
  if (p.paused) return "Product is paused by the guardian.";
  if (!p.priceOk) return "Oracle price unavailable; mint and redeem are disabled.";
  if (!market.known) return market.loading ? "Checking market status…" : "Market status unknown.";
  if (!market.mintRedeemOpen) return "Mint/redeem is only available 09:35–15:45 ET on NYSE trading days.";
  if (!allowed) return "This address is not on the compliance allowlist.";
  return undefined;
}

function MintForm(props: {
  p: ProductView;
  market: MarketStatus;
  slippageBps: number;
  quoteBal?: bigint;
  allowance: bigint;
  bufferBps: bigint;
  minMintQuote: bigint;
  discountBps: bigint;
  allowed: boolean;
  wrongChain: boolean;
  onDone: () => void;
}) {
  const { p, market, slippageBps, quoteBal, allowance, bufferBps, minMintQuote, discountBps, allowed, wrongChain, onDone } =
    props;
  const [input, setInput] = useState("");
  const { acknowledged, acknowledge } = useRiskAck();
  const approveTx = useTx(onDone);
  const mintTx = useTx(
    useCallback(() => {
      setInput("");
      onDone();
    }, [onDone]),
  );

  const quoteIn = safeParseUnits(input, QUOTE_DECIMALS);
  const est = useMemo(() => {
    if (quoteIn === undefined || quoteIn === 0n || !p.priceOk) return undefined;
    const fee = feeOf(quoteIn, p.mintFeeBps, discountBps);
    const net = quoteIn - fee;
    const netWad = net * QUOTE_TO_WAD;
    let shares: bigint;
    let usedWad: bigint;
    if (p.totalSupply === 0n || p.navPerShare === 0n) {
      usedWad = netWad;
      shares = netWad; // first mint: shares ~ equity (NAV starts at 1.0)
    } else {
      usedWad = (netWad * (BPS - bufferBps)) / BPS;
      shares = (usedWad * WAD) / p.navPerShare;
    }
    const minShares = (shares * (BPS - BigInt(slippageBps))) / BPS;
    const refund = p.totalSupply === 0n ? 0n : (net * bufferBps) / BPS;
    const capHit = p.supplyCapEquity !== 0n && p.equity + usedWad > p.supplyCapEquity;
    return { fee, net, shares, minShares, refund, capHit };
  }, [quoteIn, p, discountBps, bufferBps, slippageBps]);

  const block = blockers(p, market, allowed);
  const insufficient = quoteIn !== undefined && quoteBal !== undefined && quoteIn > quoteBal;
  const tooSmall = est !== undefined && est.net < minMintQuote;
  const needsApproval = quoteIn !== undefined && quoteIn > 0n && allowance < quoteIn;
  const canAct = !block && est !== undefined && !insufficient && !tooSmall && !est.capHit && est.minShares > 0n;

  return (
    <div>
      <label className="label" htmlFor="mint-amount">
        You pay ({QUOTE_SYMBOL})
      </label>
      <div className="mt-1 flex gap-2">
        <input
          id="mint-amount"
          className="input"
          inputMode="decimal"
          placeholder="0.00"
          value={input}
          onChange={(e) => setInput(e.target.value.replace(",", "."))}
        />
        <button
          className="btn btn-ghost px-3"
          disabled={quoteBal === undefined || quoteBal === 0n}
          onClick={() => quoteBal !== undefined && setInput(fmtUnits(quoteBal, QUOTE_DECIMALS, QUOTE_DECIMALS).replace(/,/g, ""))}
        >
          Max
        </button>
      </div>
      {input && quoteIn === undefined && <p className="mt-1 text-xs text-rose-300">Invalid amount</p>}

      <div className="mt-4 space-y-1.5 rounded-lg bg-ink-950 p-3 text-xs text-zinc-400">
        <Row k="Estimated shares" v={est ? `${fmtWad(est.shares, 6)} ${p.symbol}` : "-"} />
        <Row k={`Min. shares (${slippageBps / 100}% slippage)`} v={est ? fmtWad(est.minShares, 6) : "-"} />
        <Row k="NAV / share" v={p.priceOk ? fmtUsdWad(p.navPerShare, 6) : "price unavailable"} />
        <Row k="Fee" v={est ? `${fmtUnits(est.fee, QUOTE_DECIMALS, 4)} ${QUOTE_SYMBOL}` : "-"} />
        {est && est.refund > 0n && (
          <Row k={`Buffer refunded (~${fmtBps(bufferBps)})`} v={`≈ ${fmtUnits(est.refund, QUOTE_DECIMALS, 2)} ${QUOTE_SYMBOL}`} />
        )}
      </div>

      {block && <p className="mt-3 text-sm text-amber-300">{block}</p>}
      {insufficient && <p className="mt-3 text-sm text-rose-300">Insufficient {QUOTE_SYMBOL} balance.</p>}
      {tooSmall && (
        <p className="mt-3 text-sm text-rose-300">
          Minimum mint is {fmtUnits(minMintQuote, QUOTE_DECIMALS, 2)} {QUOTE_SYMBOL} after fees.
        </p>
      )}
      {est?.capHit && <p className="mt-3 text-sm text-rose-300">This mint would exceed the product supply cap.</p>}

      <div className="mt-4">
        <ActionGuard wrongChain={wrongChain}>
          {!acknowledged ? (
            <div className="rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-sm">
              <p className="text-zinc-300">
                Leveraged tokens can lose most or all of their value quickly and are meant for short holding periods.
                Read the <Link href="/risk" className="text-brand-300 underline">risk disclosure</Link> before minting.
              </p>
              <button className="btn btn-primary mt-3 w-full" onClick={acknowledge}>
                I understand the risks
              </button>
            </div>
          ) : needsApproval ? (
            <button
              className="btn btn-primary w-full"
              disabled={!canAct || approveTx.pending}
              onClick={() =>
                quoteIn !== undefined &&
                approveTx.writeContract({
                  address: quoteToken,
                  abi: erc20Abi,
                  functionName: "approve",
                  args: [p.product as Address, quoteIn],
                })
              }
            >
              {approveTx.pending ? "Approving…" : `Approve ${QUOTE_SYMBOL}`}
            </button>
          ) : (
            <button
              className="btn btn-primary w-full"
              disabled={!canAct || mintTx.pending}
              onClick={() =>
                quoteIn !== undefined &&
                est &&
                mintTx.writeContract({
                  address: p.product,
                  abi: leveragedTokenAbi,
                  functionName: "mint",
                  args: [quoteIn, est.minShares, deadline()],
                })
              }
            >
              {mintTx.pending ? "Minting…" : `Mint ${p.symbol}`}
            </button>
          )}
        </ActionGuard>
        <TxStatus {...approveTx} error={approveTx.errorMessage} />
        <TxStatus {...mintTx} error={mintTx.errorMessage} />
      </div>
    </div>
  );
}

function RedeemForm(props: {
  p: ProductView;
  market: MarketStatus;
  slippageBps: number;
  shareBal?: bigint;
  discountBps: bigint;
  allowed: boolean;
  wrongChain: boolean;
  onDone: () => void;
}) {
  const { p, market, slippageBps, shareBal, discountBps, allowed, wrongChain, onDone } = props;
  const [input, setInput] = useState("");
  const tx = useTx(
    useCallback(() => {
      setInput("");
      onDone();
    }, [onDone]),
  );

  const shares = safeParseUnits(input, SHARE_DECIMALS);
  const est = useMemo(() => {
    if (shares === undefined || shares === 0n || !p.priceOk || p.navPerShare === 0n) return undefined;
    const grossWad = (shares * p.navPerShare) / WAD;
    const gross = grossWad / QUOTE_TO_WAD;
    const fee = feeOf(gross, p.redeemFeeBps, discountBps);
    const out = gross - fee;
    const minOut = (out * (BPS - BigInt(slippageBps))) / BPS;
    return { gross, fee, out, minOut };
  }, [shares, p, discountBps, slippageBps]);

  const block = blockers(p, market, allowed);
  const insufficient = shares !== undefined && shareBal !== undefined && shares > shareBal;
  const canAct = !block && est !== undefined && !insufficient;

  return (
    <div>
      <label className="label" htmlFor="redeem-amount">
        You redeem ({p.symbol})
      </label>
      <div className="mt-1 flex gap-2">
        <input
          id="redeem-amount"
          className="input"
          inputMode="decimal"
          placeholder="0.0"
          value={input}
          onChange={(e) => setInput(e.target.value.replace(",", "."))}
        />
        <button
          className="btn btn-ghost px-3"
          disabled={shareBal === undefined || shareBal === 0n}
          onClick={() => shareBal !== undefined && setInput(fmtUnits(shareBal, SHARE_DECIMALS, SHARE_DECIMALS).replace(/,/g, ""))}
        >
          Max
        </button>
      </div>
      {input && shares === undefined && <p className="mt-1 text-xs text-rose-300">Invalid amount</p>}

      <div className="mt-4 space-y-1.5 rounded-lg bg-ink-950 p-3 text-xs text-zinc-400">
        <Row k={`Estimated ${QUOTE_SYMBOL}`} v={est ? fmtUnits(est.out, QUOTE_DECIMALS, 4) : "-"} />
        <Row k={`Min. received (${slippageBps / 100}% slippage)`} v={est ? fmtUnits(est.minOut, QUOTE_DECIMALS, 4) : "-"} />
        <Row k="NAV / share" v={p.priceOk ? fmtUsdWad(p.navPerShare, 6) : "price unavailable"} />
        <Row k="Fee" v={est ? `${fmtUnits(est.fee, QUOTE_DECIMALS, 4)} ${QUOTE_SYMBOL}` : "-"} />
      </div>
      <p className="mt-2 text-xs text-zinc-500">
        Redeeming unwinds your slice of the position through a DEX swap; execution can differ from NAV by swap costs.
      </p>

      {block && <p className="mt-3 text-sm text-amber-300">{block}</p>}
      {insufficient && <p className="mt-3 text-sm text-rose-300">Insufficient {p.symbol} balance.</p>}

      <div className="mt-4">
        <ActionGuard wrongChain={wrongChain}>
          <button
            className="btn btn-primary w-full"
            disabled={!canAct || tx.pending}
            onClick={() =>
              shares !== undefined &&
              est &&
              tx.writeContract({
                address: p.product,
                abi: leveragedTokenAbi,
                functionName: "redeem",
                args: [shares, est.minOut, deadline()],
              })
            }
          >
            {tx.pending ? "Redeeming…" : `Redeem ${p.symbol}`}
          </button>
        </ActionGuard>
        <TxStatus {...tx} error={tx.errorMessage} />
      </div>
    </div>
  );
}

