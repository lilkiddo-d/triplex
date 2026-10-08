/**
 * Triplex chain configuration — Robinhood Chain mainnet.
 *
 * Every address below was taken from an official source (linked inline) and
 * cross-checked on-chain against https://rpc.mainnet.chain.robinhood.com on
 * 2026-10-08 (eth_chainId = 4663, code present at each address).
 *
 * Do NOT add an address here without a source link.
 */

export const ROBINHOOD_CHAIN = {
  id: 4663,
  name: "Robinhood Chain",
  // Gas token: ETH (Arbitrum Orbit L2). Source: https://docs.robinhood.com/chain
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    // Public endpoint, rate limited (HTTP 429 under load). Source: https://docs.robinhood.com/chain/contracts
    default: "https://rpc.mainnet.chain.robinhood.com",
  },
  blockExplorer: {
    name: "Blockscout",
    url: "https://robinhoodchain.blockscout.com",
    // Contract verification: Blockscout verifier (forge --verifier blockscout).
    // Source: explorer links on https://docs.robinhood.com/chain/contracts
    verifierUrl: "https://robinhoodchain.blockscout.com/api/",
  },
  // ArbOS reported by ArbSys(0x64).arbOSVersion() = 116 (=55+61) -> ArbOS 61, Cancun opcodes available.
  evmVersion: "cancun",
} as const;

/**
 * Core tokens. Source: https://docs.robinhood.com/chain/contracts ("Core Tokens" table)
 */
export const CORE_TOKENS = {
  WETH: { address: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", decimals: 18 },
  // Global Dollar (Paxos). decimals() == 6 verified on-chain.
  USDG: { address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", decimals: 6 },
} as const;

/**
 * Stock tokens selected for Triplex products (the 5 most liquid equity tokens).
 * Token addresses: official asset registry https://api.robinhood.com/rhj/assets
 *   (the registry that renders the table on https://docs.robinhood.com/chain/contracts).
 * Chainlink feeds: https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *   (machine-readable: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json)
 *   All stock feeds: 8 decimals, 86400s heartbeat, 0.5% deviation, "us_equities_24/5" market hours.
 * Uniswap v3 pool fee = deepest USDG pool measured on 2026-10-08 (see DECISIONS.md).
 * All stock tokens are 18-decimal ERC-20s (ERC-8056 scaled-UI multiplier; Chainlink price already
 * reflects the multiplier, i.e. it is the price of one raw token).
 */
export const STOCK_TOKENS = {
  CRCL: {
    name: "Circle Internet Group",
    address: "0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5",
    chainlinkFeed: "0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a",
    uniV3Fee: 3000,
  },
  NVDA: {
    name: "NVIDIA",
    address: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC",
    chainlinkFeed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15",
    uniV3Fee: 500,
  },
  SPCX: {
    name: "Space Exploration Technologies",
    address: "0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa",
    chainlinkFeed: "0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb",
    uniV3Fee: 500,
  },
  MU: {
    name: "Micron Technology",
    address: "0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD",
    chainlinkFeed: "0x425EEFdCf05ed6526C3cE61Af99429A228a6d596",
    uniV3Fee: 3000,
  },
  QQQ: {
    name: "Invesco QQQ",
    address: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68",
    chainlinkFeed: "0x80901d846d5D7B030F26B480776EE3b29374C2ae",
    uniV3Fee: 500,
  },
} as const;

/**
 * Chainlink feeds for the quote asset.
 * Source: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json
 */
export const CHAINLINK = {
  USDG_USD: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2",
  // GAP: Chainlink publishes no L2 Sequencer Uptime Feed for Robinhood Chain (not in the
  // official feed list as of 2026-10-08). OracleAdapter supports one; it stays unset (0x0).
  SEQUENCER_UPTIME: "0x0000000000000000000000000000000000000000",
} as const;

/**
 * Morpho Blue (lending venue used by MorphoPositionAdapter).
 * Source: https://docs.morpho.org/get-started/resources/addresses/ ("Robinhood Chain" tab)
 */
export const MORPHO = {
  morphoBlue: "0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010",
  adaptiveCurveIrm: "0x2BD3d5965B26B51814AC95127b2b80dD6CcC0fa1",
  chainlinkOracleV2Factory: "0xB7c16F6F8cF531447Bf27Ca7220f981E79C9cdF2",
  // LLTV used for Triplex markets. 0.86 is enabled on this deployment (existing markets use it).
  lltv: "860000000000000000",
} as const;

/**
 * Uniswap (swap venue used by UniswapV3SwapAdapter).
 * Source: https://github.com/Uniswap/sdks/blob/main/sdks/sdk-core/src/addresses.ts (ROBINHOOD_ADDRESSES)
 *     and https://developers.uniswap.org/docs/protocols/v4/deployments ("Robinhood Chain: 4663")
 */
export const UNISWAP = {
  v3Factory: "0x1f7d7550b1b028f7571e69a784071f0205fd2efa",
  swapRouter02: "0xcaf681a66d020601342297493863e78c959e5cb2",
  quoterV2: "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7",
  v4PoolManager: "0x8366a39cc670b4001a1121b8f6a443a643e40951",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
} as const;

/**
 * Other official L2 infrastructure.
 * Source: https://docs.robinhood.com/chain/contracts ("Core contracts (L2)")
 */
export const INFRA = {
  multicall: "0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1",
  arbSys: "0x0000000000000000000000000000000000000064",
} as const;
