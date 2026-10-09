"use client";

import { useReadContracts } from "wagmi";
import { marketClockAbi } from "@/abi";
import { deployment } from "@/config";
import { isSet } from "@/config/deployments";

export interface MarketStatus {
  loading: boolean;
  known: boolean;
  marketOpen: boolean;
  mintRedeemOpen: boolean;
}

export function useMarketStatus(): MarketStatus {
  const enabled = isSet(deployment.marketClock);
  const { data, isLoading } = useReadContracts({
    contracts: [
      { address: deployment.marketClock, abi: marketClockAbi, functionName: "isMarketOpen" },
      { address: deployment.marketClock, abi: marketClockAbi, functionName: "isMintRedeemOpen" },
    ],
    query: { enabled, refetchInterval: 30_000 },
  });
  const m = data?.[0];
  const r = data?.[1];
  const known = m?.status === "success" && r?.status === "success";
  return {
    loading: enabled && isLoading,
    known,
    marketOpen: m?.status === "success" ? (m.result as boolean) : false,
    mintRedeemOpen: r?.status === "success" ? (r.result as boolean) : false,
  };
}
