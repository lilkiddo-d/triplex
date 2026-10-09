# DEPLOY

All commands from `contracts/`. Never paste a private key anywhere; signing is via Foundry keystores only.

1. Import the deployer key into an encrypted keystore (prompts for key + password):
```bash
cast wallet import triplex-deployer --interactive
```
2. Deploy + verify (Blockscout) in one command:
```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge script script/Deploy.s.sol:Deploy --rpc-url robinhood --account triplex-deployer --sender $(cast wallet address --account triplex-deployer) --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --slow
```
Optional env: `GUARDIAN`, `KEEPER`, `PROPOSER`, `TREASURY` (defaults: deployer; treasury = Timelock). Writes `deployments/4663.json` and `app/src/config/deployments/4663.json`.

3. Later, wire $TRPX (Timelock, 48h). Schedule, wait 48h, execute:
```bash
cast send <TIMELOCK> "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" <PROJECT_TOKEN_HOOKS> 0 $(cast calldata "setProjectToken(address)" <TRPX>) 0x0000000000000000000000000000000000000000000000000000000000000000 0x$(printf trpx | xxd -p | head -c 64 | sed -e :a -e 's/^.\{1,63\}$/&0/;ta') 172800 --account triplex-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```
then after 48h the same args to `execute(address,uint256,bytes,bytes32,bytes32)` (without the delay).

Keeper: `cast wallet import triplex-keeper --interactive`, then from repo root `pnpm install && CHAIN_ID=4663 KEEPER_PASSWORD_FILE=~/.triplex-keeper-pw pnpm keeper`.

Frontend (Vercel): root directory `app`, install `pnpm install`, build `pnpm build`; env `NEXT_PUBLIC_CHAIN_ID=4663`, optional `NEXT_PUBLIC_RPC_URL`, `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`, `NEXT_PUBLIC_PROJECT_TOKEN`, `NEXT_PUBLIC_GEOBLOCK_COUNTRIES`.

Local fork rehearsal (done, succeeded): `anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 31337 --port 18545`, `cast rpc anvil_impersonateAccount <ADDR>`, then the deploy command with `--rpc-url http://127.0.0.1:18545 --unlocked --sender <ADDR> --broadcast`.

Note: venue liquidity (USDG lenders in the long markets, stock lenders in the short markets) must be supplied to the new Morpho markets before minting is possible.
