import type { Metadata } from "next";
import Link from "next/link";
import { Simulator } from "@/components/Simulator";

export const metadata: Metadata = { title: "Learn: volatility decay" };

const EXAMPLE = [
  { day: "Start", move: "", u: "100.00", l: "100.00" },
  { day: "Day 1", move: "+10%", u: "110.00", l: "130.00 (+30%)" },
  { day: "Day 2", move: "−10%", u: "99.00", l: "91.00 (−30%)" },
];

export default function LearnPage() {
  return (
    <article className="prose-tx mx-auto max-w-3xl">
      <h1 className="text-2xl font-bold text-zinc-50 sm:text-3xl">How daily-leveraged tokens behave</h1>
      <p className="mt-2">
        A Triplex token such as <strong>3L-NVDA</strong> targets <strong>3x the daily move</strong> of the underlying
        stock token. Each trading day it is rebalanced back to 3x near the US close. That design keeps the token from
        drifting to extreme leverage, but it has a side effect that surprises many people: over periods longer than one
        day, the token does <strong>not</strong> return 3x what the stock returned.
      </p>

      <h2>A worked example</h2>
      <p>The stock goes up 10% one day and down 10% the next.</p>
      <div className="card mb-4 overflow-x-auto p-0">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-ink-700 text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-4 py-2">Day</th>
              <th className="px-4 py-2">Stock move</th>
              <th className="px-4 py-2 text-right">Stock</th>
              <th className="px-4 py-2 text-right">3x daily token</th>
            </tr>
          </thead>
          <tbody>
            {EXAMPLE.map((r) => (
              <tr key={r.day} className="border-b border-ink-800 last:border-0">
                <td className="px-4 py-2 text-zinc-300">{r.day}</td>
                <td className="px-4 py-2 font-mono text-zinc-300">{r.move}</td>
                <td className="px-4 py-2 text-right font-mono text-zinc-200">{r.u}</td>
                <td className="px-4 py-2 text-right font-mono text-zinc-200">{r.l}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p>
        After two days the stock is down <strong>1%</strong> (100 → 99). You might expect the 3x token to be down 3%. It
        is down <strong>9%</strong> (100 → 91). Each day it really did deliver 3x the stock&apos;s move, +30% and then
        −30%, but a 30% loss on 130 is a bigger dollar loss than a 30% gain on 100.
      </p>
      <p>
        This is called <strong>volatility decay</strong> (or path dependency). The more the price swings back and forth,
        the more the token lags 3x the overall return. In a steady trend the effect can work the other way: three +5%
        days take the stock up 15.8% and a 3x token up 52.1%, more than 3 × 15.8%. You cannot know in advance which one
        you will get, so these tokens are built for <strong>short holding periods</strong>, typically one day.
      </p>

      <h2>Try it yourself</h2>
      <p>
        Pick a product, then either set a daily volatility (random path) or type your own sequence of daily moves. The
        chart starts both lines at 100.
      </p>
      <div className="not-prose mb-6">
        <Simulator />
      </div>

      <h2>How Triplex keeps leverage on target</h2>
      <h3>Daily rebalance at the US close</h3>
      <p>
        During the day, leverage drifts as the price moves. A long token&apos;s leverage falls when the stock rises and
        rises when it falls; a short token behaves the opposite way. Shortly before the 4:00 pm ET close a keeper calls
        the rebalancer, which buys or sells in chunks until leverage is back at target. Afterwards the token records a
        daily snapshot of its NAV and the stock price. The &quot;today&quot; figures on the products page are measured
        from that snapshot.
      </p>
      <h3>Emergency rebalances</h3>
      <p>
        Every product has a leverage band around its target (shown on each product page). If a large intraday move pushes leverage
        outside the band, the rebalancer acts right away instead of waiting for the close, to keep the position safely
        away from the lending venue&apos;s liquidation threshold.
      </p>
      <h3>Overnight and weekend gaps</h3>
      <p>
        Stock prices can jump between sessions: overnight, over weekends and holidays, or on news. The position
        can&apos;t be rebalanced while the market is closed, so the full gap hits a leveraged token at once. A{" "}
        <strong>~33% adverse gap wipes out a 3x token</strong> (~50% for 2x long or 2x short, 100% for 1x short).
        Emergency rebalances can&apos;t help with a gap they never see.
      </p>
      <h3>Mint and redeem hours</h3>
      <p>
        Minting and redeeming are only open during US regular market hours (09:35–15:45 ET on NYSE trading days), so
        trades happen while the stock&apos;s price feed is live and its market is liquid.
      </p>

      <p className="mt-8">
        Before using any product, read the full <Link href="/risk">risk disclosure</Link>.
      </p>
    </article>
  );
}
