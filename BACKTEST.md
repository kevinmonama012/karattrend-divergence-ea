# Backtest Guide — Karat Trend Divergence EA

Covers how to backtest `KaratTrend_Divergence_EA.mq5` correctly in the MT5 Strategy Tester, and how to
read the results without fooling yourself.

## 1. Data quality first

Divergence detection and the price-action confirmation candle both depend on accurate
high/low/open/close on every bar, not just closes -- tick data quality matters more
here than for a simple moving-average system.

- **Model:** use "Every tick based on real ticks" if available for XAUUSD in your date
  range; fall back to "Every tick" (simulated) otherwise.
- **Download history first:** MT5 -> View -> Symbols -> XAUUSD -> request the full
  range for **4H** *and* `PERIOD_M1` (the tester needs M1 to simulate intrabar
  price paths for "Every tick").
- **Date range:** 5+ years -- weekly bars produce few trades per year, so a short window may only contain a handful of trades.

## 2. Strategy Tester setup

| Setting | Value |
|---|---|
| Symbol | XAUUSD (or your broker's gold symbol) |
| Chart timeframe / `InpTimeframe` | 4H (set `InpTimeframe` explicitly -- v1.10 makes the chart's own timeframe irrelevant) |
| Model | Every tick based on real ticks |
| Deposit | Match your real/intended account size -- position sizing is % equity based |
| Leverage | Match your real account |
| Spread | Set to your broker's realistic *average* spread, not the tightest you've seen -- `InpMaxSpreadPoints` is a hard gate |
| Optimization | Off for a first pass -- get a baseline before optimizing |

## 3. Reading the report -- in order

1. **Trade count first.** Single digits means none of the stats below are meaningful
   yet -- widen the date range rather than trusting a small sample.
2. **Profit factor & expectancy**, not just net profit -- one large win can mask
   negative expectancy.
3. **Max drawdown by equity, not just balance** -- reflects open-position pain.
4. **Consecutive losses** against `InpMaxDailyLossPercent` (3.0%)
   to see how many bad days in a row this desk can realistically produce.
5. **Distribution across time** -- open the report graph and check no single regime
   (one trending quarter) is carrying the whole result.

## 4. Position-sizing sanity check

`CalculateLotSize()` sizes off current account equity at `InpRiskPercent` =
**1.0%**. On a small account, lot rounding
(`SYMBOL_VOLUME_MIN`/step) can push actual risk above that percentage; on a large
account, `SYMBOL_VOLUME_MAX` can silently cap position size below what the risk
setting calls for. Check the tester's per-trade dollar risk directly, not just the %.

## 5. Walk-forward / out-of-sample check

1. Split history into in-sample (first ~70%) and out-of-sample (last ~30%).
2. Only optimize inputs (Strategy Tester -> Optimization) on the in-sample window, then
   run the chosen set once, untouched, out-of-sample.
3. A set that only works in-sample is overfit -- the pivot-based inputs here
   (`InpPivotLeft/Right`, `InpMaxPivotAgeBars`, RSI/Stoch periods) are easy to
   curve-fit to one window.

## 6. Forward test before live

Run on a demo account for at least 4-6 weeks of live conditions before funding it,
to confirm execution/slippage assumptions hold at this frequency.

## 7. Using the notebook alongside the tester

`KaratTrend_signal_lab.ipynb` reimplements this EA's divergence/pivot/confirmation-candle
formulas in Python with this desk's exact parameter preset, so you can research and
visualize signals faster than MT5's built-in optimizer. It does not model spread,
slippage, execution, or the daily-loss lock -- treat it as a signal-quality research
tool and confirm any promising region of parameters with a real Strategy Tester run.
