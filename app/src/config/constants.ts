/**
 * Chain / token constants copied from ../../../config/chains.ts (the single source of truth for the
 * protocol). They are copied (with their source links) rather than imported so the app builds standalone
 * on Vercel with root directory `app`. Keep in sync with config/chains.ts.
 */

export const ROBINHOOD_CHAIN = {
  id: 4663,
  name: "Robinhood Chain",
  // Gas token: ETH (Arbitrum Orbit L2). Source: https://docs.robinhood.com/chain
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  // Public endpoint, rate limited (HTTP 429 under load). Source: https://docs.robinhood.com/chain/contracts
  defaultRpc: "https://rpc.mainnet.chain.robinhood.com",
  blockExplorer: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" },
} as const;

/** Core tokens. Source: https://docs.robinhood.com/chain/contracts ("Core Tokens" table) */
export const CORE_TOKENS = {
  // Global Dollar (Paxos). decimals() == 6 verified on-chain.
  USDG: { address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", decimals: 6 },
} as const;

/**
 * Official L2 multicall. Source: https://docs.robinhood.com/chain/contracts ("Core contracts (L2)")
 */
export const MULTICALL3 = "0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1" as const;

/** Quote token (USDG) decimals; shares are 18 decimals. */
export const QUOTE_DECIMALS = 6;
export const QUOTE_SYMBOL = "USDG";
export const SHARE_DECIMALS = 18;
