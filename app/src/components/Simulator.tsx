"use client";

import { useMemo, useState } from "react";

/** Deterministic PRNG (mulberry32) so a given seed always produces the same path. */
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Standard normal via Box-Muller. */
function normal(r: () => number) {
  const u = Math.max(r(), 1e-12);
  const v = r();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}

function parseSequence(s: string): number[] | undefined {
  const parts = s
    .split(/[,\s;]+/)
    .map((x) => x.replace("%", "").trim())
    .filter(Boolean);
  if (parts.length === 0 || parts.length > 500) return undefined;
  const nums = parts.map(Number);
  if (nums.some((n) => !Number.isFinite(n) || n <= -100 || n > 1000)) return undefined;
  return nums.map((n) => n / 100);
}

export interface SimResult {
  underlying: number[];
  leveraged: number[];
  wipedOutDay?: number;
}

/** Daily-rebalanced leveraged path. A day with 1 + L*r <= 0 wipes the product out (value 0 thereafter). */
export function simulate(returns: number[], leverage: number): SimResult {
  const underlying = [100];
  const leveraged = [100];
  let wipedOutDay: number | undefined;
  for (let i = 0; i < returns.length; i++) {
    const r = returns[i];
    underlying.push(underlying[i] * (1 + r));
    const prev = leveraged[i];
    const next = prev * (1 + leverage * r);
    if (next <= 0 && wipedOutDay === undefined) wipedOutDay = i + 1;
    leveraged.push(next <= 0 || prev === 0 ? 0 : next);
  }
  return { underlying, leveraged, wipedOutDay };
}

const LEVERAGES = [
  { v: 3, label: "3x long" },
  { v: 2, label: "2x long" },
  { v: -1, label: "1x short" },
  { v: -2, label: "2x short" },
];

const pct = (x: number) => `${x >= 0 ? "+" : ""}${(x * 100).toFixed(2)}%`;

export function Simulator() {
  const [leverage, setLeverage] = useState(3);
  const [mode, setMode] = useState<"random" | "custom">("random");
  const [vol, setVol] = useState(3); // daily % std dev
  const [drift, setDrift] = useState(0); // daily % mean
  const [days, setDays] = useState(60);
  const [seed, setSeed] = useState(7);
  const [seq, setSeq] = useState("10, -10, 10, -10, 10, -10");

  const parsed = useMemo(() => (mode === "custom" ? parseSequence(seq) : undefined), [mode, seq]);
  const returns = useMemo(() => {
    if (mode === "custom") return parsed ?? [];
    const r = rng(seed);
    return Array.from({ length: days }, () => drift / 100 + (vol / 100) * normal(r));
  }, [mode, parsed, seed, days, drift, vol]);

  const sim = useMemo(() => simulate(returns, leverage), [returns, leverage]);
  const n = returns.length;
  const uRet = sim.underlying[n] / 100 - 1;
  const lRet = sim.leveraged[n] / 100 - 1;
  const naive = leverage * uRet;

  return (
    <div className="card">
      <div className="grid gap-4 md:grid-cols-[260px_1fr]">
        <div className="space-y-4 text-sm">
          <div>
            <div className="label mb-1.5">Product</div>
            <div className="grid grid-cols-2 gap-1.5">
              {LEVERAGES.map((l) => (
                <button
                  key={l.v}
                  onClick={() => setLeverage(l.v)}
                  className={`rounded-md border px-2 py-1.5 text-xs font-semibold ${
                    leverage === l.v ? "border-brand-500 bg-brand-500/10 text-brand-300" : "border-ink-700 text-zinc-400"
                  }`}
                >
                  {l.label}
                </button>
              ))}
            </div>
          </div>
          <div>
            <div className="label mb-1.5">Daily returns</div>
            <div className="flex rounded-lg border border-ink-700 bg-ink-950 p-1 text-xs">
              {(["random", "custom"] as const).map((m) => (
                <button
                  key={m}
                  onClick={() => setMode(m)}
                  className={`flex-1 rounded-md px-2 py-1 font-semibold ${mode === m ? "bg-ink-800 text-zinc-50" : "text-zinc-400"}`}
                >
                  {m === "random" ? "Volatility" : "Custom sequence"}
                </button>
              ))}
            </div>
          </div>
          {mode === "random" ? (
            <>
              <Slider label="Daily volatility" value={vol} min={0} max={8} step={0.25} unit="%" onChange={setVol} />
              <Slider label="Daily drift" value={drift} min={-1} max={1} step={0.05} unit="%" onChange={setDrift} />
              <Slider label="Trading days" value={days} min={5} max={250} step={5} unit="" onChange={setDays} />
              <button className="btn btn-ghost w-full" onClick={() => setSeed((s) => s + 1)}>
                New random path
              </button>
            </>
          ) : (
            <div>
              <label className="label" htmlFor="seq">
                Daily % moves (comma separated)
              </label>
              <textarea
                id="seq"
                className="input mt-1 h-24 text-sm"
                value={seq}
                onChange={(e) => setSeq(e.target.value)}
              />
              {!parsed && <p className="mt-1 text-xs text-rose-300">Enter numbers like: 10, -10, 5</p>}
            </div>
          )}
        </div>

        <div className="min-w-0">
          <Chart sim={sim} leverage={leverage} />
          <div className="mt-3 grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
            <Summary label="Underlying" value={pct(uRet)} tone={uRet} />
            <Summary label={`${Math.abs(leverage)}x ${leverage > 0 ? "long" : "short"} token`} value={pct(lRet)} tone={lRet} />
            <Summary label={`Naive ${leverage}x underlying`} value={pct(naive)} tone={naive} />
            <Summary label="Path effect" value={pct(lRet - naive)} tone={lRet - naive} />
          </div>
          {sim.wipedOutDay !== undefined && (
            <p className="mt-2 text-xs text-rose-300">
              Day {sim.wipedOutDay}: a single move of {(100 / Math.abs(leverage)).toFixed(0)}% against the position wiped
              the token out. (In practice emergency rebalances try to cut exposure earlier, but gaps can skip past them.)
            </p>
          )}
          <p className="mt-2 text-xs text-zinc-500">
            Simplified model: leverage reset to exactly {leverage}x every day, no fees, borrow costs or slippage.
          </p>
        </div>
      </div>
    </div>
  );
}

