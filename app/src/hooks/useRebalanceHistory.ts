"use client";

import { useQuery } from "@tanstack/react-query";
import { getAbiItem, type Address, type Hash } from "viem";
import { usePublicClient } from "wagmi";
import { leveragedTokenAbi, rebalancerAbi } from "@/abi";
import { deployment } from "@/config";
import { isSet } from "@/config/deployments";

/** Max blocks per eth_getLogs request (public RPC limit). */
export const LOG_CHUNK = 50_000n;
/** Hard cap on how far back we scan, to keep the page light on a rate-limited public RPC. */
export const MAX_LOOKBACK_BLOCKS = 1_000_000n;
/** Max rows shown / block timestamps fetched. */
const MAX_ROWS = 50;

const rebalancedEvent = getAbiItem({ abi: rebalancerAbi, name: "Rebalanced" });
const snapshotEvent = getAbiItem({ abi: leveragedTokenAbi, name: "DailySnapshot" });

export type HistoryRow =
  | {
      kind: "rebalance";
      mode: number; // 1 = Daily, 2 = Emergency
      increase: boolean;
      chunkWad: bigint;
      leverageBefore: bigint;
      leverageAfter: bigint;
      navPerShare: bigint;
      price: bigint;
      blockNumber: bigint;
      logIndex: number;
      txHash: Hash;
      timestamp?: bigint;
    }
  | {
      kind: "snapshot";
      day: bigint;
      navPerShare: bigint;
      price: bigint;
      blockNumber: bigint;
      logIndex: number;
      txHash: Hash;
      timestamp?: bigint;
    };

export function useRebalanceHistory(product: Address | undefined) {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["rebalance-history", client?.chain.id, product],
    enabled: !!client && !!product,
    staleTime: 60_000,
    refetchInterval: 120_000,
    queryFn: async () => {
      if (!client || !product) return { rows: [] as HistoryRow[], fromBlock: 0n, toBlock: 0n, capped: false };
      const latest = await client.getBlockNumber();
      const deployBlock = BigInt(deployment.deployBlock ?? 0);
      const floor = latest > MAX_LOOKBACK_BLOCKS ? latest - MAX_LOOKBACK_BLOCKS : 0n;
      const fromBlock = deployBlock > floor ? deployBlock : floor;
      const capped = fromBlock > deployBlock;

      const rows: HistoryRow[] = [];
      // Walk backwards from the tip so the most recent rows arrive first; stop once we have enough.
      for (let end = latest; end >= fromBlock; ) {
        const start = end - LOG_CHUNK + 1n > fromBlock ? end - LOG_CHUNK + 1n : fromBlock;
        const [reb, snap] = await Promise.all([
          isSet(deployment.rebalancer)
            ? client.getLogs({
                address: deployment.rebalancer,
                event: rebalancedEvent,
                args: { product },
                fromBlock: start,
                toBlock: end,
              })
            : Promise.resolve([]),
          client.getLogs({ address: product, event: snapshotEvent, fromBlock: start, toBlock: end }),
        ]);
        for (const l of reb) {
          const a = l.args;
          if (a.leverageBefore === undefined || l.blockNumber === null || l.transactionHash === null) continue;
          rows.push({
            kind: "rebalance",
            mode: Number(a.mode ?? 0),
            increase: !!a.increase,
            chunkWad: a.chunkWad ?? 0n,
            leverageBefore: a.leverageBefore,
            leverageAfter: a.leverageAfter ?? 0n,
            navPerShare: a.navPerShare ?? 0n,
            price: a.price ?? 0n,
            blockNumber: l.blockNumber,
            logIndex: l.logIndex ?? 0,
            txHash: l.transactionHash,
          });
        }
        for (const l of snap) {
          const a = l.args;
          if (a.day === undefined || l.blockNumber === null || l.transactionHash === null) continue;
          rows.push({
            kind: "snapshot",
            day: a.day,
            navPerShare: a.navPerShare ?? 0n,
            price: a.underlyingPrice ?? 0n,
            blockNumber: l.blockNumber,
            logIndex: l.logIndex ?? 0,
            txHash: l.transactionHash,
            timestamp: a.timestamp,
          });
        }
        if (rows.length >= MAX_ROWS || start === 0n) break;
        end = start - 1n;
      }

      rows.sort((x, y) =>
        x.blockNumber === y.blockNumber ? y.logIndex - x.logIndex : x.blockNumber > y.blockNumber ? -1 : 1,
      );
      const shown = rows.slice(0, MAX_ROWS);

      // Rebalanced has no timestamp field: fetch block timestamps (JSON-RPC batched by the transport).
      const need = [...new Set(shown.filter((r) => r.timestamp === undefined).map((r) => r.blockNumber))];
      const ts = new Map<bigint, bigint>();
      await Promise.all(
        need.map(async (bn) => {
          try {
            const b = await client.getBlock({ blockNumber: bn });
            ts.set(bn, b.timestamp);
          } catch {
            /* timestamp is optional */
          }
        }),
      );
      for (const r of shown) if (r.timestamp === undefined) r.timestamp = ts.get(r.blockNumber);

      return { rows: shown, fromBlock, toBlock: latest, capped };
    },
  });
}
