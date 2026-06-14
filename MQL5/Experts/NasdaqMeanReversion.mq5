//+------------------------------------------------------------------+
//|                                          NasdaqMeanReversion.mq5 |
//|              Estrategia: "Nasdaq Mean Reversion" (estilo RSI-2)  |
//|                                                                  |
//|  CONCEPTO (swing, evaluado al cierre de vela DIARIA):            |
//|  En un índice en tendencia alcista de fondo, las caídas bruscas  |
//|  de corto plazo tienden a REVERTIR. Compramos la sobreventa      |
//|  extrema y salimos cuando el precio vuelve a su media corta.     |
//|  Es lo OPUESTO al seguimiento de tendencia: no perseguimos la    |
//|  fuerza, compramos el desplome y aprovechamos el rebote.         |
//|                                                                  |
//|  LÓGICA (solo largos):                                           |
//|   - Filtro de tendencia .....: Cierre[1] > MA(200)              |
//|                                 (solo operamos en deriva alcista)|
//|   - Entrada ..................: RSI(2)[1] < umbral (sobreventa)  |
//|   - Salida (señal) ...........: Cierre > MA corta  Y/O  RSI alto |
//|   - Stop protector ...........: ATR (amplio, swing) en servidor  |
//|   - Stop temporal ............: máximo N velas en la operación    |
//|   - Lotaje ...................: % de riesgo sobre la Equity      |
//|                                                                  |
//|  NOTA: es una estrategia SWING. Las posiciones se mantienen      |
//|  varios días (overnight incluido). El riesgo de gap se gestiona  |
//|  con el tamaño de la posición y el stop ATR puesto en el         |
//|  servidor. No hay cierre forzado intradía.                       |
//|                                                                  |
//|  Reutiliza el motor de gestión de riesgo y ejecución validado    |
//|  en el EA de momentum (lotaje dinámico, manejo de errores del    |
//|  servidor, filtros de seguridad, OnTester).                      |
//+------------------------------------------------------------------+
#property copyright "BOT-ALGOTRADING"
#property version   "1.00"
#property strict
#property description "EA de reversión a la media (MA200 + RSI-2 + ATR) para NASDAQ, swing en Diario. Solo largos."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| PARÁMETROS DE ENTRADA (todos optimizables en el Strategy Tester) |
//+------------------------------------------------------------------+
input group "=== 1. IDENTIFICACIÓN ==="
input long     InpMagicNumber        = 20260614;   // Magic Number (identificador único del EA)
input string   InpComentarioOrden    = "NQ-MeanRev"; // Comentario de las órdenes

input group "=== 2. SEÑAL DE ENTRADA ==="
input int      InpPeriodoMATendencia = 200;        // Periodo de la MA de tendencia (filtro de fondo)
input ENUM_MA_METHOD InpMetodoMA     = MODE_SMA;   // Método de la MA de tendencia
input int      InpRSIPeriodo         = 2;          // Periodo del RSI (Connors usa 2)
input double   InpRSIEntrada         = 10.0;       // Comprar si RSI < este umbral (sobreventa extrema)

input group "=== 3. SEÑAL DE SALIDA ==="
input int      InpModoSalida         = 0;          // 0=Cierre>MA corta, 1=RSI>umbral, 2=cualquiera de las dos
input int      InpPeriodoMASalida    = 5;          // Periodo de la MA corta de salida
input double   InpRSISalida          = 70.0;       // Salir si RSI > este umbral (reversión completada)
input int      InpMaxBarrasEnTrade   = 10;         // Stop temporal: máx. velas en la operación (0 = off)

input group "=== 4. GESTIÓN DE RIESGO ==="
input double   InpRiesgoPorOperacion = 1.0;        // Riesgo por operación (% de la Equity)
input int      InpPeriodoATR         = 14;         // Periodo del ATR
input double   InpMultiplicadorSL    = 2.5;        // Stop protector = ATR x este multiplicador (amplio, swing)
input bool     InpUsarStopATR        = true;       // Colocar stop protector ATR en el servidor
input double   InpLoteMaximo         = 5.0;        // Lote máximo absoluto (techo de seguridad)

input group "=== 5. FILTROS DE SEGURIDAD ==="
input int      InpSpreadMaximo       = 200;        // Spread máximo permitido (en puntos)
input int      InpSlippageMaximo     = 30;         // Desviación/Slippage máximo (en puntos)
input double   InpFactorMargenLibre  = 1.5;        // Margen libre requerido (x veces el margen de la orden)

