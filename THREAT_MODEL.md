# THREAT MODEL

Status: **unaudited**. This document lists what the code defends against, how, and what remains as residual risk.

## Assets and trust

| Actor | Trust | Powers |
|---|---|---|
| Holders | untrusted | mint / redeem during US regular hours |
| Keepers | untrusted | `Rebalancer.rebalance(product)`: size, direction and slippage are computed on-chain; keepers choose nothing |
| Guardian | semi-trusted (multisig) | pause products/rebalancer/staking, halt the MarketClock, set holidays, manage the allowlist. **Cannot unpause, move funds or change parameters.** |
| Timelock (48h, floor enforced) | governance | every admin setter; swapping oracle, swap adapter, rebalancer or clock; fees (hard-capped); leverage bands (validated against LLTV) |
| External | trusted dependencies | Morpho Blue, Chainlink feeds, Uniswap v3, USDG and the stock token contracts |

## Top risks

### 1. Rebalance front-running / sandwiching
Rebalances are predictable (the band is public, the daily window is public).
- **TWAP chunks:** each call trades at most `maxChunk` (default $10k of exposure). Calls are `minInterval` apart (default 120s), so a large rebalance spreads over many blocks.
- **Oracle-bounded execution:** every swap has `minOut` / `maxIn` derived from the Chainlink price ± `maxSwapSlippageBps` (150 bps). A sandwich can extract at most that bound per chunk.
- **Fixed routes:** the pool fee tier per pair is set by governance; keepers cannot pass a route.
- **Sequencer ordering:** Robinhood Chain is an Arbitrum Orbit chain with a first-come-first-served sequencer and no public mempool auction, which limits classic sandwiching.
- The daily window (15:45–17:00 ET) does not overlap mint/redeem, so rebalance trades and NAV-sensitive flows are not interleaved.

### 2. Overnight / weekend gaps wiping out 3x products
A 3x long at target loses all equity on a −33.3% move; 2x on −50%. Morpho liquidates earlier, at LTV 0.86: a 3x long starting at LTV 0.667 is liquidatable after roughly −22%.
- **Emergency rebalance 24/5:** whenever leverage leaves the band (3x: 2.5–3.6x) and the oracle is live (Chainlink stock feeds run 24/5), anyone can deleverage. This covers extended and overnight sessions. Once triggered, it continues to target, not just to the band edge.
- **Urgent mode:** beyond `max + (max − target)` (4.2x for 3L) the TWAP interval is skipped.
- **Band design:** the factory rejects any band whose worst-case LTV is within 5 points of LLTV (`validateBand`).
- **NAV never negative:** equity is floored at 0 and debt is never socialised to other products, since each product has its own Morpho position.
- **Residual:** weekend and holiday gaps can't be hedged on-chain because feeds go stale. A gap larger than about 22% on a 3L product can trigger Morpho liquidation (~5% penalty); a gap of 33% or more wipes it out. This is disclosed on `/risk`. The invariant suite shows equity stays positive for shocks up to ±12% per step with keepers acting.

### 3. Venue (Morpho) liquidation
- Positions are isolated per product adapter; liquidation of one product affects only its holders.
- Bands are validated against LLTV with a 5% buffer. Every rebalance increase is **flash-funded** (collateral posted before debt), so the position never transiently exceeds its final LTV. The invariant tests found the borrow-first bug this prevents.
- Interest accrual raises leverage and is handled like any drift (tested with a 50% APR stress).
- **Residual:** market liquidity. If lenders withdraw, mints can fail (borrow liquidity) and the IRM spikes rates. Redeems and deleveraging still work, since they repay debt.

### 4. NAV manipulation
- **Mint/redeem are proportional in token terms:** the minter adds the same fraction *k* of collateral **and** debt and receives *k*·supply shares; redeem removes the same fraction. Share issuance is therefore **independent of the oracle price**. A stale or manipulated oracle cannot mint cheap shares or redeem expensive ones, and the minter/redeemer pays their own execution cost. Fuzz-tested over 2,048 runs per property with ±10% price moves, ±1% oracle/market offsets and venue slippage: per-share collateral never falls and the debt/collateral ratio never worsens, beyond 2 wei of Morpho share rounding.
- **Donations:** idle token balances held by an adapter are excluded from NAV, so donating tokens can't move it.
- **First-depositor inflation:** 1e12 dead shares are locked on the first mint.
- **Oracle checks:** staleness (26h max age against the 24h heartbeat), non-positive answers, incomplete rounds and future timestamps are all rejected. A deviation check against a Uniswap v3 TWAP is configured (5%, lenient when the pool has no history). An optional sequencer-uptime feed is supported; Chainlink doesn't publish one for this chain yet.
- **Management fee** accrues as dilutive shares at a rate hard-capped at 3%/yr in code (`MAX_MGMT_FEE_BPS`). Mint/redeem fees are capped at 1%.

### 5. Other
- **Reentrancy:** `nonReentrant` on every state-changing entry point. The flash-loan callback only accepts Morpho while an operation is active. Checks-effects-interactions is followed, e.g. shares are burned before the unwind.
- **Tokens:** SafeERC20 everywhere. Approvals to the swap adapter are exact and reset to 0. The stake token uses fee-on-transfer-safe accounting.
- **Governance compromise:** a malicious Timelock proposal (e.g. a hostile swap adapter) is visible for 48h. The guardian can pause in the meantime; holders can't redeem while paused, which is a deliberate trade-off.
- **Market hours:** mint/redeem only between 09:35 and 15:45 ET on NYSE trading days. DST is computed on-chain; holidays and early closes for 2026–2028 are preloaded and the operator can add more.
- **Compliance:** optional allowlist (`ComplianceRegistry`), off by default; redeem gating can be enabled separately.
- **No unbounded loops** in state-changing paths. Lists are iterated only in views.

## Static analysis

`slither .` (config `contracts/slither.config.json`) reports **0 high/medium findings**. Triage:
- `weak-prng`, `divide-before-multiply` (MarketClock): `%` and floor division are calendar arithmetic, not randomness or precision loss. Suppressed inline; the day↔date round trip is fuzz-tested.
- `reentrancy-balance` (`mintProportional`) and `reentrancy-no-eth` (`rebalance`): balance deltas and state writes inside `nonReentrant` functions that only call trusted venues. Suppressed inline with justification.
- `incorrect-equality` (18): all `== 0` guards on computed values. `unused-return` (28): intentionally ignored view-tuple members and Morpho `borrow`/`repay` returns (exact amounts are passed). Excluded in config with this rationale.
- `uninitialized-local` (2): fixed.

## Tests

- Unit tests across all contracts.
- Fuzz tests (fairness, round trips, NAV stability).
- Stateful invariants (equity never negative, leverage back in band after every rebalance, mint/redeem fair, shares backed) over 64 × 64 random action sequences.
- Fork tests on Robinhood Chain mainnet state (real USDG, stock tokens, Chainlink, Morpho, Uniswap).
- Line coverage ≥ 97% on every core contract.
