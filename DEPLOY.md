# DEPLOY — Robinhood Chain mainnet runbook

Run everything from `contracts/` unless noted. Never paste a private key into a command, file or chat:
signing happens only through encrypted Foundry keystores (`triplex-deployer`, `triplex-keeper`).

## 0. Prerequisites

- Foundry ≥ 1.8 (`forge --version`), Node 22+ and pnpm 10 (frontend and keeper).
- Deployer wallet funded with **≥ 0.01 ETH on Robinhood Chain**. The dry run estimates ~37.5M gas, about 0.0015 ETH at 0.02 gwei; the extra is headroom.
- Optional env vars for the deploy (each defaults to the deployer address):
  - `GUARDIAN`: can pause products, halt the market clock, manage holidays and the allowlist. Use a multisig.
  - `KEEPER`: gets OPERATOR_ROLE on FeeCollector for fee harvests. Use the `triplex-keeper` address.
  - `PROPOSER`: the only account that can schedule Timelock operations. Use a multisig.
  - `TREASURY`: receives the protocol's fee share. Defaults to the Timelock.

## 1. Import the deployer key (once)

```bash
cast wallet import triplex-deployer --interactive
```

## 2. Dry run (no transactions sent)

```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge script script/Deploy.s.sol:Deploy --rpc-url robinhood --sender $(cast wallet address --account triplex-deployer)
```
It must end with `SIMULATION COMPLETE`. It writes `deployments/4663-dryrun.json`; real deployment files are never overwritten by a dry run.

## 3. Deploy + verify (one command)

```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge script script/Deploy.s.sol:Deploy --rpc-url robinhood --account triplex-deployer --sender $(cast wallet address --account triplex-deployer) --broadcast --slow --verify --verifier sourcify
```

This deploys and wires all contracts and the 20 products, hands every admin role to the 48h Timelock (the deployer keeps nothing), and verifies the source on Sourcify. Blockscout shows Sourcify-verified source. It also writes `deployments/4663.json` and `app/src/config/deployments/4663.json`.

**If verification fails after the broadcast succeeded:** the deployment is fine. Verify without re-sending anything:
```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge script script/Deploy.s.sol:Deploy --rpc-url robinhood --account triplex-deployer --sender $(cast wallet address --account triplex-deployer) --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```
(The Blockscout API sits behind a Cloudflare challenge from some networks, which is why Sourcify is the primary verifier.)

## 4. Post-deploy checklist

1. Commit `contracts/deployments/4663.json` and `app/src/config/deployments/4663.json`.
2. **Venue liquidity.** Triplex creates fresh Morpho Blue markets (LLTV 0.86). Minting needs lenders:
   - USDG supplied to each stock's **long** market (borrowed by the 3L/2L products);
   - the stock token supplied to each stock's **short** market (borrowed by the 1S/2S products).
   Market params are in each adapter (`marketParams()`); Morpho vault curators or the treasury can allocate.
3. Seed each product with a first mint during market hours (09:35–15:45 ET). That opens the position at target leverage.
4. Start the keeper (section 6).

## 5. Wire the $TRPX project token later (Timelock, 48h)

Addresses: `HOOKS` = `projectTokenHooks` and `TL` = `timelock` from `deployments/4663.json`; `TRPX` = the launched token.

Schedule (the `PROPOSER` account):
```bash
cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $(cast calldata "setProjectToken(address)" $TRPX) 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast keccak triplex.setProjectToken) 172800 --account triplex-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```
After 48 hours, execute (anyone may execute):
```bash
cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" $HOOKS 0 $(cast calldata "setProjectToken(address)" $TRPX) 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast keccak triplex.setProjectToken) --account triplex-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```
`setProjectToken` can only ever succeed once. Then set `NEXT_PUBLIC_PROJECT_TOKEN` in the frontend. See `TOKEN_INTEGRATION.md`.

## 6. Keeper

```bash
cast wallet import triplex-keeper --interactive
```
Fund it with a little ETH, then from the repo root:
```bash
pnpm install
CHAIN_ID=4663 KEEPER_ADDRESS=$(cast wallet address --account triplex-keeper) KEEPER_PASSWORD_FILE=$HOME/.triplex-keeper-pw pnpm keeper
```
Set `HARVEST=1` to also harvest and distribute fees daily (needs `KEEPER` = this address at deploy). Set `DRY_RUN=1` to log only. Run it under a process manager (systemd, pm2, Docker) on an always-on host.

## 7. Frontend (Vercel)

Vercel project settings: root directory `app`, install command `pnpm install`, build command `pnpm build`.

Env vars:
- `NEXT_PUBLIC_CHAIN_ID=4663`
- `NEXT_PUBLIC_RPC_URL` (recommended: a dedicated RPC, since the public one rate-limits)
- `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` (optional)
- `NEXT_PUBLIC_PROJECT_TOKEN` (leave empty until $TRPX is wired)
- `NEXT_PUBLIC_GEOBLOCK_COUNTRIES` (optional, e.g. `US,CU,IR,KP,SY`)

## Local fork rehearsal (already passed)

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 31337 --port 18545
```
```bash
cast rpc anvil_setBalance 0x7121A3E5F3f1D1C1c9df2a51a7C5B1c0ffEE0001 0x56BC75E2D63100000 --rpc-url http://127.0.0.1:18545
```
```bash
cast rpc anvil_impersonateAccount 0x7121A3E5F3f1D1C1c9df2a51a7C5B1c0ffEE0001 --rpc-url http://127.0.0.1:18545
```
```bash
forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:18545 --unlocked --sender 0x7121A3E5F3f1D1C1c9df2a51a7C5B1c0ffEE0001 --broadcast --slow
```
On Windows, don't pass `--auto-impersonate` to anvil (it crashes); impersonate via RPC as above. Point the app at the fork with `NEXT_PUBLIC_CHAIN_ID=31337 NEXT_PUBLIC_RPC_URL=http://127.0.0.1:18545 pnpm app:dev`.
