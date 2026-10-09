import type { Address } from "viem";
import { zeroAddress } from "viem";
import d4663 from "./4663.json";
import d31337 from "./31337.json";

/** Schema written by contracts/script/Deploy.s.sol (see ./README.md). */
export interface DeploymentProduct {
  symbol: string;
  address: Address;
  adapter: Address;
  underlying: Address;
  underlyingSymbol: string;
  isLong: boolean;
  targetLeverage: number;
}

export interface Deployment {
  chainId: number;
  deployBlock: number;
  quoteToken: Address;
  factory: Address;
  navCalculator: Address;
  rebalancer: Address;
  oracle: Address;
  marketClock: Address;
  feeCollector: Address;
  projectTokenHooks: Address;
  complianceRegistry: Address;
  timelock: Address;
  products: DeploymentProduct[];
}

/** Static import map: add a line here when a new chain gets a deployment file. */
const DEPLOYMENTS: Record<number, unknown> = {
  4663: d4663,
  31337: d31337,
};

function emptyDeployment(chainId: number): Deployment {
  return {
    chainId,
    deployBlock: 0,
    quoteToken: zeroAddress,
    factory: zeroAddress,
    navCalculator: zeroAddress,
    rebalancer: zeroAddress,
    oracle: zeroAddress,
    marketClock: zeroAddress,
    feeCollector: zeroAddress,
    projectTokenHooks: zeroAddress,
    complianceRegistry: zeroAddress,
    timelock: zeroAddress,
    products: [],
  };
}

export function getDeployment(chainId: number): Deployment {
  const raw = DEPLOYMENTS[chainId] as Partial<Deployment> | undefined;
  if (!raw) return emptyDeployment(chainId);
  const base = emptyDeployment(chainId);
  return { ...base, ...raw, products: raw.products ?? [] } as Deployment;
}

export function isDeployed(d: Deployment): boolean {
  return d.factory !== zeroAddress && d.navCalculator !== zeroAddress;
}

export const isSet = (a: Address | undefined | null): a is Address =>
  !!a && a.toLowerCase() !== zeroAddress;
