# DECISIONS

- Venue: **Morpho Blue** (borrow-and-swap) behind `IPositionAdapter`; no composable perps venue exists on Robinhood Chain (Lighter is off-chain to L2 contracts).
- Dedicated Morpho markets per stock (long: USDG loan / stock collateral; short: stock loan / USDG collateral), LLTV 0.86, AdaptiveCurveIRM, Morpho's own ChainlinkOracleV2 — existing stock markets top out at 0.625/0.77 LLTV, too low for 3x long / 2x short.
- Underlyings: CRCL, NVDA, SPCX, MU, QQQ = top-5 Chainlink-fed equity tokens by Uniswap v3 USDG-pool TVL (2026-10-08); excluded GLD/USO/SGOV (commodity/T-bill ETFs).
- Swaps: Uniswap v3 SwapRouter02 behind `ISwapAdapter`, fee tier fixed per pair by governance (keepers cannot choose routes).
- Mint/redeem scale collateral and debt by the same fraction → share pricing is oracle-independent; minter/redeemer pays own slippage. Mint fee is charged on quote actually used; unused buffer (~1%/leverage turn) refunded.
- Rebalance increases/decreases are flash-loan funded (Morpho free flash loans) so the position never transiently exceeds final LTV (found by invariant test).
- Emergency rebalances continue to target (not just the band edge); dust products (<$1 equity) are not rebalanced.
- Unit of account: USDG (6 dec); NAV uses Chainlink stock/USD ÷ USDG/USD.
- Feed max age 26h (24h heartbeat). No sequencer-uptime feed exists for Robinhood Chain (gap; supported, unset).
- Guardian pauses; only the 48h Timelock unpauses. Timelock delay floor enforced via `getMinDelay()` override.
- Treasury defaults to the Timelock. Staker fee share default 50%; discount tiers 25%/50% at 10k/100k $TRPX, 7-day unstake cooldown.
- No keeper bounty on-chain (avoids value leakage); protocol runs its own keeper; rebalance is permissionless.
- Local anvil fork runs on port 18545 (8545/8546 were occupied on this machine); `--auto-impersonate` crashes anvil on Windows, so `anvil_impersonateAccount` is used.
- `block.number` is L1-style on Arbitrum chains; deploy script records L2 block via `eth_blockNumber`.
