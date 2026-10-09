import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  coinbaseWallet,
  injectedWallet,
  metaMaskWallet,
  rabbyWallet,
  rainbowWallet,
  walletConnectWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http } from "wagmi";
import { activeChain, localFork, robinhoodChain } from "./chains";
import { ENV } from "./env";

const appName = "Triplex";
const projectId = ENV.walletConnectProjectId;

// Without a WalletConnect project id only injected (browser extension) wallets are offered, so the app
// builds and runs without any third-party credentials.
const connectors = connectorsForWallets(
  projectId
    ? [
        { groupName: "Popular", wallets: [injectedWallet, metaMaskWallet, rabbyWallet, rainbowWallet, coinbaseWallet] },
        { groupName: "More", wallets: [walletConnectWallet] },
      ]
    : [{ groupName: "Browser wallet", wallets: [injectedWallet] }],
  { appName, projectId: projectId || "triplex-injected-only" },
);

export const wagmiConfig = createConfig({
  chains: [activeChain],
  connectors,
  transports: {
    [robinhoodChain.id]: http(undefined, { batch: true }),
    [localFork.id]: http(undefined, { batch: true }),
  },
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
