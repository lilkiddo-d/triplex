"use client";

import { ConnectButton } from "@rainbow-me/rainbowkit";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import { activeChain } from "@/config";
import { useTokenFeatures } from "@/hooks/useTokenFeatures";
import { Logo } from "./Logo";

export function Header() {
  const pathname = usePathname() ?? "/";
  const { active: tokenActive } = useTokenFeatures();
  const [open, setOpen] = useState(false);
  const links = [
    { href: "/", label: "Products" },
    { href: "/learn", label: "Learn" },
    { href: "/risk", label: "Risk" },
    ...(tokenActive ? [{ href: "/stake", label: "Stake" }] : []),
  ];
  const isActive = (href: string) =>
    href === "/" ? pathname === "/" || pathname.startsWith("/product") : pathname.startsWith(href);

  return (
    <header className="sticky top-0 z-30 border-b border-ink-700 bg-ink-950/85 backdrop-blur">
      <div className="mx-auto flex max-w-6xl items-center gap-3 px-4 py-3">
        <Link href="/" aria-label="Triplex home">
          <Logo />
        </Link>
        <nav className="ml-4 hidden items-center gap-1 md:flex">
          {links.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className={`rounded-md px-3 py-1.5 text-sm font-medium ${
                isActive(l.href) ? "bg-ink-800 text-zinc-50" : "text-zinc-400 hover:text-zinc-100"
              }`}
            >
              {l.label}
            </Link>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-2">
          {activeChain.id === 31337 && (
            <span className="hidden rounded-md border border-amber-500/40 bg-amber-500/10 px-2 py-1 text-xs text-amber-300 sm:inline">
              Local fork
            </span>
          )}
          <ConnectButton
            chainStatus="icon"
            accountStatus={{ smallScreen: "avatar", largeScreen: "full" }}
            showBalance={false}
          />
          <button
            className="rounded-md border border-ink-700 p-2 text-zinc-300 md:hidden"
            onClick={() => setOpen((o) => !o)}
            aria-label="Toggle menu"
            aria-expanded={open}
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M4 7h16M4 12h16M4 17h16" />
            </svg>
          </button>
        </div>
      </div>
      {open && (
        <nav className="border-t border-ink-700 px-4 py-2 md:hidden">
          {links.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              onClick={() => setOpen(false)}
              className={`block rounded-md px-3 py-2 text-sm ${
                isActive(l.href) ? "bg-ink-800 text-zinc-50" : "text-zinc-400"
              }`}
            >
              {l.label}
            </Link>
          ))}
        </nav>
      )}
    </header>
  );
}
