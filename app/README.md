# Triplex app (`@triplex/app`)

Next.js 15 (App Router) frontend for Triplex: auto-rebalancing leveraged tokens (3x/2x long, 1x/2x short) on
tokenized stocks, deployed on Robinhood Chain (chain id 4663).

Stack: Next.js 15, TypeScript (strict), wagmi v2, viem v2, RainbowKit v2, TanStack Query, Tailwind CSS v4.
All chain data is fetched client-side, so `next build` never needs network access.

## Pages

| Route | What it does |
| --- | --- |
| `/` | Product list from `NAVCalculator.getAllProducts()` (refreshed every 15s): NAV, real vs target leverage (amber when >10% off target, red outside the band), today's product vs underlying return since the last close snapshot, TVL, market status. |
| `/product/[address]` | Stats, leverage band, collateral/debt/LTV, mint and redeem (approve → mint, slippage setting with 1% default, 10-minute deadline), balances, fees (with staker discount when token features are active), rebalance history from `Rebalanced` + `DailySnapshot` logs. |
| `/learn` | Volatility-decay explainer, worked example and a client-side simulator (SVG chart). |
| `/risk` | Risk disclosure plus the one-time "I understand the risks" acknowledgement (localStorage) required before minting. |
| `/stake` | $TRPX staking (stake, 7-day cooldown unstake, withdraw, claim, fee discount tiers). Only linked/rendered when token features are active. |
| `/blocked` | Shown to geoblocked visitors (see `src/middleware.ts`). |

## Environment variables

Copy `.env.example` to `.env.local`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NEXT_PUBLIC_CHAIN_ID` | `4663` | `4663` = Robinhood Chain mainnet, `31337` = local anvil fork ("Triplex Local Fork", `http://127.0.0.1:8545`). |
| `NEXT_PUBLIC_RPC_URL` | `https://rpc.mainnet.chain.robinhood.com` | RPC for chain 4663. The public endpoint is rate limited; use a private one in production. |
| `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` | empty | WalletConnect Cloud project id. Empty = injected browser wallets only. |
| `NEXT_PUBLIC_PROJECT_TOKEN` | empty | $TRPX token address. Empty = all token features hidden. When set, features also require `ProjectTokenHooks.isActive()`. |
| `NEXT_PUBLIC_GEOBLOCK_COUNTRIES` | empty | Comma-separated ISO country codes (e.g. `US,CU,IR,KP,SY`). Uses Vercel's `x-vercel-ip-country` header. Empty = off. |

All variables are `NEXT_PUBLIC_*` and inlined at build time, so redeploy after changing them.

## Contract addresses and ABIs

- Addresses come only from `src/config/deployments/<chainId>.json`, written by the deploy script
  (schema: `src/config/deployments/README.md`). The committed `4663.json` / `31337.json` are placeholders with zero
  addresses; the UI shows a "not deployed yet" notice until they are overwritten. To support another chain, add its
  JSON and one line in `src/config/deployments/index.ts`.
- Chain/token constants (USDG, multicall, RPC, explorer) are copied with their source links from `../config/chains.ts`
  into `src/config/constants.ts`.
- ABIs in `src/abi/*.ts` are generated from the Foundry output and committed so the app builds standalone:

```bash
cd ../contracts && forge build   # ~1 min
cd ../app && pnpm sync-abis
```

## Run locally

```bash
# from the repo root
pnpm install

# against mainnet (read-only until you connect a wallet)
pnpm --filter @triplex/app dev

# against a local anvil fork of Robinhood Chain
anvil --fork-url https://rpc.mainnet.chain.robinhood.com          # terminal 1
# deploy the contracts to the fork (writes app/src/config/deployments/31337.json)
cd app && NEXT_PUBLIC_CHAIN_ID=31337 pnpm dev                       # terminal 2
```

Then add the "Triplex Local Fork" network (chain id 31337, RPC `http://127.0.0.1:8545`) in your wallet; RainbowKit
will prompt to switch. Use one of anvil's own test accounts imported into your wallet; this app never handles keys.

