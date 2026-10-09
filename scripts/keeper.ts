/**
 * Triplex rebalance keeper.
 *
 * Reads Rebalancer.check(product) for every product and, when a step is due, sends
 * Rebalancer.rebalance(product). Rebalancing is permissionless and fully determined on-chain (direction, size,
 * slippage bound), so the keeper holds no discretion and no funds beyond gas.
 *
 * Signing: transactions are sent with `cast send --account <KEEPER_ACCOUNT>` (Foundry keystore, default
 * "triplex-keeper"). This process never sees a private key. For unattended runs, point KEEPER_PASSWORD_FILE at a
 * file containing the keystore password (chmod 600), or export ETH_PASSWORD; otherwise cast prompts.
 *
 * Env:
 *   RPC_URL                 default https://rpc.mainnet.chain.robinhood.com
 *   CHAIN_ID                default 4663 (reads contracts/deployments/<CHAIN_ID>.json)
 *   KEEPER_ACCOUNT          default triplex-keeper
 *   KEEPER_PASSWORD_FILE    optional
 *   KEEPER_ADDRESS          optional, used to pre-simulate from the keeper's address
 *   POLL_INTERVAL_MS        default 30000
 *   HARVEST                 "1" to also harvest + distribute fees once per day (keeper needs OPERATOR_ROLE on FeeCollector)
 *   DRY_RUN                 "1" to only log what would be sent
 *   ONCE                    "1" to run a single pass and exit
 */
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, parseAbi, type Address } from "viem";

const here = dirname(fileURLToPath(import.meta.url));
const RPC_URL = process.env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com";
const CHAIN_ID = Number(process.env.CHAIN_ID ?? "4663");
const ACCOUNT = process.env.KEEPER_ACCOUNT ?? "triplex-keeper";
const PASSWORD_FILE = process.env.KEEPER_PASSWORD_FILE;
const KEEPER_ADDRESS = process.env.KEEPER_ADDRESS as Address | undefined;
const POLL = Number(process.env.POLL_INTERVAL_MS ?? "30000");
const DRY = process.env.DRY_RUN === "1";
const ONCE = process.env.ONCE === "1";
const HARVEST = process.env.HARVEST === "1";

type Deployment = {
  chainId: number;
  rebalancer: Address;
  feeCollector: Address;
  marketClock: Address;
  products: { symbol: string; address: Address }[];
};

const MODES = ["None", "Daily", "Emergency"] as const;

const rebalancerAbi = parseAbi([
  "function check(address product) view returns (uint8 mode, uint256 leverage, bool increase, uint256 chunk, bool ready)",
  "function rebalance(address product) returns (uint8)",
  "function paused() view returns (bool)",
]);
const clockAbi = parseAbi(["function isMintRedeemOpen() view returns (bool)", "function tradingDayId(uint256) view returns (uint256)"]);
const erc20Abi = parseAbi(["function balanceOf(address) view returns (uint256)"]);

function loadDeployment(): Deployment {
  const file = resolve(here, "../contracts/deployments", `${CHAIN_ID}.json`);
  return JSON.parse(readFileSync(file, "utf8")) as Deployment;
}

const log = (...a: unknown[]) => console.log(new Date().toISOString(), ...a);
const fmt = (wad: bigint) => (wad === 2n ** 256n - 1n ? "inf" : (Number(wad) / 1e18).toFixed(4));

function castSend(to: Address, sig: string, args: string[]): boolean {
  const cmd = ["send", "--rpc-url", RPC_URL, "--account", ACCOUNT, to, sig, ...args];
  if (PASSWORD_FILE) cmd.splice(5, 0, "--password-file", PASSWORD_FILE);
  if (DRY) {
    log("[dry-run] cast", cmd.join(" "));
    return true;
  }
  const r = spawnSync("cast", cmd, { encoding: "utf8", stdio: ["inherit", "pipe", "pipe"] });
  if (r.status !== 0) {
    log("cast send failed:", (r.stderr || r.stdout || "").trim().split("\n").slice(-3).join(" | "));
    return false;
  }
  const hash = r.stdout.match(/transactionHash\s+(0x[0-9a-fA-F]{64})/)?.[1];
  log("sent", sig, args.join(","), hash ?? "");
  return true;
}

async function main() {
  const dep = loadDeployment();
  const client = createPublicClient({ transport: http(RPC_URL, { retryCount: 5, retryDelay: 1500 }) });
  log(`keeper up: chain ${CHAIN_ID}, ${dep.products.length} products, account "${ACCOUNT}"${DRY ? " (dry run)" : ""}`);
  let lastHarvestDay = -1n;

  for (;;) {
    try {
      const paused = await client.readContract({ address: dep.rebalancer, abi: rebalancerAbi, functionName: "paused" });
      if (paused) log("rebalancer paused by guardian; waiting");
      else {
        for (const p of dep.products) {
          // A product may need several TWAP chunks; take at most a few per pass to stay polite with the RPC.
          for (let step = 0; step < 5; step++) {
            const [mode, lev, inc, chunk, ready] = await client.readContract({
              address: dep.rebalancer,
              abi: rebalancerAbi,
              functionName: "check",
              args: [p.address],
            });
            if (mode === 0 || !ready) break;
            log(`${p.symbol}: ${MODES[mode]} lev=${fmt(lev)} ${chunk === 0n ? "snapshot" : `${inc ? "+" : "-"}${fmt(chunk)} exposure`}`);
            try {
              await client.simulateContract({
                address: dep.rebalancer,
                abi: rebalancerAbi,
                functionName: "rebalance",
                args: [p.address],
                account: KEEPER_ADDRESS,
              });
            } catch (e) {
              log(`${p.symbol}: simulation reverted, skipping:`, (e as Error).message.split("\n")[0]);
              break;
            }
            if (!castSend(dep.rebalancer, "rebalance(address)", [p.address]) || DRY) break;
          }
        }
      }

      if (HARVEST) {
        const now = BigInt(Math.floor(Date.now() / 1000));
        const day = await client.readContract({ address: dep.marketClock, abi: clockAbi, functionName: "tradingDayId", args: [now] });
        const open = await client.readContract({ address: dep.marketClock, abi: clockAbi, functionName: "isMintRedeemOpen" });
        if (open && day !== lastHarvestDay) {
          for (const p of dep.products) {
            const bal = await client.readContract({ address: p.address, abi: erc20Abi, functionName: "balanceOf", args: [dep.feeCollector] });
            if (bal > 0n) castSend(dep.feeCollector, "harvest(address,uint256,uint256)", [p.address, "0", String(now + 600n)]);
          }
          castSend(dep.feeCollector, "distribute()", []);
          lastHarvestDay = day;
        }
      }
    } catch (e) {
      log("pass failed:", (e as Error).message.split("\n")[0]);
    }
    if (ONCE) return;
    await new Promise((r) => setTimeout(r, POLL));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
