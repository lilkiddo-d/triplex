import type { Address } from "viem";
import { isAddress } from "viem";

// NEXT_PUBLIC_* values are inlined at build time; they must be referenced literally.
const rawChainId = process.env.NEXT_PUBLIC_CHAIN_ID;
const rawToken = (process.env.NEXT_PUBLIC_PROJECT_TOKEN ?? "").trim();

export const ENV = {
  chainId: rawChainId && /^\d+$/.test(rawChainId.trim()) ? Number(rawChainId.trim()) : 4663,
  rpcUrl: (process.env.NEXT_PUBLIC_RPC_URL ?? "").trim(),
  walletConnectProjectId: (process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "").trim(),
  projectToken: (isAddress(rawToken) ? rawToken : undefined) as Address | undefined,
  geoblockCountries: (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES ?? "")
    .split(",")
    .map((c) => c.trim().toUpperCase())
    .filter(Boolean),
} as const;
