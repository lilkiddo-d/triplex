"use client";

import { useConnectModal } from "@rainbow-me/rainbowkit";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { zeroAddress, type Address } from "viem";
import { useAccount, useReadContracts, useSwitchChain } from "wagmi";
import { erc20Abi, projectTokenHooksAbi } from "@/abi";
import { activeChain, deployment, ENV } from "@/config";
import { explorerTx } from "@/config/chains";
import { QUOTE_DECIMALS } from "@/config/constants";
import { useTokenFeatures } from "@/hooks/useTokenFeatures";
import { useTx } from "@/hooks/useTx";
import { fmtBps, fmtTime, fmtUnits, safeParseUnits } from "@/lib/format";
import { Badge, Stat } from "@/components/ui";

export default function StakePage() {
  const { active, loading } = useTokenFeatures();
  if (loading) return <div className="card animate-pulse text-sm text-zinc-500">Loading…</div>;
  if (!active)
    return (
      <div className="card">
        <h1 className="text-lg font-semibold text-zinc-100">Staking is not available</h1>
        <p className="mt-1 text-sm text-zinc-400">Token features are not active on this deployment.</p>
        <Link href="/" className="mt-3 inline-block text-sm text-brand-300 underline">
          Back to products
        </Link>
      </div>
    );
  return <Staking token={ENV.projectToken as Address} hooks={deployment.projectTokenHooks} />;
}

