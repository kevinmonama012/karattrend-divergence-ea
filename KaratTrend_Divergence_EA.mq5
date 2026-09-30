//+------------------------------------------------------------------+
//|                                    KaratTrend_Divergence_EA.mq5   |
//|   Karat Trend — RSI/Stoch Divergence + Price Action (4H)          |
//|   AUTREND desk 2: 4H swing trading, moderate frequency             |
//+------------------------------------------------------------------+
#property copyright "AUTREND"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

//================================= INPUTS ====================================

input group "=== Chart / Timeframe ==="
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT; // Signal timeframe (explicit, chart-independent)

input group "=== Divergence Detection ==="
input int      InpPivotLeft        = 5;        // Bars left of pivot (fractal arm)
input int      InpPivotRight       = 5;        // Bars right of pivot (fractal arm)
input int      InpMaxPivotAgeBars  = 60;        // Ignore pivots older than this (bars)
input int      InpMinBarsBetweenPivots = 5;     // Min spacing between the two compared pivots
input bool     InpRequireBothDivergences = true;// Require RSI AND Stochastic divergence together
input bool     InpAllowHiddenDivergence  = false;// Also trade hidden (continuation) divergence

input group "=== RSI Settings ==="
input int      InpRSIPeriod        = 14;
input ENUM_APPLIED_PRICE InpRSIPrice = PRICE_CLOSE;

input group "=== Stochastic Settings ==="
input int      InpStochK           = 14;
input int      InpStochD           = 3;
input int      InpStochSlowing     = 3;
input ENUM_MA_METHOD InpStochMAMethod = MODE_SMA;
input ENUM_STO_PRICE  InpStochPriceField = STO_LOWHIGH;
input double   InpStochOverbought  = 80.0;
input double   InpStochOversold    = 20.0;

input group "=== Price Action Confirmation ==="
input bool     InpRequirePriceAction = true;    // Require candle confirmation before entry
input double   InpMinBodyToRangeRatio = 0.55;   // Engulfing/marubozu-like body strength
input double   InpMinWickRejectionRatio = 0.55; // Pin-bar / hammer wick-to-range ratio
input int      InpConfirmationTimeoutBars = 5;   // Bars allowed to wait for confirmation after divergence

input group "=== Trend / Regime Filter ==="
input bool     InpUseTrendFilter   = true;
input int      InpTrendEMAPeriod   = 200;
input bool     InpOnlyCounterTrendAtExtremes = true; // Only fade the trend when Stoch is at OB/OS

input group "=== Volatility / Session Filters ==="
input int      InpATRPeriod        = 14;
input double   InpMinATRPips       = 0;        // 0 = disabled, else min ATR in pips to trade
input int      InpMaxSpreadPoints  = 300;       // Reject entries if spread too high
input bool     InpUseSessionFilter = false;
input int      InpSessionStartHour = 7;         // Broker server time
input int      InpSessionEndHour   = 20;

input group "=== Risk Management ==="
input double   InpRiskPercent      = 1.0;       // % of equity risked per trade
input double   InpSL_ATR_Mult      = 1.5;       // SL = pivot +/- ATR * mult
input double   InpRR_Ratio         = 2.0;       // TP as multiple of risk (R multiple)
input bool     InpUseTrailingStop  = true;
input double   InpTrailStartR      = 1.0;       // Start trailing after this many R in profit
input double   InpTrailATRMult     = 1.2;       // Trailing distance = ATR * mult
input bool     InpUseBreakeven     = true;
input double   InpBreakevenR       = 0.8;        // Move SL to breakeven after this many R

input group "=== Trade Management ==="
input int      InpMagicNumber      = 190422;
input string   InpTradeComment     = "KaratTrend";
input bool     InpOnePositionAtATime = true;
input int      InpMaxTradesPerDay  = 3;
input double   InpMaxDailyLossPercent = 3.0;     // Stop trading for the day after this drawdown

//================================= GLOBALS ====================================

int      hRSI, hStochMain, hATR, hTrendEMA;
double   rsiBuf[], stochMainBuf[], stochSignalBuf[], atrBuf[], emaBuf[];

datetime lastBarTime = 0;

