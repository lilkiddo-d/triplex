import { formatUnits, maxUint256, parseUnits } from "viem";

export const WAD = 10n ** 18n;
export const BPS = 10_000n;

/** Format a bigint with `decimals` to a human string with at most `maxFrac` fraction digits. */
export function fmtUnits(value: bigint | undefined, decimals: number, maxFrac = 2, minFrac = 0): string {
  if (value === undefined) return "-";
  const s = formatUnits(value, decimals);
  return groupDecimalString(roundDecimalString(s, maxFrac), minFrac);
}

export const fmtWad = (v: bigint | undefined, maxFrac = 2, minFrac = 0) => fmtUnits(v, 18, maxFrac, minFrac);

/** Round a decimal string (possibly negative) to `frac` digits, half away from zero, using bigint math only. */
function roundDecimalString(s: string, frac: number): string {
  const neg = s.startsWith("-");
  const abs = neg ? s.slice(1) : s;
  const [i, f = ""] = abs.split(".");
  const scaled = BigInt(i + f.padEnd(frac + 1, "0").slice(0, frac + 1));
  const rounded = (scaled + 5n) / 10n; // keeps `frac` digits
  let str = rounded.toString().padStart(frac + 1, "0");
  const intPart = frac > 0 ? str.slice(0, -frac) : str;
  let fracPart = frac > 0 ? str.slice(-frac) : "";
  fracPart = fracPart.replace(/0+$/, "");
  str = fracPart ? `${intPart}.${fracPart}` : intPart;
  return neg && /[1-9]/.test(str) ? `-${str}` : str;
}

function groupDecimalString(s: string, minFrac: number): string {
  const neg = s.startsWith("-");
  const abs = neg ? s.slice(1) : s;
  const [i, f = ""] = abs.split(".");
  const grouped = i.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const fr = f.padEnd(minFrac, "0");
  return `${neg ? "-" : ""}${grouped}${fr ? `.${fr}` : ""}`;
}

/** USD-like display of a WAD quote value (e.g. equity / TVL). */
export function fmtUsdWad(v: bigint | undefined, maxFrac = 2): string {
  if (v === undefined) return "-";
  return `$${fmtWad(v, maxFrac, Math.min(2, maxFrac))}`;
}

/** Compact USD for big numbers (display only). */
export function fmtUsdCompact(v: bigint | undefined): string {
  if (v === undefined) return "-";
  const n = Number(formatUnits(v, 18));
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    notation: n >= 100_000 ? "compact" : "standard",
    maximumFractionDigits: 2,
  }).format(n);
}

/** Leverage (WAD) as "2.98x"; type(uint256).max means the product has no equity. */
export function fmtLeverage(v: bigint | undefined, frac = 2): string {
  if (v === undefined) return "-";
  if (v === maxUint256) return "no equity";
  return `${fmtWad(v, frac, frac)}x`;
}

/** Signed WAD return (int256) as "+2.91%". */
export function fmtPctWad(v: bigint | undefined, frac = 2): string {
  if (v === undefined) return "-";
  const pct = v * 100n; // still WAD-scaled
  const s = fmtWad(pct, frac, frac);
  return v > 0n ? `+${s}%` : `${s}%`;
}

export function fmtBps(bps: bigint | number | undefined): string {
  if (bps === undefined) return "-";
  const n = typeof bps === "bigint" ? Number(bps) : bps;
  return `${(n / 100).toFixed(2).replace(/\.?0+$/, "")}%`;
}

/** Parse user input safely; returns undefined for empty/invalid input. */
export function safeParseUnits(input: string, decimals: number): bigint | undefined {
  const t = input.trim();
  if (!t || !/^\d*\.?\d*$/.test(t) || t === ".") return undefined;
  const [, f = ""] = t.split(".");
  if (f.length > decimals) return undefined;
  try {
    return parseUnits(t, decimals);
  } catch {
    return undefined;
  }
}

export function shortAddr(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

export function signClass(v: bigint | undefined): string {
  if (v === undefined || v === 0n) return "text-zinc-300";
  return v > 0n ? "text-emerald-400" : "text-rose-400";
}

export function fmtTime(tsSeconds: bigint | number | undefined): string {
  if (tsSeconds === undefined) return "-";
  const n = Number(tsSeconds);
  if (!n) return "-";
  return new Date(n * 1000).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** WAD -> JS number, for display geometry only (never for amounts sent on-chain). */
export function wadToNum(v: bigint): number {
  return Number(formatUnits(v, 18));
}
