"use client";

import type { Address, ContractFunctionReturnType } from "viem";
import { useReadContract } from "wagmi";
import { navCalculatorAbi } from "@/abi";
import { deployed, deployment } from "@/config";

export type ProductView = ContractFunctionReturnType<typeof navCalculatorAbi, "view", "getAllProducts">[number];

export const REFRESH_MS = 15_000;

export function useProducts() {
  return useReadContract({
    address: deployment.navCalculator,
    abi: navCalculatorAbi,
    functionName: "getAllProducts",
    query: { enabled: deployed, refetchInterval: REFRESH_MS },
  });
}

export function useProduct(product: Address | undefined) {
  return useReadContract({
    address: deployment.navCalculator,
    abi: navCalculatorAbi,
    functionName: "getProduct",
    args: product ? [product] : undefined,
    query: { enabled: deployed && !!product, refetchInterval: REFRESH_MS },
  });
}