function Slider(props: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  unit: string;
  onChange: (v: number) => void;
}) {
  return (
    <div>
      <div className="flex justify-between">
        <span className="label">{props.label}</span>
        <span className="font-mono text-xs text-zinc-300">
          {props.value}
          {props.unit}
        </span>
      </div>
      <input
        type="range"
        className="mt-1 w-full accent-[#7c5cff]"
        min={props.min}
        max={props.max}
        step={props.step}
        value={props.value}
        onChange={(e) => props.onChange(Number(e.target.value))}
        aria-label={props.label}
      />
    </div>
  );
}

function Summary({ label, value, tone }: { label: string; value: string; tone: number }) {
  return (
    <div className="rounded-lg bg-ink-950 p-2.5">
      <div className="text-[11px] text-zinc-500">{label}</div>
      <div className={`font-mono ${tone > 0 ? "text-emerald-400" : tone < 0 ? "text-rose-400" : "text-zinc-300"}`}>
        {value}
      </div>
    </div>
  );
}

function Chart({ sim, leverage }: { sim: SimResult; leverage: number }) {
  const W = 640;
  const H = 260;
  const pad = { l: 44, r: 12, t: 12, b: 24 };
  const all = [...sim.underlying, ...sim.leveraged];
  const yMax = Math.max(...all, 110);
  const yMin = Math.min(...all, 90);
  const n = sim.underlying.length - 1;
  const x = (i: number) => pad.l + (n === 0 ? 0 : (i / n) * (W - pad.l - pad.r));
  const y = (v: number) => pad.t + (1 - (v - yMin) / (yMax - yMin || 1)) * (H - pad.t - pad.b);
  const path = (vals: number[]) => vals.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join("");
  const ticks = 4;
  const yTicks = Array.from({ length: ticks + 1 }, (_, i) => yMin + ((yMax - yMin) * i) / ticks);

  return (
    <div>
      <svg viewBox={`0 0 ${W} ${H}`} className="h-auto w-full" role="img" aria-label="Underlying vs leveraged value">
        {yTicks.map((t) => (
          <g key={t}>
            <line x1={pad.l} x2={W - pad.r} y1={y(t)} y2={y(t)} stroke="#252a37" strokeWidth="1" />
            <text x={pad.l - 6} y={y(t) + 4} textAnchor="end" fontSize="10" fill="#71717a">
              {t.toFixed(0)}
            </text>
          </g>
        ))}
        <line x1={pad.l} x2={W - pad.r} y1={y(100)} y2={y(100)} stroke="#52525b" strokeDasharray="4 4" />
        <path d={path(sim.underlying)} fill="none" stroke="#a1a1aa" strokeWidth="2" />
        <path d={path(sim.leveraged)} fill="none" stroke="#7c5cff" strokeWidth="2.25" />
        <text x={pad.l} y={H - 6} fontSize="10" fill="#71717a">
          day 0
        </text>
        <text x={W - pad.r} y={H - 6} fontSize="10" fill="#71717a" textAnchor="end">
          day {n}
        </text>
      </svg>
      <div className="mt-1 flex gap-4 text-xs text-zinc-400">
        <span className="flex items-center gap-1.5">
          <span className="h-0.5 w-4 bg-zinc-400" /> Underlying (start 100)
        </span>
        <span className="flex items-center gap-1.5">
          <span className="h-0.5 w-4 bg-brand-500" /> {leverage > 0 ? `${leverage}x long` : `${-leverage}x short`} token
        </span>
      </div>
    </div>
  );
}
