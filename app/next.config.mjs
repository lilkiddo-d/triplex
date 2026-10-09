/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // No lint step is configured for this package; type checking still runs during `next build`.
  eslint: { ignoreDuringBuilds: true },
  webpack: (config) => {
    // Optional peer deps pulled in by WalletConnect / MetaMask SDK that are not needed in the browser.
    config.externals.push("pino-pretty", "lokijs", "encoding");
    config.resolve.fallback = { ...config.resolve.fallback, "@react-native-async-storage/async-storage": false };
    // @coinbase/cdp-sdk (pulled in transitively by wagmi's Base Account connector) imports optional x402 payment
    // packages that are not installed and never used here; resolve them to empty modules.
    config.resolve.alias = {
      ...config.resolve.alias,
      ...Object.fromEntries(
        ["@x402/core", "@x402/evm", "@x402/svm", "@x402/express", "@x402/extensions", "@x402/fetch"].map((m) => [m, false]),
      ),
    };
    return config;
  },
};

export default nextConfig;
