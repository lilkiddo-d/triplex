import type { Metadata } from "next";
import Link from "next/link";
import { RiskAckBox } from "@/components/RiskAckBox";

export const metadata: Metadata = { title: "Risk disclosure" };

export default function RiskPage() {
  return (
    <article className="prose-tx mx-auto max-w-3xl">
      <h1 className="text-2xl font-bold text-zinc-50 sm:text-3xl">Risk disclosure</h1>
      <p className="mt-2">
        Triplex tokens are leveraged and inverse products. They are complex, high-risk instruments. Read this page in
        full before minting. If you do not understand how these products work, do not use them.
      </p>

      <h2>Short holding periods only</h2>
      <p>
        Each token targets a multiple of the underlying&apos;s <strong>daily</strong> return and is rebalanced every
        trading day. Over more than one day, returns can differ substantially from the target multiple of the
        underlying&apos;s return, especially in volatile markets (see <Link href="/learn">volatility decay</Link>). The
        products are designed for short holding periods and active monitoring.
      </p>

      <h2>You can lose most or all of your money quickly</h2>
      <p>
        Losses are magnified by leverage. A sequence of adverse or choppy moves can erode most of a token&apos;s value
        within days, and a single large move can wipe it out.
      </p>

      <h2>Overnight, weekend and gap risk</h2>
      <ul>
        <li>
          Positions can only be rebalanced while the market is open. Price gaps between sessions (overnight, weekends,
          holidays, trading halts) hit the token in full.
        </li>
        <li>
          An adverse move of about <strong>33% wipes out a 3x product</strong>; about <strong>50%</strong> wipes out a 2x
          long or 2x short product; a 100% rise wipes out a 1x short.
        </li>
        <li>Emergency (band-triggered) rebalances cannot protect against a move that happens while the market is closed.</li>
      </ul>

      <h2>Lending venue and liquidation risk</h2>
      <p>
        Leverage is obtained by borrowing on <strong>Morpho Blue</strong>. If the position&apos;s loan-to-value exceeds the
        market&apos;s liquidation LTV (for example after a large gap) it can be liquidated by third parties at a penalty,
        causing losses beyond the price move itself. Morpho market liquidity, interest rates and bad-debt events are
        outside Triplex&apos;s control.
      </p>

      <h2>Oracle risk</h2>
      <p>
        NAV, leverage and liquidations depend on <strong>Chainlink</strong> price feeds. Stock feeds run on a 24/5
        schedule and may be stale, paused or wrong, particularly around market closures, corporate actions or feed
        incidents. When a price is unavailable, Triplex shows &quot;price unavailable&quot; and mint/redeem may be
        blocked.
      </p>

      <h2>Smart-contract risk</h2>
      <p>
        The Triplex contracts are <strong>unaudited</strong>. They interact with third-party contracts (Morpho, Uniswap,
        Chainlink, token issuers). Bugs or exploits in any of them can result in a total loss of funds.
      </p>

      <h2>Liquidity and slippage</h2>
      <p>
        Minting and redeeming trade the underlying through on-chain liquidity (Uniswap). Thin liquidity, large orders or
        volatile markets cause slippage, so you may receive less than the displayed NAV. Your slippage setting limits
        this; if exceeded, the transaction reverts.
      </p>

      <h2>Tokenized stocks are not shares</h2>
      <p>
        The underlying stock tokens are <strong>tokenized debt securities issued by a third party</strong> that track a
        share price. They are not the shares themselves and carry no shareholder rights. They are subject to the
        issuer&apos;s credit, operational, legal and redemption risks, and may trade at a discount or premium to the
        reference stock.
      </p>

      <h2>Trading hours</h2>
      <p>
        Mint and redeem are only possible during US regular market hours, <strong>09:35–15:45 ET on NYSE trading days</strong>.
        Outside those hours you cannot enter or exit through Triplex, even if the price moves sharply.
      </p>

      <h2>Governance and pauses</h2>
      <p>
        Protocol parameters are changed through governance with a <strong>48-hour timelock</strong>. A guardian can{" "}
        <strong>pause</strong> products, the rebalancer and the market clock at any time without delay, which can
        temporarily prevent minting, redeeming or rebalancing.
      </p>

      <h2>Fees</h2>
      <p>
        Mint and redeem fees and a streaming management fee apply. Rebalancing and borrowing costs are borne by the
        product and reduce NAV over time.
      </p>

      <h2>Not investment advice; restricted jurisdictions</h2>
      <p>
        Nothing on this site is investment, legal or tax advice, or an offer or solicitation to buy or sell any
        security. Triplex is <strong>not available to persons in restricted jurisdictions</strong>, including where
        access to leveraged products or tokenized securities is prohibited. You are responsible for complying with the
        laws that apply to you.
      </p>

      <RiskAckBox />
    </article>
  );
}