// Pending confirmation state (waiting for price-action candle after a divergence fires)
bool     waitingConfirm = false;
bool     waitingIsBullish = false;
int      waitingBarsElapsed = 0;
double   waitingPivotPrice = 0;
datetime waitingPivotTime = 0;

// Daily loss tracking
double   dayStartEquity = 0;
datetime currentDay = 0;
int      tradesToday = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   hRSI       = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, InpRSIPrice);
   hStochMain = iStochastic(_Symbol, InpTimeframe, InpStochK, InpStochD, InpStochSlowing,
                             InpStochMAMethod, InpStochPriceField);
   hATR       = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   hTrendEMA  = iMA(_Symbol, InpTimeframe, InpTrendEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(hRSI == INVALID_HANDLE || hStochMain == INVALID_HANDLE ||
      hATR == INVALID_HANDLE || hTrendEMA == INVALID_HANDLE)
     {
      Print("Indicator handle creation failed");
      return(INIT_FAILED);
     }

   ArraySetAsSeries(rsiBuf, true);
   ArraySetAsSeries(stochMainBuf, true);
   ArraySetAsSeries(stochSignalBuf, true);
   ArraySetAsSeries(atrBuf, true);
   ArraySetAsSeries(emaBuf, true);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   currentDay = TimeCurrent() - (TimeCurrent() % 86400);

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(hRSI);
   IndicatorRelease(hStochMain);
   IndicatorRelease(hATR);
   IndicatorRelease(hTrendEMA);
  }

//+------------------------------------------------------------------+
//| Returns true once per new closed bar                             |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, InpTimeframe, 0);
   if(t != lastBarTime)
     {
      lastBarTime = t;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Reset the daily counters on a new calendar day                   |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   datetime todayStart = TimeCurrent() - (TimeCurrent() % 86400);
   if(todayStart != currentDay)
     {
      currentDay = todayStart;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      tradesToday = 0;
     }
  }

//+------------------------------------------------------------------+
//| Hard risk gate: daily loss limit                                 |
//+------------------------------------------------------------------+
bool DailyLossLimitHit()
  {
   if(dayStartEquity <= 0) return(false);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (dayStartEquity - equity) / dayStartEquity * 100.0;
   return(lossPct >= InpMaxDailyLossPercent);
  }

//+------------------------------------------------------------------+
//| Spread / session gates                                           |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spread <= InpMaxSpreadPoints);
  }

bool SessionOK()
  {
   if(!InpUseSessionFilter) return(true);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpSessionStartHour <= InpSessionEndHour)
      return(dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);
   // overnight session wrap
   return(dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);
  }

bool VolatilityOK()
  {
   if(InpMinATRPips <= 0) return(true);
   double pip = _Point * ((_Digits == 3 || _Digits == 5) ? 10 : 1);
   return(atrBuf[0] >= InpMinATRPips * pip);
  }

//+------------------------------------------------------------------+
//| Pivot detection (simple fractal: strict local extreme)           |
//| Returns true and fills idx with the bar index (shift) of the     |
//| most recent CONFIRMED pivot low/high within the lookback window. |
//+------------------------------------------------------------------+
bool FindLastPivotLow(int searchFrom, int &idxOut, const double &lowArr[])
  {
   int arraySize = ArraySize(lowArr);
   for(int i = searchFrom; i < InpMaxPivotAgeBars; i++)
     {
      int center = i + InpPivotRight; // pivot candidate index (series indexing)
      if(center + InpPivotLeft >= arraySize) break; // stay inside the buffer we actually copied
      bool isPivot = true;
      double centerVal = lowArr[center];
      for(int L = 1; L <= InpPivotLeft; L++)
         if(lowArr[center + L] < centerVal) { isPivot = false; break; }
      if(isPivot)
         for(int R = 1; R <= InpPivotRight; R++)
            if(lowArr[center - R] < centerVal) { isPivot = false; break; }
      if(isPivot)
        {
         idxOut = center;
         return(true);
        }
     }
   return(false);
  }

