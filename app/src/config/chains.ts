import { defineChain } from "viem";
import { ENV } from "./env";
import { MULTICALL3, ROBINHOOD_CHAIN } from "./constants";

export const robinhoodChain = defineChain({
  id: ROBINHOOD_CHAIN.id,
  name: ROBINHOOD_CHAIN.name,
  nativeCurrency: ROBINHOOD_CHAIN.nativeCurrency,
  rpcUrls: { default: { http: [ENV.rpcUrl || ROBINHOOD_CHAIN.defaultRpc] } },
  blockExplorers: { default: ROBINHOOD_CHAIN.blockExplorer },
  contracts: { multicall3: { address: MULTICALL3 } },
});

/** Local anvil fork of Robinhood Chain (same contracts, chain id 31337). */
export const localFork = defineChain({
  id: 31337,
  name: "Triplex Local Fork",
  nativeCurrency: ROBINHOOD_CHAIN.nativeCurrency,
  rpcUrls: { default: { http: [ENV.rpcUrl || "http://127.0.0.1:8545"] } },
  // Explorer links on the fork point at the mainnet explorer (useful for forked state only).
  blockExplorers: { default: ROBINHOOD_CHAIN.blockExplorer },
  contracts: { multicall3: { address: MULTICALL3 } },
  testnet: true,
});

export const activeChain = ENV.chainId === 31337 ? localFork : robinhoodChain;

export function explorerTx(hash: string) {
  return `${activeChain.blockExplorers.default.url}/tx/${hash}`;
}
export function explorerAddress(addr: string) {
  return `${activeChain.blockExplorers.default.url}/address/${addr}`;
}