function Staking({ token, hooks }: { token: Address; hooks: Address }) {
  const { address, isConnected, chainId } = useAccount();
  const user = address ?? zeroAddress;
  const reads = useReadContracts({
    contracts: [
      { address: hooks, abi: projectTokenHooksAbi, functionName: "stakedBalance", args: [user] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "earned", args: [user] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "feeDiscountBps", args: [user] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "pendingUnstake", args: [user] },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "unstakeCooldown" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "tier1Threshold" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "tier1DiscountBps" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "tier2Threshold" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "tier2DiscountBps" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "totalStaked" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "projectToken" },
      { address: token, abi: erc20Abi, functionName: "balanceOf", args: [user] },
      { address: token, abi: erc20Abi, functionName: "allowance", args: [user, hooks] },
      { address: token, abi: erc20Abi, functionName: "decimals" },
      { address: token, abi: erc20Abi, functionName: "symbol" },
      { address: hooks, abi: projectTokenHooksAbi, functionName: "rewardToken" },
    ],
    query: { refetchInterval: 20_000 },
  });
  const d = reads.data;
  const v = <T,>(i: number, f: T): T => (d?.[i]?.status === "success" ? (d[i].result as T) : f);
  const staked = v<bigint>(0, 0n);
  const earned = v<bigint>(1, 0n);
  const discount = v<bigint>(2, 0n);
  const pending = v<readonly [bigint, bigint]>(3, [0n, 0n]);
  const cooldown = v<bigint>(4, 7n * 86400n);
  const t1 = v<bigint>(5, 0n);
  const t1d = v<bigint>(6, 0n);
  const t2 = v<bigint>(7, 0n);
  const t2d = v<bigint>(8, 0n);
  const totalStaked = v<bigint>(9, 0n);
  const onchainToken = v<Address | undefined>(10, undefined);
  const balance = v<bigint>(11, 0n);
  const allowance = v<bigint>(12, 0n);
  const decimals = Number(v<number>(13, 18));
  const symbol = v<string>(14, "TRPX");
  const rewardToken = v<Address | undefined>(15, undefined);
  const rewardMeta = useReadContracts({
    contracts: [
      { address: rewardToken ?? zeroAddress, abi: erc20Abi, functionName: "decimals" },
      { address: rewardToken ?? zeroAddress, abi: erc20Abi, functionName: "symbol" },
    ],
    query: { enabled: !!rewardToken, staleTime: Infinity },
  });
  const rDec = rewardMeta.data?.[0]?.status === "success" ? Number(rewardMeta.data[0].result) : QUOTE_DECIMALS;
  const rSym = rewardMeta.data?.[1]?.status === "success" ? String(rewardMeta.data[1].result) : "USDG";
  const tokenMismatch = !!onchainToken && onchainToken.toLowerCase() !== token.toLowerCase();

  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 15_000);
    return () => clearInterval(t);
  }, []);
  const unlocked = pending[0] > 0n && BigInt(now) >= pending[1];

  const refetch = useCallback(() => void reads.refetch(), [reads]);
  const [stakeIn, setStakeIn] = useState("");
  const [unstakeIn, setUnstakeIn] = useState("");
  const stakeAmt = safeParseUnits(stakeIn, decimals);
  const unstakeAmt = safeParseUnits(unstakeIn, decimals);
  const approveTx = useTx(refetch);
  const stakeTx = useTx(refetch);
  const unstakeTx = useTx(refetch);
  const withdrawTx = useTx(refetch);
  const claimTx = useTx(refetch);

  const fmt = (x: bigint) => fmtUnits(x, decimals, 4);
  const days = Number(cooldown) / 86400;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-zinc-50 sm:text-3xl">Stake ${symbol}</h1>
        <p className="mt-1 max-w-2xl text-sm text-zinc-400">
          Stakers earn a share of protocol fees and get a discount on mint and redeem fees. Unstaking has a{" "}
          {days.toFixed(days % 1 ? 1 : 0)}-day cooldown; stake in cooldown stops earning and stops counting toward the
          discount immediately.
        </p>
        {tokenMismatch && (
          <p className="mt-2 text-sm text-rose-300">
            Configured NEXT_PUBLIC_PROJECT_TOKEN does not match the staking contract&apos;s token. Check configuration.
          </p>
        )}
      </div>

      <div className="card grid grid-cols-2 gap-5 sm:grid-cols-4">
        <Stat label="Your stake" value={`${fmt(staked)}`} sub={symbol} />
        <Stat label="Claimable rewards" value={fmtUnits(earned, rDec, 4)} sub={rSym} />
        <Stat label="Your fee discount" value={discount > 0n ? fmtBps(discount) : "none"} />
        <Stat label="Total staked" value={fmt(totalStaked)} sub={symbol} />
      </div>

      <div className="card">
        <h2 className="text-base font-semibold text-zinc-100">Fee discount tiers</h2>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          {[
            { name: "Tier 1", th: t1, bps: t1d },
            { name: "Tier 2", th: t2, bps: t2d },
          ].map((t) => (
            <div key={t.name} className="flex items-center justify-between rounded-lg bg-ink-950 p-3 text-sm">
              <div>
                <div className="font-semibold text-zinc-200">{t.name}</div>
                <div className="text-xs text-zinc-500">
                  {t.th === 0n ? "not configured" : `stake ≥ ${fmt(t.th)} ${symbol}`}
                </div>
              </div>
              <div className="flex items-center gap-2">
                <span className="font-mono text-zinc-200">{fmtBps(t.bps)} off</span>
                {t.th !== 0n && staked >= t.th && discount === t.bps && <Badge tone="green">Active</Badge>}
              </div>
            </div>
          ))}
        </div>
      </div>

      <div className="grid gap-6 md:grid-cols-2">
        <div className="card">
          <h2 className="text-base font-semibold text-zinc-100">Stake</h2>
          <p className="mt-1 text-xs text-zinc-500">
            Wallet: {fmt(balance)} {symbol}
          </p>
          <AmountInput value={stakeIn} onChange={setStakeIn} onMax={() => setStakeIn(fmtUnits(balance, decimals, decimals).replace(/,/g, ""))} />
          <Guard>
            {stakeAmt !== undefined && stakeAmt > 0n && allowance < stakeAmt ? (
              <button
                className="btn btn-primary mt-3 w-full"
                disabled={approveTx.pending || stakeAmt > balance}
                onClick={() =>
                  approveTx.writeContract({ address: token, abi: erc20Abi, functionName: "approve", args: [hooks, stakeAmt] })
                }
              >
                {approveTx.pending ? "Approving…" : `Approve ${symbol}`}
              </button>
            ) : (
              <button
                className="btn btn-primary mt-3 w-full"
                disabled={!stakeAmt || stakeAmt > balance || stakeTx.pending}
                onClick={() =>
                  stakeAmt &&
                  stakeTx.writeContract(
                    { address: hooks, abi: projectTokenHooksAbi, functionName: "stake", args: [stakeAmt] },
                    { onSuccess: () => setStakeIn("") },
                  )
                }
              >
                {stakeTx.pending ? "Staking…" : "Stake"}
              </button>
            )}
          </Guard>
          <TxLine tx={approveTx} />
          <TxLine tx={stakeTx} />
        </div>

        <div className="card">
          <h2 className="text-base font-semibold text-zinc-100">Unstake</h2>
          <p className="mt-1 text-xs text-zinc-500">
            Staked: {fmt(staked)} {symbol}
          </p>
          <AmountInput value={unstakeIn} onChange={setUnstakeIn} onMax={() => setUnstakeIn(fmtUnits(staked, decimals, decimals).replace(/,/g, ""))} />
          <Guard>
            <button
              className="btn btn-ghost mt-3 w-full"
              disabled={!unstakeAmt || unstakeAmt > staked || unstakeTx.pending}
              onClick={() =>
                unstakeAmt &&
                unstakeTx.writeContract(
                  { address: hooks, abi: projectTokenHooksAbi, functionName: "requestUnstake", args: [unstakeAmt] },
                  { onSuccess: () => setUnstakeIn("") },
                )
              }
            >
              {unstakeTx.pending ? "Requesting…" : `Request unstake (${days.toFixed(days % 1 ? 1 : 0)}-day cooldown)`}
            </button>
          </Guard>
          <TxLine tx={unstakeTx} />
          {pending[0] > 0n && (
            <div className="mt-4 rounded-lg bg-ink-950 p-3 text-sm">
              <div className="flex justify-between">
                <span className="text-zinc-400">In cooldown</span>
                <span className="font-mono text-zinc-200">
                  {fmt(pending[0])} {symbol}
                </span>
              </div>
              <div className="flex justify-between text-xs text-zinc-500">
                <span>Unlocks</span>
                <span>{fmtTime(pending[1])}</span>
              </div>
              <Guard>
                <button
                  className="btn btn-primary mt-3 w-full"
                  disabled={!unlocked || withdrawTx.pending}
                  onClick={() => withdrawTx.writeContract({ address: hooks, abi: projectTokenHooksAbi, functionName: "withdraw" })}
                >
                  {withdrawTx.pending ? "Withdrawing…" : unlocked ? "Withdraw" : "Still in cooldown"}
                </button>
              </Guard>
              <TxLine tx={withdrawTx} />
            </div>
          )}
        </div>
      </div>

      <div className="card flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-base font-semibold text-zinc-100">Rewards</h2>
          <p className="text-sm text-zinc-400">
            Claimable: <span className="font-mono text-zinc-200">{fmtUnits(earned, rDec, 4)} {rSym}</span>
          </p>
        </div>
        <div className="sm:w-48">
          <Guard>
            <button
              className="btn btn-primary w-full"
              disabled={earned === 0n || claimTx.pending}
              onClick={() => claimTx.writeContract({ address: hooks, abi: projectTokenHooksAbi, functionName: "claim" })}
            >
              {claimTx.pending ? "Claiming…" : "Claim"}
            </button>
          </Guard>
          <TxLine tx={claimTx} />
        </div>
      </div>
      {!isConnected && <p className="text-sm text-zinc-500">Connect a wallet to see your balances.</p>}
      {isConnected && chainId !== activeChain.id && <p className="text-sm text-amber-300">Wrong network.</p>}
    </div>
  );
}

