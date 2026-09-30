# Karat Trend Divergence EA — v1.10 (Fixed & Reviewed)

**File:** `KaratTrend_Divergence_EA.mq5`
**Timeframe:** 4H
**Style:** Swing trading — moderate frequency
**Magic number:** 190422
**Trade comment:** "KaratTrend"

Strategy: RSI + Stochastic divergence (regular, plus hidden/continuation where enabled),
confirmed by a price-action candle (engulfing / strong body / pin-bar), filtered by an
EMA trend regime, with ATR-based stop-loss, R-multiple take-profit, breakeven and ATR
trailing management, and a daily loss circuit breaker.

## Key parameters (defaults shipped in this file)

| Parameter | Value |
|---|---|
| Pivot arm (left/right) | 5 / 5 bars |
| Max pivot age | 60 bars |
| Min bars between pivots | 5 |
| Hidden divergence | Off |
| RSI period | 14 |
| Stochastic %K/%D/slowing | 14 / 3 / 3 |
| Trend EMA | 200 |
| SL = ATR x | 1.5 |
| Reward:Risk | 2.0R |
| Risk % per trade | 1.0% |
| Max trades/day | 3 |
| Max daily loss | 3.0% |

## Notes specific to this desk

Classic 14/14 RSI-Stochastic settings on a 4H chart with a 200-EMA regime filter — the middle-ground desk between the scalper and the weekly accumulator.

## What changed vs. the uploaded version (v1.00 -> v1.10)

1. **Explicit `InpTimeframe` input.** The original code called every indicator/price
   function with `PERIOD_CURRENT`, i.e. it silently used whatever chart the EA was
   dropped on. Now the EA has its own `InpTimeframe` input (defaults to
   `PERIOD_CURRENT`, so existing behaviour is unchanged if you leave it alone), used
   everywhere internally, so the signal timeframe is explicit and chart-independent.
2. **Broker min-stop / freeze-level check before sending an order.** SL/TP is computed
   from ATR and the pivot price. On many gold (XAU) brokers, a tight ATR-based stop can
   land inside the broker's minimum stop distance and the order gets rejected --
   invisibly wasting a signal. `ExecuteEntry()` now reads `SYMBOL_TRADE_STOPS_LEVEL` /
   `SYMBOL_TRADE_FREEZE_LEVEL` and skips the trade (with a log line) instead of firing
   an order that would bounce.
3. **Fixed a resource/logic leak in `OnTick()`.** When `InpOnePositionAtATime = true`
   and a position was already open, the original still scanned for new divergences and
   could arm the confirmation watcher, relying only on the later `canTrade` check inside
   `ExecuteEntry()` to prevent a second position. It now returns immediately once a
   position is open (unless a confirmation is already in flight), so a fresh signal
   isn't silently discarded mid-confirmation of a stale one.
4. **Re-check spread right before firing, not just at signal time.** A divergence can
   wait up to `InpConfirmationTimeoutBars` bars for a price-action candle; spread can
   widen in that window. `SpreadOK()` is now checked again immediately before
   `ExecuteEntry()` is called from the confirmation branch.
5. **Divide-by-zero guards.** `CalculateLotSize()` and `DailyLossLimitHit()` both
   divided by account equity / day-start equity with no guard -- a blown or freshly
   reset (0-balance) test account would throw a runtime error. Both now return safely
   (`0` lots / `false`) if equity is `<= 0`.
6. **Cleaned up a dead bounds check** in `FindLastPivotLow` / `FindLastPivotHigh`.
   Replaced an unreachable condition with an explicit `ArraySize()` check so the pivot
   scan can never read outside the array it was actually given.
7. Version bumped to `1.10` in `#property version`.

## What was *not* changed (flagged for your attention)

- **Position sizing assumes a linear tick value** (`SYMBOL_TRADE_TICK_VALUE /
  SYMBOL_TRADE_TICK_SIZE`), correct for spot gold (XAUUSD) on most brokers but can
  misprice risk on instruments with non-linear contract specs. Confirm with your broker
  if you run this on anything else.
- **No news filter.** Gold is highly news-sensitive (NFP, CPI, FOMC). Consider pairing
  with a session/news-blackout filter.


## Installation

1. Copy `KaratTrend_Divergence_EA.mq5` into `MQL5/Experts/AUTREND/` in your MetaTrader 5 data folder
   (File -> Open Data Folder).
2. Restart MT5 or right-click **Experts** in the Navigator -> Refresh.
3. Compile in MetaEditor (F7) -- should build with 0 errors, 0 warnings on MT5 build
   3800+.
4. Drag onto a chart of the symbol you intend to trade (XAUUSD recommended -- these
   presets were tuned for gold's volatility profile).
5. Set `InpTimeframe` to **4H** (the input is chart-independent as of v1.10, so
   the chart itself no longer has to match, but keeping it aligned makes `Comment()`
   overlays match what you're watching).
6. Enable **Algo Trading** and review the risk inputs (`InpRiskPercent`,
   `InpMaxDailyLossPercent`) before going live.

## Running alongside the other AUTREND desks

This EA's magic number (190422) and trade comment ("KaratTrend") are unique
across the four-desk family, so it can run on the same account/symbol simultaneously
with the others without interfering in position counting or daily-loss tracking. Size
your total gold exposure across desks accordingly -- risk limits here are scoped per
EA (per magic number), not per account.

See `BACKTEST.md` in this package for how to test this EA correctly in the Strategy
Tester, and `KaratTrend_signal_lab.ipynb` for a Python reproduction of the signal formulas
for faster parameter research outside MT5.
