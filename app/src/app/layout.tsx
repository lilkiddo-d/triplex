import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { Footer } from "@/components/Footer";
import { Header } from "@/components/Header";
import "./globals.css";
import { Providers } from "./providers";

export const metadata: Metadata = {
  title: { default: "Triplex: leveraged tokens on tokenized stocks", template: "%s · Triplex" },
  description:
    "Auto-rebalancing 3x/2x long and 1x/2x short tokens on tokenized stocks. High risk, short holding periods only.",
};

export const viewport: Viewport = { themeColor: "#07080c" };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Header />
          <main className="mx-auto max-w-6xl px-4 py-6 sm:py-8">{children}</main>
          <Footer />
        </Providers>
      </body>
    </html>
  );
}
