# $TRPX token integration

**Triplex does not create or deploy any project token.** $TRPX is launched separately on a launchpad. This repo only
*accepts* its address later, and the protocol works fully without it. The only ERC-20 named TRPX in this repo is a
test mock (`contracts/test/mocks/Mocks.sol`), which is never deployed.

## Where the token plugs in

All token logic lives in `contracts/src/ProjectTokenHooks.sol`:

| Feature | Behaviour before the token is set | After `setProjectToken` |
|---|---|---|
| Staking (`stake`, `requestUnstake`, `withdraw`) | reverts `NotActive` | enabled; unstaking has a 7-day cooldown (max 30 days, Timelock-settable) |
| Fee share for stakers | `FeeCollector.distribute()` sends 100% to the treasury | `stakerShareBps` (default 50%) of fees goes to stakers pro rata, paid in USDG and claimable via `claim()` |
| Mint/redeem fee discount | `feeDiscountBps()` returns 0 | tier 1: ≥10,000 staked → 25% off; tier 2: ≥100,000 staked → 50% off (max 75%, Timelock-settable) |

The discount and fee share apply only to *currently staked* balances. Requesting an unstake removes them immediately, so flash-staking for a discount means locking capital for the full cooldown.

## `setProjectToken(address)`

- Callable **only by `DEFAULT_ADMIN_ROLE`, which is held only by the 48h Timelock** after deployment.
- Callable **once**: a second call reverts `AlreadySet`.
- Rejects the zero address, EOAs and contracts without `totalSupply()`.
- Staking measures received balances, so fee-on-transfer launchpad tokens are handled.

Exact commands (schedule, wait 48h, execute) are in `DEPLOY.md` §5. A test covers the full flow through a real Timelock (`test_setProjectToken_viaTimelock_48h`).

## Frontend

`NEXT_PUBLIC_PROJECT_TOKEN`:
- **empty** (default): every token feature is hidden (no Stake page, no discount display).
- **set to the token address:** the Stake page and the discount UI appear, but only once `ProjectTokenHooks.isActive()` is true on-chain. Setting the env var early is harmless.

## Checklist when $TRPX launches

1. Verify the launched token address on the explorer.
2. Schedule `setProjectToken` through the Timelock, then execute after 48h.
3. Optionally adjust tiers (`setTiers`) or the staker share (`FeeCollector.setStakerShareBps`), also through the Timelock.
4. Set `NEXT_PUBLIC_PROJECT_TOKEN` on Vercel and redeploy the frontend.
