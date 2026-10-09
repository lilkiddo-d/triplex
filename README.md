# Triplex

Auto-rebalancing leveraged tokens for tokenized stocks on **Robinhood Chain**: 3x and 2x long, 1x and 2x short, like leveraged ETFs but on-chain.

Twenty products at launch: `3L-`, `2L-`, `1S-` and `2S-` on **CRCL, NVDA, SPCX, MU, QQQ**. These are the five most liquid equity tokens with Chainlink feeds. Each product is its own ERC-20 share token, not a project token.

> Unaudited software. Leveraged and inverse products can lose most or all of their value quickly. See the app's `/risk` page and `THREAT_MODEL.md`.

## How it works

```
user ──mint/redeem (USDG, US market hours)──▶ LeveragedToken (one per product, EIP-1167 clone)
                                                   │ proportional add/remove of collateral AND debt
                                                   ▼
                                         MorphoPositionAdapter ──flash loans / borrow / repay──▶ Morpho Blue (LLTV 0.86)
                                                   │ swaps (oracle-bounded slippage)
                                                   ▼
                                          UniswapV3SwapAdapter ──▶ Uniswap v3 stock/USDG pools
keepers ──rebalance(product)──▶ Rebalancer (daily at the close + emergency outside the band, TWAP chunks)
```

- **Position:**
  - Long: the stock is collateral and USDG is debt (borrow USDG, buy stock).
  - Short: USDG is collateral and the stock is debt (borrow stock, sell it).
- **Mint/redeem at NAV:** collateral and debt scale by the same fraction, so share pricing is oracle-independent and the minter/redeemer pays their own slippage. Mint/redeem runs 09:35–15:45 ET on NYSE trading days (`MarketClock`, DST-aware, holidays preloaded).
- **Rebalancing:**
  - Daily, in the close window (15:45–17:00 ET), back to target leverage, with a NAV snapshot used for "daily performance".
  - Emergency, 24/5, whenever leverage leaves the band (e.g. 3x: 2.5–3.6x).
  - Chunked (max $10k exposure per call, 120s apart), with slippage bounded against Chainlink.
- **Fees:**
  - Mint and redeem: 10 bps each, hard cap 1%.
  - Streaming management fee: 0.95%/yr, **hard-capped at 3%/yr in code**.
  - Fees accrue to the `FeeCollector`, which pays $TRPX stakers once the token is wired (see `TOKEN_INTEGRATION.md`).
- **Governance:**
  - Every admin role is held by a 48h `Timelock`, whose delay can't go below the floor.
  - A guardian can pause but not unpause.
  - The optional `ComplianceRegistry` allowlist is off by default.

## Repo layout

| Path | What |
|---|---|
| `contracts/` | Foundry project: `src/` (protocol), `test/` (unit, fuzz, invariant, fork), `script/Deploy.s.sol` |
| `app/` | Next.js + wagmi/viem + RainbowKit frontend |
| `scripts/` | rebalance keeper (`keeper.ts`, signs via the Foundry keystore) |
| `config/chains.ts` | every chain/token/oracle/venue address with its source link |
| `docs` | `DEPLOY.md`, `DECISIONS.md`, `THREAT_MODEL.md`, `TOKEN_INTEGRATION.md` (repo root) |

Contracts: `LeveragedTokenFactory` (also the module registry), `LeveragedToken`, `IPositionAdapter` + `MorphoPositionAdapter`, `Rebalancer`, `NAVCalculator`, `MarketClock`, `OracleAdapter` (+ `UniswapV3TwapPriceSource`), `UniswapV3SwapAdapter`, `FeeCollector`, `ProjectTokenHooks`, `ComplianceRegistry`, `Timelock`.

## Develop

```bash
cd contracts && forge build
```
```bash
cd contracts && forge test --no-match-path "test/{invariant,fork}/*"
```
```bash
cd contracts && forge test --match-path "test/fork/*"
```
```bash
cd contracts && forge test --match-path "test/invariant/*"
```
```bash
cd contracts && python -m slither .
```
```bash
pnpm install && pnpm app:dev
```

The fork tests use `ROBINHOOD_RPC_URL`, defaulting to the public RPC. The invariant suite takes about 10 minutes.

## Status

- **Tests pass:** unit, fuzz (2,048 runs per property), invariants, and fork tests against Robinhood Chain mainnet state.
- **Slither:** 0 high/medium findings (triage in `THREAT_MODEL.md`).
- **Coverage:** ≥ 97% lines on every core contract.
- **Deployment rehearsed:** a full deploy succeeded on a local anvil fork, and the mainnet dry run simulates cleanly.

Deploy instructions are in **[DEPLOY.md](DEPLOY.md)**.