bool FindLastPivotHigh(int searchFrom, int &idxOut, const double &highArr[])
  {
   int arraySize = ArraySize(highArr);
   for(int i = searchFrom; i < InpMaxPivotAgeBars; i++)
     {
      int center = i + InpPivotRight;
      if(center + InpPivotLeft >= arraySize) break; // stay inside the buffer we actually copied
      bool isPivot = true;
      double centerVal = highArr[center];
      for(int L = 1; L <= InpPivotLeft; L++)
         if(highArr[center + L] > centerVal) { isPivot = false; break; }
      if(isPivot)
         for(int R = 1; R <= InpPivotRight; R++)
            if(highArr[center - R] > centerVal) { isPivot = false; break; }
      if(isPivot)
        {
         idxOut = center;
         return(true);
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Divergence structure result                                      |
//+------------------------------------------------------------------+
struct DivResult
  {
   bool     found;
   bool     bullish;      // true = bullish (buy) signal
   bool     hidden;       // true = hidden/continuation divergence
   int      pivotIdx;     // bar shift of the most recent pivot used
   double   pivotPrice;
   datetime pivotTime;
  };

//+------------------------------------------------------------------+
//| Generic divergence check between price pivots and an oscillator  |
//+------------------------------------------------------------------+
DivResult CheckDivergence(const double &lowArr[], const double &highArr[], const double &oscArr[])
  {
   DivResult res;
   res.found = false; res.bullish = false; res.hidden = false;
   res.pivotIdx = -1; res.pivotPrice = 0; res.pivotTime = 0;

   int idx1 = -1, idx2 = -1;

   // --- Bullish (price low vs osc low) ---
   if(FindLastPivotLow(1, idx1, lowArr))
     {
      int nextSearch = idx1 + InpMinBarsBetweenPivots;
      if(FindLastPivotLow(nextSearch, idx2, lowArr))
        {
         double priceNew = lowArr[idx1];
         double priceOld = lowArr[idx2];
         double oscNew   = oscArr[idx1];
         double oscOld    = oscArr[idx2];

         // Regular bullish: lower price low, higher (rising) oscillator low
         if(priceNew < priceOld && oscNew > oscOld)
           {
            res.found = true; res.bullish = true; res.hidden = false;
            res.pivotIdx = idx1; res.pivotPrice = priceNew;
            res.pivotTime = iTime(_Symbol, InpTimeframe, idx1);
            return(res);
           }
         // Hidden bullish (trend continuation): higher price low, lower oscillator low
         if(InpAllowHiddenDivergence && priceNew > priceOld && oscNew < oscOld)
           {
            res.found = true; res.bullish = true; res.hidden = true;
            res.pivotIdx = idx1; res.pivotPrice = priceNew;
            res.pivotTime = iTime(_Symbol, InpTimeframe, idx1);
            return(res);
           }
        }
     }

   // --- Bearish (price high vs osc high) ---
   if(FindLastPivotHigh(1, idx1, highArr))
     {
      int nextSearch = idx1 + InpMinBarsBetweenPivots;
      if(FindLastPivotHigh(nextSearch, idx2, highArr))
        {
         double priceNew = highArr[idx1];
         double priceOld = highArr[idx2];
         double oscNew   = oscArr[idx1];
         double oscOld    = oscArr[idx2];

         // Regular bearish: higher price high, lower (falling) oscillator high
         if(priceNew > priceOld && oscNew < oscOld)
           {
            res.found = true; res.bullish = false; res.hidden = false;
            res.pivotIdx = idx1; res.pivotPrice = priceNew;
            res.pivotTime = iTime(_Symbol, InpTimeframe, idx1);
            return(res);
           }
         // Hidden bearish: lower price high, higher oscillator high
         if(InpAllowHiddenDivergence && priceNew < priceOld && oscNew > oscOld)
           {
            res.found = true; res.bullish = false; res.hidden = true;
            res.pivotIdx = idx1; res.pivotPrice = priceNew;
            res.pivotTime = iTime(_Symbol, InpTimeframe, idx1);
            return(res);
           }
        }
     }

   return(res);
  }

//+------------------------------------------------------------------+
//| Price-action confirmation candle check                           |
//| Bullish: bullish engulfing OR hammer/pin-bar with lower wick      |
//| Bearish: bearish engulfing OR shooting star/pin-bar upper wick    |
//+------------------------------------------------------------------+
bool IsBullishConfirmationCandle(int shift)
  {
   double o = iOpen(_Symbol, InpTimeframe, shift);
   double c = iClose(_Symbol, InpTimeframe, shift);
   double h = iHigh(_Symbol, InpTimeframe, shift);
   double l = iLow(_Symbol, InpTimeframe, shift);
   double range = h - l;
   if(range <= 0) return(false);

   double body = MathAbs(c - o);
   double lowerWick = MathMin(o, c) - l;
   bool isBull = c > o;

   // Strong bullish body (marubozu-like / engulfing candidate)
   bool strongBody = isBull && (body / range >= InpMinBodyToRangeRatio);

   // Engulfing check against prior candle
   double oPrev = iOpen(_Symbol, InpTimeframe, shift + 1);
   double cPrev = iClose(_Symbol, InpTimeframe, shift + 1);
   bool engulfing = isBull && (c > oPrev) && (o < cPrev) && (cPrev < oPrev); // prior bar bearish, fully engulfed

   // Hammer / pin bar: long lower wick, small body, close in upper half
   bool pinBar = (lowerWick / range >= InpMinWickRejectionRatio) && (c > (l + range * 0.5));

   return(strongBody || engulfing || pinBar);
  }

bool IsBearishConfirmationCandle(int shift)
  {
   double o = iOpen(_Symbol, InpTimeframe, shift);
   double c = iClose(_Symbol, InpTimeframe, shift);
   double h = iHigh(_Symbol, InpTimeframe, shift);
   double l = iLow(_Symbol, InpTimeframe, shift);
   double range = h - l;
   if(range <= 0) return(false);

   double body = MathAbs(c - o);
   double upperWick = h - MathMax(o, c);
   bool isBear = c < o;

   bool strongBody = isBear && (body / range >= InpMinBodyToRangeRatio);

   double oPrev = iOpen(_Symbol, InpTimeframe, shift + 1);
   double cPrev = iClose(_Symbol, InpTimeframe, shift + 1);
   bool engulfing = isBear && (c < oPrev) && (o > cPrev) && (cPrev > oPrev);

   bool pinBar = (upperWick / range >= InpMinWickRejectionRatio) && (c < (h - range * 0.5));

   return(strongBody || engulfing || pinBar);
  }

//+------------------------------------------------------------------+
//| Trend filter: only take longs above EMA / shorts below EMA,      |
//| unless InpOnlyCounterTrendAtExtremes allows a fade at OB/OS      |
//+------------------------------------------------------------------+
bool TrendAllows(bool wantBullish)
  {
   if(!InpUseTrendFilter) return(true);

   double price = iClose(_Symbol, InpTimeframe, 1);
   double ema   = emaBuf[1];
   bool aboveEMA = price > ema;

   if(wantBullish && aboveEMA) return(true);
   if(!wantBullish && !aboveEMA) return(true);

   // Counter-trend: only allow if stochastic confirms a genuine extreme
   if(InpOnlyCounterTrendAtExtremes)
     {
      if(wantBullish && stochMainBuf[1] <= InpStochOversold) return(true);
      if(!wantBullish && stochMainBuf[1] >= InpStochOverbought) return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Position sizing based on % equity risk and SL distance           |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0) return(0);
   double riskAmount = equity * (InpRiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return(0);

   double valuePerPriceUnit = tickValue / tickSize; // account currency per 1.0 price move, per 1 lot
   double slValuePerLot = slDistancePrice * valuePerPriceUnit;
   if(slValuePerLot <= 0) return(0);

   double lots = riskAmount / slValuePerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return(NormalizeDouble(lots, 2));
  }

//+------------------------------------------------------------------+
//| Count open positions for this EA/symbol                          |
//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            count++;
        }
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Open the trade with ATR-based SL and R-multiple TP                |
//+------------------------------------------------------------------+
void ExecuteEntry(bool bullish, double pivotPrice)
  {
   double atr = atrBuf[0];
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl, tp, entry, slDistance;

   if(bullish)
     {
      entry = ask;
      sl = MathMin(pivotPrice, iLow(_Symbol, InpTimeframe, 1)) - atr * InpSL_ATR_Mult;
      slDistance = entry - sl;
      if(slDistance <= 0) return;
      tp = entry + slDistance * InpRR_Ratio;
     }
   else
     {
      entry = bid;
      sl = MathMax(pivotPrice, iHigh(_Symbol, InpTimeframe, 1)) + atr * InpSL_ATR_Mult;
      slDistance = sl - entry;
      if(slDistance <= 0) return;
      tp = entry - slDistance * InpRR_Ratio;
     }

   double lots = CalculateLotSize(slDistance);
   if(lots <= 0)
     {
      Print("Lot size calculation returned 0 - skipping trade");
      return;
     }

   // --- Broker minimum stop / freeze distance validation ---
   double stopLevelPts  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double freezeLvlPts  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDistPts    = MathMax(stopLevelPts, freezeLvlPts);
   double minDistPrice  = minDistPts * _Point;
   if(minDistPrice > 0)
     {
      if(MathAbs(entry - sl) < minDistPrice || MathAbs(entry - tp) < minDistPrice)
        {
         Print("SL/TP inside broker's minimum stop distance (", (long)minDistPts,
               " pts) - skipping trade to avoid a rejected order");
         return;
        }
     }

   bool ok;
   if(bullish)
      ok = trade.Buy(lots, _Symbol, 0, sl, tp, InpTradeComment);
   else
      ok = trade.Sell(lots, _Symbol, 0, sl, tp, InpTradeComment);

   if(ok)
     {
      tradesToday++;
      Print(bullish ? "BUY" : "SELL", " opened | lots=", lots, " SL=", sl, " TP=", tp);
     }
   else
      Print("Order failed: ", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Manage open trade: breakeven + ATR trailing stop                 |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   double atr = atrBuf[0];
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      long   type      = posInfo.PositionType();
      double openPrice = posInfo.PriceOpen();
      double curSL      = posInfo.StopLoss();
      double curTP      = posInfo.TakeProfit();
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double originalRiskDist = MathAbs(openPrice - curSL);
      if(originalRiskDist <= 0) continue;

      if(type == POSITION_TYPE_BUY)
        {
         double profitR = (bid - openPrice) / originalRiskDist;

         if(InpUseBreakeven && profitR >= InpBreakevenR && curSL < openPrice)
            trade.PositionModify(posInfo.Ticket(), openPrice, curTP);

         if(InpUseTrailingStop && profitR >= InpTrailStartR)
           {
            double newSL = bid - atr * InpTrailATRMult;
            if(newSL > curSL && newSL < bid)
               trade.PositionModify(posInfo.Ticket(), newSL, curTP);
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double profitR = (openPrice - ask) / originalRiskDist;

         if(InpUseBreakeven && profitR >= InpBreakevenR && (curSL > openPrice || curSL == 0))
            trade.PositionModify(posInfo.Ticket(), openPrice, curTP);

         if(InpUseTrailingStop && profitR >= InpTrailStartR)
           {
            double newSL = ask + atr * InpTrailATRMult;
            if((newSL < curSL || curSL == 0) && newSL > ask)
               trade.PositionModify(posInfo.Ticket(), newSL, curTP);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Main tick handler                                                 |
//+------------------------------------------------------------------+
void OnTick()
  {
   CheckNewDay();
   ManageOpenPositions();

   if(!IsNewBar()) return; // everything below evaluates once per closed bar

   // --- Refresh indicator buffers ---
   if(CopyBuffer(hRSI, 0, 0, InpMaxPivotAgeBars + InpPivotLeft + InpPivotRight + 5, rsiBuf) <= 0) return;
   if(CopyBuffer(hStochMain, 0, 0, InpMaxPivotAgeBars + InpPivotLeft + InpPivotRight + 5, stochMainBuf) <= 0) return;
   if(CopyBuffer(hATR, 0, 0, 5, atrBuf) <= 0) return;
   if(CopyBuffer(hTrendEMA, 0, 0, 5, emaBuf) <= 0) return;

   int barsNeeded = InpMaxPivotAgeBars + InpPivotLeft + InpPivotRight + 5;
   double lowArr[], highArr[];
   ArraySetAsSeries(lowArr, true);
   ArraySetAsSeries(highArr, true);
   if(CopyLow(_Symbol, InpTimeframe, 0, barsNeeded, lowArr) <= 0) return;
   if(CopyHigh(_Symbol, InpTimeframe, 0, barsNeeded, highArr) <= 0) return;

   // --- Hard risk gates ---
   if(DailyLossLimitHit())
     {
      Comment("DivConfluence EA: daily loss limit hit - trading paused");
      return;
     }
   if(tradesToday >= InpMaxTradesPerDay) return;
   bool positionOpen = (InpOnePositionAtATime && CountMyPositions() > 0);
   if(!SpreadOK() || !SessionOK() || !VolatilityOK()) return;

   // A position is already open under this magic number and only one is allowed:
   // let it be managed by ManageOpenPositions() above, but do not look for new signals.
   if(positionOpen && !waitingConfirm) return;

   // --- Handle a pending confirmation from a prior bar first ---
   if(waitingConfirm)
     {
      waitingBarsElapsed++;
      bool confirmed = waitingIsBullish ? IsBullishConfirmationCandle(1) : IsBearishConfirmationCandle(1);

      if(confirmed)
        {
         bool canTrade = !InpOnePositionAtATime || CountMyPositions() == 0;
         if(canTrade && SpreadOK() && TrendAllows(waitingIsBullish))
            ExecuteEntry(waitingIsBullish, waitingPivotPrice);
         waitingConfirm = false;
        }
      else if(waitingBarsElapsed >= InpConfirmationTimeoutBars)
        {
         waitingConfirm = false; // confirmation window expired, discard signal
        }
      return; // don't also scan for a brand-new divergence on the same bar
     }

   // --- Scan for new divergence signals ---
   DivResult rsiDiv   = CheckDivergence(lowArr, highArr, rsiBuf);
   DivResult stochDiv = CheckDivergence(lowArr, highArr, stochMainBuf);

   bool signalBullish = false, signalBearish = false;
   double pivotPrice = 0;

   if(InpRequireBothDivergences)
     {
      if(rsiDiv.found && stochDiv.found && rsiDiv.bullish && stochDiv.bullish &&
         MathAbs(rsiDiv.pivotIdx - stochDiv.pivotIdx) <= InpPivotLeft) // pivots should align
        {
         signalBullish = true;
         pivotPrice = rsiDiv.pivotPrice;
        }
      if(rsiDiv.found && stochDiv.found && !rsiDiv.bullish && !stochDiv.bullish &&
         MathAbs(rsiDiv.pivotIdx - stochDiv.pivotIdx) <= InpPivotLeft)
        {
         signalBearish = true;
         pivotPrice = rsiDiv.pivotPrice;
        }
     }
   else
     {
      if(rsiDiv.found && rsiDiv.bullish) { signalBullish = true; pivotPrice = rsiDiv.pivotPrice; }
      if(stochDiv.found && stochDiv.bullish) { signalBullish = true; pivotPrice = stochDiv.pivotPrice; }
      if(rsiDiv.found && !rsiDiv.bullish) { signalBearish = true; pivotPrice = rsiDiv.pivotPrice; }
      if(stochDiv.found && !stochDiv.bullish) { signalBearish = true; pivotPrice = stochDiv.pivotPrice; }
     }

   if(!signalBullish && !signalBearish) return;
   if(signalBullish && signalBearish) return; // conflicting - skip for safety

   bool wantBullish = signalBullish;

   if(!TrendAllows(wantBullish)) return;

   if(InpRequirePriceAction)
     {
      // Arm the confirmation watcher; entry happens on a later bar once a
      // qualifying price-action candle prints.
      waitingConfirm = true;
      waitingIsBullish = wantBullish;
      waitingBarsElapsed = 0;
      waitingPivotPrice = pivotPrice;
      Print("Divergence detected (", wantBullish ? "bullish" : "bearish",
            "). Waiting up to ", InpConfirmationTimeoutBars, " bars for price-action confirmation.");
     }
   else
     {
      bool canTrade = !InpOnePositionAtATime || CountMyPositions() == 0;
      if(canTrade)
         ExecuteEntry(wantBullish, pivotPrice);
     }
  }
//+------------------------------------------------------------------+
