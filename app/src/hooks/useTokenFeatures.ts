"use client";

import { useReadContract } from "wagmi";
import { projectTokenHooksAbi } from "@/abi";
import { deployment, tokenFeaturesConfigured } from "@/config";

/** $TRPX features are shown only when NEXT_PUBLIC_PROJECT_TOKEN is set AND ProjectTokenHooks.isActive(). */
export function useTokenFeatures() {
  const { data, isLoading } = useReadContract({
    address: deployment.projectTokenHooks,
    abi: projectTokenHooksAbi,
    functionName: "isActive",
    query: { enabled: tokenFeaturesConfigured, staleTime: 60_000 },
  });
  return { active: tokenFeaturesConfigured && data === true, loading: tokenFeaturesConfigured && isLoading };
}