Build: `pnpm --filter @triplex/app build`. Typecheck only: `pnpm --filter @triplex/app typecheck`.

## Deploy to Vercel

1. Import the repository in Vercel.
2. **Root Directory**: `app`. Framework preset: Next.js.
3. **Install Command**: `pnpm install`. **Build Command**: `pnpm build`. Output: default (`.next`).
4. Set the environment variables above (at least `NEXT_PUBLIC_RPC_URL` with a private RPC, and
   `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` for mobile wallets).
5. Deploy. The geoblock middleware runs on Vercel's edge and reads `x-vercel-ip-country`.

## Frontend decisions

- **Constants copied, not imported.** `../config/chains.ts` values used by the app (chain, USDG, multicall) are copied
  with their source comments into `src/config/constants.ts`, so a Vercel build with root directory `app` does not
  depend on files outside it. No `transpilePackages` needed. Keep them in sync if `config/chains.ts` changes.
- **USDG address** is taken from the deployment JSON `quoteToken`, falling back to the canonical mainnet USDG.
- **Only the active chain** is registered with wagmi, so wallets are asked to switch to it.
- **No WalletConnect id → injected wallets only** (`injectedWallet`), so build/run works without any third-party
  credentials. With an id, MetaMask/Rabby/Rainbow/Coinbase/WalletConnect are offered.
- **Mint estimate** mirrors the contract: fee = ceil(quoteIn × feeBps × (1 − discount)), then
  shares = net × (1 − mintBuffer) / navPerShare. `minSharesOut` = estimate × (1 − slippage). The unused buffer is shown
  as an approximate refund. For a product's very first mint (supply 0) shares ≈ net (NAV starts at 1.0).
- **Redeem estimate** = shares × NAV − redeem fee; `minQuoteOut` = estimate × (1 − slippage). The UI warns that the
  unwind swap can cost more than NAV.
- **Approve exact amount** (not unlimited) before minting/staking.
- **Risk acknowledgement** gates the mint button only (redeem is always possible so users can exit). Stored under
  localStorage key `triplex.riskAck.v1`; it can also be given on `/risk`.
- **Compliance**: if a ComplianceRegistry is deployed, the panel checks `isAllowed(user, keccak256("MINT"/"REDEEM"))`
  and explains a block instead of letting the transaction revert.
- **Rebalance history** scans backwards from the chain tip in 50,000-block `eth_getLogs` chunks, starting no earlier
  than `deployBlock`, stops after 50 events and never looks back more than 1,000,000 blocks. Block timestamps for
  `Rebalanced` rows are fetched with JSON-RPC batching.
- **Leverage colours**: red when outside [min, max] or no equity (`type(uint256).max`), amber when more than 10%
  away from target, neutral otherwise.
- **Market status** comes from `MarketClock.isMarketOpen()` / `isMintRedeemOpen()` on-chain (not from the browser
  clock), so holidays, early closes and guardian halts are respected.
- **Geoblock** leaves `/risk` and `/blocked` reachable for blocked visitors; when the Vercel header is absent (local
  dev, other hosts) requests pass through.
- **Staking rewards** token decimals/symbol are read from `ProjectTokenHooks.rewardToken()`; a mismatch between
  `NEXT_PUBLIC_PROJECT_TOKEN` and the contract's `projectToken()` is flagged on the page.
- **Webpack aliases**: `@x402/*` (optional deps of `@coinbase/cdp-sdk`, pulled in transitively by wagmi's Base Account
  connector) are aliased to empty modules in `next.config.mjs`; they are never used and otherwise break `next build`.
- **No lint script** is configured; `next build` still type-checks (`eslint.ignoreDuringBuilds` is set because no
  ESLint config is present).
- **Generated ABIs** are kept in the repo (not git-ignored) but this task did not create a git commit, because other
  work in the repository is uncommitted.