function AmountInput({ value, onChange, onMax }: { value: string; onChange: (v: string) => void; onMax: () => void }) {
  return (
    <div className="mt-3 flex gap-2">
      <input
        className="input"
        inputMode="decimal"
        placeholder="0.0"
        value={value}
        onChange={(e) => onChange(e.target.value.replace(",", "."))}
      />
      <button className="btn btn-ghost px-3" onClick={onMax}>
        Max
      </button>
    </div>
  );
}

function Guard({ children }: { children: React.ReactNode }) {
  const { isConnected, chainId } = useAccount();
  const { openConnectModal } = useConnectModal();
  const { switchChain } = useSwitchChain();
  if (!isConnected)
    return (
      <button className="btn btn-primary mt-3 w-full" onClick={() => openConnectModal?.()}>
        Connect wallet
      </button>
    );
  if (chainId !== activeChain.id)
    return (
      <button className="btn btn-primary mt-3 w-full" onClick={() => switchChain({ chainId: activeChain.id })}>
        Switch to {activeChain.name}
      </button>
    );
  return <>{children}</>;
}

function TxLine({ tx }: { tx: ReturnType<typeof useTx> }) {
  if (!tx.hash && !tx.errorMessage) return null;
  return (
    <p className="mt-2 text-xs">
      {tx.errorMessage && <span className="block break-words text-rose-300">{tx.errorMessage}</span>}
      {tx.success && <span className="text-emerald-300">Confirmed. </span>}
      {tx.hash && (
        <a className="text-brand-300 underline" href={explorerTx(tx.hash)} target="_blank" rel="noopener noreferrer">
          View transaction
        </a>
      )}
    </p>
  );
}