input group "=== 6. INTERFAZ ==="
input bool     InpMostrarPanel       = true;       // Mostrar panel de estado en el gráfico

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                               |
//+------------------------------------------------------------------+
CTrade   g_trade;
int      g_handle_ma_tend = INVALID_HANDLE;   // MA de tendencia (200)
int      g_handle_ma_sal  = INVALID_HANDLE;   // MA corta de salida (5)
int      g_handle_rsi     = INVALID_HANDLE;   // RSI (2)
int      g_handle_atr     = INVALID_HANDLE;   // ATR (14)

datetime g_ultima_vela    = 0;     // Detector de vela nueva
double   g_atr_actual     = 0.0;   // ATR de la última vela cerrada

//--- Buffers (índice 0 = vela [1], la última cerrada)
double   g_ma_tend[];
double   g_ma_sal[];
double   g_rsi[];
double   g_atr[];

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- 1. Validación de parámetros
   if(InpRiesgoPorOperacion <= 0.0 || InpRiesgoPorOperacion > 10.0)
     { Print("ERROR: el riesgo por operación debe estar entre 0.1% y 10%."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpMultiplicadorSL <= 0.0)
     { Print("ERROR: el multiplicador de SL debe ser positivo."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpRSIEntrada <= 0.0 || InpRSIEntrada >= 100.0 || InpRSISalida <= 0.0 || InpRSISalida >= 100.0)
     { Print("ERROR: los umbrales de RSI deben estar entre 0 y 100."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpRSIEntrada >= InpRSISalida)
     { Print("ERROR: el umbral de entrada del RSI debe ser menor que el de salida."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpModoSalida < 0 || InpModoSalida > 2)
     { Print("ERROR: InpModoSalida debe ser 0, 1 o 2."); return(INIT_PARAMETERS_INCORRECT); }

   //--- 2. Handles de los indicadores
   g_handle_ma_tend = iMA(_Symbol, PERIOD_CURRENT, InpPeriodoMATendencia, 0, InpMetodoMA, PRICE_CLOSE);
   g_handle_ma_sal  = iMA(_Symbol, PERIOD_CURRENT, InpPeriodoMASalida, 0, MODE_SMA, PRICE_CLOSE);
   g_handle_rsi     = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriodo, PRICE_CLOSE);
   g_handle_atr     = iATR(_Symbol, PERIOD_CURRENT, InpPeriodoATR);

   if(g_handle_ma_tend == INVALID_HANDLE || g_handle_ma_sal == INVALID_HANDLE ||
      g_handle_rsi == INVALID_HANDLE || g_handle_atr == INVALID_HANDLE)
     { Print("ERROR: no se pudieron crear los indicadores. Código: ", GetLastError()); return(INIT_FAILED); }

   //--- 3. Buffers como series temporales
   ArraySetAsSeries(g_ma_tend, true);
   ArraySetAsSeries(g_ma_sal, true);
   ArraySetAsSeries(g_rsi, true);
   ArraySetAsSeries(g_atr, true);

   //--- 4. Objeto de trading
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippageMaximo);
   g_trade.SetAsyncMode(false);

   //--- 5. Filling mode soportado por el broker
   long modos_filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((modos_filling & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((modos_filling & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   Print("NasdaqMeanReversion iniciado en ", _Symbol, " (", EnumToString((ENUM_TIMEFRAMES)Period()), ")",
         " | Dígitos: ", _Digits,
         " | Cuenta: ", (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING ? "HEDGING" : "NETTING"));

   //--- Aviso si no estamos en Diario (la estrategia está pensada para D1)
   if(Period() != PERIOD_D1)
      Print("AVISO: la estrategia está diseñada para el gráfico DIARIO (D1). Timeframe actual: ", EnumToString((ENUM_TIMEFRAMES)Period()));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_handle_ma_tend != INVALID_HANDLE) IndicatorRelease(g_handle_ma_tend);
   if(g_handle_ma_sal  != INVALID_HANDLE) IndicatorRelease(g_handle_ma_sal);
   if(g_handle_rsi     != INVALID_HANDLE) IndicatorRelease(g_handle_rsi);
   if(g_handle_atr     != INVALID_HANDLE) IndicatorRelease(g_handle_atr);
   Comment("");
  }

//+------------------------------------------------------------------+
//| OnTick: motor principal                                         |
//+------------------------------------------------------------------+
void OnTick()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   if(InpMostrarPanel)
      ActualizarPanel(tick);

   //--- TODO se decide al cierre de la vela diaria (sin ruido intradía)
   if(!EsVelaNueva())
      return;

   if(!CopiarIndicadores())
      return;

   //--- 1. Si hay posición abierta, evaluamos su SALIDA por señal/tiempo
   if(ContarPosicionesPropias() > 0)
     {
      GestionarSalida();
      return; // Una sola posición: no buscamos entradas mientras haya una abierta
     }

   //--- 2. Sin posición: evaluamos la ENTRADA
   //--- Filtro de spread
   double spread_puntos = (tick.ask - tick.bid) / _Point;
   if(spread_puntos > InpSpreadMaximo)
     {
      Print("Entrada descartada: spread (", DoubleToString(spread_puntos, 0), " pts) > máximo.");
      return;
     }

   if(HaySenalDeCompra())
      AbrirLargo(tick);
  }

//+------------------------------------------------------------------+
//| Detecta vela nueva                                              |
//+------------------------------------------------------------------+
bool EsVelaNueva()
  {
   datetime apertura = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(apertura == g_ultima_vela)
      return(false);
   g_ultima_vela = apertura;
   return(true);
  }

//+------------------------------------------------------------------+
//| Copia los indicadores de la vela [1] (la última cerrada)         |
//+------------------------------------------------------------------+
bool CopiarIndicadores()
  {
   if(CopyBuffer(g_handle_ma_tend, 0, 1, 2, g_ma_tend) < 2)
     { Print("Aviso: MA tendencia sin datos."); return(false); }
   if(CopyBuffer(g_handle_ma_sal, 0, 1, 2, g_ma_sal) < 2)
     { Print("Aviso: MA salida sin datos."); return(false); }
   if(CopyBuffer(g_handle_rsi, 0, 1, 2, g_rsi) < 2)
     { Print("Aviso: RSI sin datos."); return(false); }
   if(CopyBuffer(g_handle_atr, 0, 1, 2, g_atr) < 2)
     { Print("Aviso: ATR sin datos."); return(false); }

   g_atr_actual = g_atr[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| SEÑAL DE COMPRA: tendencia alcista de fondo + sobreventa extrema |
//+------------------------------------------------------------------+
bool HaySenalDeCompra()
  {
   double cierre_1 = iClose(_Symbol, PERIOD_CURRENT, 1);

   //--- 1. Filtro de tendencia: el precio cerró por ENCIMA de la MA200.
   //    Solo compramos sobreventa dentro de una tendencia alcista de fondo;
   //    la reversión a la media en índices tiene edge a favor de la deriva.
   bool tendencia_alcista = (cierre_1 > g_ma_tend[0]);

   //--- 2. Sobreventa extrema: el RSI(2) por debajo del umbral.
   bool sobreventa = (g_rsi[0] < InpRSIEntrada);

   return(tendencia_alcista && sobreventa);
  }

//+------------------------------------------------------------------+
//| ¿Se cumple la condición de SALIDA por señal?                     |
//+------------------------------------------------------------------+
bool HaySenalDeSalida()
  {
   double cierre_1 = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool por_ma  = (cierre_1 > g_ma_sal[0]);   // El precio recuperó su media corta
   bool por_rsi = (g_rsi[0] > InpRSISalida);  // El RSI volvió a zona alta

   if(InpModoSalida == 0)
      return(por_ma);
   if(InpModoSalida == 1)
      return(por_rsi);
   return(por_ma || por_rsi);                 // Modo 2: la primera que ocurra
  }

//+------------------------------------------------------------------+
//| Gestiona la salida de la posición abierta (señal o stop temporal)|
//+------------------------------------------------------------------+
void GestionarSalida()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      //--- Salida por SEÑAL de reversión completada
      if(HaySenalDeSalida())
        {
         CerrarPosicion(ticket, "Salida por señal: reversión completada");
         return;
        }

      //--- Salida por STOP TEMPORAL (la reversión no llegó en N velas)
      if(InpMaxBarrasEnTrade > 0)
        {
         datetime apertura = (datetime)PositionGetInteger(POSITION_TIME);
         int segundos_vela = PeriodSeconds(PERIOD_CURRENT);
         if(segundos_vela > 0)
           {
            int barras = (int)((TimeCurrent() - apertura) / segundos_vela);
            if(barras >= InpMaxBarrasEnTrade)
               CerrarPosicion(ticket, "Salida por stop temporal: " + IntegerToString(barras) + " velas");
           }
        }
      return;
     }
  }

//+------------------------------------------------------------------+
//| Apertura de un largo con stop protector ATR                      |
//+------------------------------------------------------------------+
void AbrirLargo(const MqlTick &tick)
  {
   double precio_entrada = tick.ask;

   //--- Stop protector basado en ATR (amplio, propio del swing)
   double distancia_sl = g_atr_actual * InpMultiplicadorSL;
   if(distancia_sl <= 0.0)
     { Print("ERROR: ATR no válido. Operación abortada."); return; }

   double sl = 0.0;
   if(InpUsarStopATR)
     {
      sl = NormalizeDouble(precio_entrada - distancia_sl, _Digits);
      //--- Respetar la distancia mínima de stops del broker
      double stops_minimos = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      if(distancia_sl < stops_minimos)
        { Print("Entrada descartada: SL ATR menor que el mínimo del broker."); return; }
     }

   //--- Lotaje dinámico: arriesgar el 1% de la Equity hasta el stop.
   //    Si no usamos stop ATR, dimensionamos igualmente con la distancia
   //    ATR teórica para mantener el riesgo controlado (no operar a ciegas).
   double sl_puntos = distancia_sl / _Point;
   double lote = CalcularLote(sl_puntos);
   if(lote <= 0.0)
      return;

   if(!HayMargenSuficiente(lote, precio_entrada))
      return;

   //--- Envío con reintentos ante requotes (sin TP: la salida es por señal)
   for(int intento = 1; intento <= 3; intento++)
     {
      bool enviado = g_trade.Buy(lote, _Symbol, 0.0, sl, 0.0, InpComentarioOrden);
      uint retcode = g_trade.ResultRetcode();

      if(enviado && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
        {
         PrintFormat("COMPRA ejecutada | Lote: %.2f | Precio: %s | SL: %s | RSI: %.1f | ATR: %s",
                     lote, DoubleToString(g_trade.ResultPrice(), _Digits),
                     (InpUsarStopATR ? DoubleToString(sl, _Digits) : "(sin stop)"),
                     g_rsi[0], DoubleToString(g_atr_actual, _Digits));
         return;
        }

      if(retcode == TRADE_RETCODE_REQUOTE || retcode == TRADE_RETCODE_PRICE_CHANGED || retcode == TRADE_RETCODE_PRICE_OFF)
        {
         PrintFormat("Intento %d/3 fallido (retcode %u). Reintentando...", intento, retcode);
         Sleep(200);
         MqlTick t;
         if(!SymbolInfoTick(_Symbol, t))
            return;
         if(InpUsarStopATR)
            sl = NormalizeDouble(t.ask - distancia_sl, _Digits);
         continue;
        }

      PrintFormat("ERROR al abrir COMPRA. Retcode %u: %s. Abortada.", retcode, g_trade.ResultRetcodeDescription());
      return;
     }
   Print("ERROR: agotados los reintentos por requotes. Señal descartada.");
  }

//+------------------------------------------------------------------+
//| Cálculo del lotaje dinámico (riesgo % de la Equity / distancia SL)|
//+------------------------------------------------------------------+
double CalcularLote(double sl_puntos)
  {
   double equity        = AccountInfoDouble(ACCOUNT_EQUITY);
   double riesgo_dinero = equity * InpRiesgoPorOperacion / 100.0;

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_value <= 0.0 || tick_size <= 0.0 || sl_puntos <= 0.0)
     { Print("ERROR: datos del símbolo inválidos para calcular el lote."); return(0.0); }
   double valor_punto_por_lote = tick_value * (_Point / tick_size);

   double lote = riesgo_dinero / (sl_puntos * valor_punto_por_lote);

   double lote_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lote_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lote_paso = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lote = MathFloor(lote / lote_paso) * lote_paso;   // Redondeo HACIA ABAJO

   if(lote < lote_min)
     {
      double riesgo_real = (lote_min * sl_puntos * valor_punto_por_lote) / equity * 100.0;
      PrintFormat("AVISO: lote calculado (%.4f) < mínimo (%.2f). Se usa el mínimo => riesgo real ~%.2f%%.",
                  lote, lote_min, riesgo_real);
      lote = lote_min;
     }
   if(lote > lote_max)
      lote = lote_max;
   if(lote > InpLoteMaximo)
     {
      PrintFormat("AVISO: lote (%.2f) supera el techo (%.2f). Se recorta.", lote, InpLoteMaximo);
      lote = InpLoteMaximo;
     }
   return(NormalizeDouble(lote, 2));
  }

//+------------------------------------------------------------------+
//| Verifica margen libre suficiente (con colchón)                   |
//+------------------------------------------------------------------+
bool HayMargenSuficiente(double lote, double precio)
  {
   double margen_requerido = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lote, precio, margen_requerido))
     { Print("ERROR: OrderCalcMargin falló. Código: ", GetLastError()); return(false); }

   double margen_libre = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margen_libre < margen_requerido * InpFactorMargenLibre)
     {
      PrintFormat("Entrada descartada: margen libre insuficiente. Libre: %.2f | Requerido x%.1f: %.2f",
                  margen_libre, InpFactorMargenLibre, margen_requerido * InpFactorMargenLibre);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Cuenta posiciones propias (mismo símbolo y Magic)                |
//+------------------------------------------------------------------+
int ContarPosicionesPropias()
  {
   int contador = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         contador++;
     }
   return(contador);
  }

//+------------------------------------------------------------------+
//| Cierre de una posición con reintentos                            |
//+------------------------------------------------------------------+
void CerrarPosicion(ulong ticket, string motivo)
  {
   for(int intento = 1; intento <= 3; intento++)
     {
      if(g_trade.PositionClose(ticket))
        {
         uint retcode = g_trade.ResultRetcode();
         if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL)
           { PrintFormat("Posición %I64u cerrada. Motivo: %s", ticket, motivo); return; }
        }
      PrintFormat("Intento %d/3 de cierre del ticket %I64u fallido. Retcode %u: %s",
                  intento, ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      Sleep(300);
     }
   PrintFormat("ERROR CRÍTICO: no se pudo cerrar la posición %I64u tras 3 intentos. REVISAR MANUALMENTE.", ticket);
  }

//+------------------------------------------------------------------+
//| Panel de estado                                                 |
//+------------------------------------------------------------------+
void ActualizarPanel(const MqlTick &tick)
  {
   double spread_pts = (tick.ask - tick.bid) / _Point;
   double rsi_actual = (ArraySize(g_rsi) > 0) ? g_rsi[0] : 0.0;
   double cierre_1   = iClose(_Symbol, PERIOD_CURRENT, 1);
   double ma_tend    = (ArraySize(g_ma_tend) > 0) ? g_ma_tend[0] : 0.0;
   bool   tendencia  = (ma_tend > 0.0 && cierre_1 > ma_tend);

   string estado;
   if(ContarPosicionesPropias() > 0)
      estado = "EN POSICIÓN (esperando reversión / stop)";
   else if(!tendencia)
      estado = "EN ESPERA (precio bajo la MA200: sin tendencia alcista)";
   else if(rsi_actual >= InpRSIEntrada)
      estado = "EN ESPERA (sin sobreventa: RSI por encima del umbral)";
   else
      estado = "SEÑAL ACTIVA (sobreventa en tendencia alcista)";

   Comment(
      "═══════ NASDAQ MEAN REVERSION (RSI-2) ═══════\n",
      "Estado............: ", estado, "\n",
      "Timeframe.........: ", EnumToString((ENUM_TIMEFRAMES)Period()), (Period() == PERIOD_D1 ? " (correcto)" : " (¡usar D1!)"), "\n",
      "Tendencia (MA200).: ", (tendencia ? "ALCISTA (operable)" : "no alcista"), "\n",
      "RSI(", InpRSIPeriodo, ") vela [1]...: ", DoubleToString(rsi_actual, 1), " (entra <", DoubleToString(InpRSIEntrada, 0), ", sale >", DoubleToString(InpRSISalida, 0), ")\n",
      "ATR(", InpPeriodoATR, ").........: ", DoubleToString(g_atr_actual, _Digits), "\n",
      "Spread actual.....: ", DoubleToString(spread_pts, 0), " pts (máx: ", InpSpreadMaximo, ")\n",
      "Riesgo/operación..: ", DoubleToString(InpRiesgoPorOperacion, 1), "% de la Equity\n",
      "Equity............: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), "\n",
      "Posiciones EA.....: ", ContarPosicionesPropias(), " / 1\n",
      "═════════════════════════════════════════════"
     );
  }

//+------------------------------------------------------------------+
//| OnTester: criterio personalizado de optimización ("Custom max")  |
//| Métrica = (Beneficio neto / Drawdown máximo) * sqrt(nº trades),  |
//| descartando combinaciones con menos de 30 trades (en Diario hay  |
//| menos operaciones que en intradía, por eso el umbral baja a 30). |
//+------------------------------------------------------------------+
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES);
   if(trades < 30.0)
      return(0.0);
   double neto = TesterStatistics(STAT_PROFIT);
   double dd   = TesterStatistics(STAT_BALANCE_DD);
   if(dd < 1.0)
      dd = 1.0;
   return(neto / dd * MathSqrt(trades));
  }
//+------------------------------------------------------------------+
