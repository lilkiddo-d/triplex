"use client";

import { useEffect, useRef } from "react";
import { BaseError, ContractFunctionRevertedError, type Hash } from "viem";
import { useWaitForTransactionReceipt, useWriteContract } from "wagmi";

/** Thin wrapper: write a contract call, wait for the receipt, and call `onSuccess` once mined. */
export function useTx(onSuccess?: () => void) {
  const write = useWriteContract();
  const receipt = useWaitForTransactionReceipt({ hash: write.data });
  const done = useRef<Hash | undefined>(undefined);

  useEffect(() => {
    if (receipt.isSuccess && write.data && done.current !== write.data) {
      done.current = write.data;
      onSuccess?.();
    }
  }, [receipt.isSuccess, write.data, onSuccess]);

  const pending = write.isPending || (!!write.data && receipt.isLoading);
  const error = write.error ?? receipt.error;
  const reverted = receipt.data?.status === "reverted";

  return {
    writeContract: write.writeContract,
    reset: write.reset,
    hash: write.data,
    pending,
    confirming: !!write.data && receipt.isLoading,
    success: receipt.isSuccess && !reverted,
    reverted,
    errorMessage: error ? humanError(error) : reverted ? "Transaction reverted" : undefined,
  };
}

const KNOWN: Record<string, string> = {
  MarketClosed: "Mint/redeem is closed (US regular hours 09:35–15:45 ET on trading days only).",
  Slippage: "Price moved beyond your slippage tolerance. Try again or raise slippage.",
  Expired: "Transaction deadline passed. Please retry.",
  NotAllowed: "This address is not allowed to use this product (compliance allowlist).",
  CapExceeded: "Product supply cap reached.",
  ZeroAmount: "Amount too small.",
  ProductDead: "Product has no equity; minting is disabled.",
  EnforcedPause: "Product is paused.",
  Locked: "Unstake cooldown has not finished yet.",
};

export function humanError(e: unknown): string {
  if (e instanceof BaseError) {
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName;
      if (name && KNOWN[name]) return KNOWN[name];
      if (name) return `Reverted: ${name}`;
    }
    if (/user rejected|denied/i.test(e.message)) return "Request rejected in wallet.";
    return e.shortMessage || e.message.split("\n")[0];
  }
  if (e instanceof Error) return e.message.split("\n")[0];
  return "Unknown error";
}
