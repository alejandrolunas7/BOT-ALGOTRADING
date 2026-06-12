//+------------------------------------------------------------------+
//|                                       NasdaqMomentumPullback.mq5 |
//|                          Estrategia: "Nasdaq Momentum Pullback"  |
//|                                                                  |
//|  LÓGICA GENERAL (evaluada SIEMPRE al cierre de vela M15):        |
//|   - Filtro de tendencia ......: EMA 200 (cierre vs media)        |
//|   - Filtro de pullback .......: línea principal del MACD          |
//|                                 (negativa para LONG, positiva    |
//|                                  para SHORT)                     |
//|   - Gatillo ..................: cruce MACD línea/señal en la     |
//|                                 última vela cerrada              |
//|   - SL dinámico ..............: 1.5 x ATR(14)                    |
//|   - TP dinámico ..............: 3.0 x ATR(14)  (ratio 1:2)       |
//|   - Lotaje ...................: % de riesgo sobre la Equity      |
//|   - Breakeven ................: al alcanzar +1R                  |
//|   - Trailing Stop ............: desde +1.5R, distancia por ATR   |
//|   - Invalidación técnica .....: cruce contrario del MACD          |
//|   - Cierre forzado diario ....: sin exposición nocturna          |
//|   - Kill Switch ..............: pérdida diaria máxima (3%)       |
//|   - Máx. operaciones/día .....: 4                                |
//|                                                                  |
//|  IMPORTANTE SOBRE HORARIOS:                                      |
//|  MetaTrader 5 trabaja con la HORA DEL SERVIDOR del broker, NO    |
//|  con la hora local (CET). La mayoría de brokers usan GMT+2 en    |
//|  invierno y GMT+3 en verano. Con un broker GMT+3 (verano):       |
//|     16:00 CET (CEST) = 17:00 hora servidor                       |
//|     22:00 CET (CEST) = 23:00 hora servidor                       |
//|     22:45 CET (CEST) = 23:45 hora servidor                       |
//|  Los valores por defecto de los inputs asumen ese caso. Ajusta   |
//|  los inputs de horario según el GMT offset de TU broker.         |
//+------------------------------------------------------------------+
#property copyright "BOT-ALGOTRADING"
#property version   "1.00"
#property strict
#property description "EA de seguimiento de tendencia con pullback (EMA200 + MACD + ATR) para NASDAQ en M15."

//--- Librería estándar de trading de MetaQuotes (envoltorio de OrderSend)
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| PARÁMETROS DE ENTRADA (todos optimizables en el Strategy Tester) |
//+------------------------------------------------------------------+
input group "=== 1. IDENTIFICACIÓN ==="
input long     InpMagicNumber        = 20260611;   // Magic Number (identificador único del EA)
input string   InpComentarioOrden    = "NQ-MomPullback"; // Comentario de las órdenes

input group "=== 2. INDICADORES ==="
input int      InpPeriodoEMA         = 200;        // Periodo de la EMA de tendencia
input int      InpMACD_Rapida        = 12;         // MACD: EMA rápida
input int      InpMACD_Lenta         = 26;         // MACD: EMA lenta
input int      InpMACD_Senal         = 9;          // MACD: SMA de la señal
input int      InpPeriodoATR         = 14;         // Periodo del ATR
input int      InpPendienteEMABarras = 20;         // Filtro de pendiente: EMA debe subir/bajar vs hace N velas (0 = off)

input group "=== 2b. GESTIÓN DE LA SALIDA POR INVALIDACIÓN ==="
input int      InpModoInvalidacion   = 1;          // Cruce MACD contrario: 0=cierra siempre, 1=solo si hay pérdida, 2=nunca

input group "=== 3. GESTIÓN DE RIESGO ==="
input double   InpRiesgoPorOperacion = 1.0;        // Riesgo por operación (% de la Equity)
input double   InpMultiplicadorSL    = 1.5;        // SL = ATR x este multiplicador
input double   InpMultiplicadorTP    = 3.0;        // TP = ATR x este multiplicador (1:2)
input double   InpPerdidaDiariaMax   = 3.0;        // Kill Switch: pérdida diaria máxima (% del balance)
input int      InpMaxOperacionesDia  = 4;          // Máximo de operaciones por día
input int      InpATRMinimoPuntos    = 500;        // ATR mínimo en puntos para operar (filtro de mercado muerto)
input int      InpATRMaximoPuntos    = 0;          // ATR máximo en puntos para operar (0 = sin límite)
input double   InpLoteMaximo         = 5.0;        // Lote máximo absoluto (techo de seguridad)

input group "=== 4. BREAKEVEN Y TRAILING STOP ==="
input bool     InpUsarBreakeven      = true;       // Activar Breakeven
input double   InpBreakevenR         = 1.0;        // Activar BE al alcanzar +X R (múltiplos del riesgo)
input int      InpBreakevenMargen    = 10;         // Margen del BE en puntos (cubre comisiones)
input bool     InpUsarTrailing       = true;       // Activar Trailing Stop
input double   InpTrailingActivacionR= 1.5;        // Activar Trailing al alcanzar +X R
input double   InpTrailingATRMult    = 1.0;        // Distancia del Trailing = ATR x este multiplicador
input int      InpTrailingPasoMin    = 20;         // Paso mínimo en puntos para mover el SL (evita spam al servidor)

input group "=== 5. HORARIO (¡HORA DEL SERVIDOR DEL BROKER!) ==="
input int      InpHoraInicio         = 17;         // Hora de inicio de entradas (servidor)
input int      InpMinutoInicio       = 0;          // Minuto de inicio de entradas
input int      InpHoraFin            = 23;         // Hora de fin de entradas (servidor)
input int      InpMinutoFin          = 0;          // Minuto de fin de entradas
input int      InpHoraCierreForzado  = 23;         // Hora del cierre forzado diario (servidor)
input int      InpMinutoCierreForzado= 45;         // Minuto del cierre forzado diario
input int      InpMinutosSinEntradas = 45;         // Bloquear entradas X minutos antes del cierre forzado
input int      InpMargenFinSesion    = 15;         // Cerrar X minutos antes del fin de sesión del símbolo

input group "=== 6. FILTROS DE SEGURIDAD ==="
input int      InpSpreadMaximo       = 200;        // Spread máximo permitido (en puntos)
input int      InpSlippageMaximo     = 30;         // Desviación/Slippage máximo (en puntos)
input double   InpFactorMargenLibre  = 1.5;        // Margen libre requerido (x veces el margen de la orden)

input group "=== 7. INTERFAZ ==="
input bool     InpMostrarPanel       = true;       // Mostrar panel de estado en el gráfico

//+------------------------------------------------------------------+
//| VARIABLES GLOBALES                                               |
//+------------------------------------------------------------------+
CTrade   g_trade;                  // Objeto de trading de la librería estándar
int      g_handle_ema    = INVALID_HANDLE;  // Handle del indicador EMA 200
int      g_handle_macd   = INVALID_HANDLE;  // Handle del indicador MACD
int      g_handle_atr    = INVALID_HANDLE;  // Handle del indicador ATR

datetime g_ultima_vela   = 0;      // Hora de apertura de la última vela procesada (detector de vela nueva)
double   g_atr_actual    = 0.0;    // ATR de la última vela cerrada (cacheado, se usa en el trailing)
double   g_riesgo_inicial_pts = 0.0; // Distancia del SL inicial en PUNTOS (define "1R" de la posición abierta)
bool     g_killswitch_activo  = false; // true = pérdida diaria superada, no se opera más hoy
datetime g_dia_killswitch     = 0;     // Día en el que se activó el Kill Switch

//--- Buffers de indicadores (índice 0 = vela [1], índice 1 = vela [2])
double   g_ema[];                  // EMA 200
double   g_macd_main[];            // MACD línea principal
double   g_macd_signal[];          // MACD línea de señal
double   g_atr[];                  // ATR

//+------------------------------------------------------------------+
//| OnInit: inicialización del EA                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- 1. Validación de parámetros de entrada (evita configuraciones absurdas)
   if(InpRiesgoPorOperacion <= 0.0 || InpRiesgoPorOperacion > 10.0)
     {
      Print("ERROR de configuración: el riesgo por operación debe estar entre 0.1% y 10%.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpMultiplicadorSL <= 0.0 || InpMultiplicadorTP <= 0.0)
     {
      Print("ERROR de configuración: los multiplicadores de ATR deben ser positivos.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpMACD_Rapida >= InpMACD_Lenta)
     {
      Print("ERROR de configuración: la EMA rápida del MACD debe ser menor que la lenta.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpMaxOperacionesDia <= 0 || InpPerdidaDiariaMax <= 0.0)
     {
      Print("ERROR de configuración: límites diarios inválidos.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- 2. Creación de los handles de los indicadores
   //    En MQL5 los indicadores se calculan en el terminal y se leen con CopyBuffer.
   g_handle_ema  = iMA(_Symbol, PERIOD_CURRENT, InpPeriodoEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_handle_macd = iMACD(_Symbol, PERIOD_CURRENT, InpMACD_Rapida, InpMACD_Lenta, InpMACD_Senal, PRICE_CLOSE);
   g_handle_atr  = iATR(_Symbol, PERIOD_CURRENT, InpPeriodoATR);

   if(g_handle_ema == INVALID_HANDLE || g_handle_macd == INVALID_HANDLE || g_handle_atr == INVALID_HANDLE)
     {
      Print("ERROR: no se pudieron crear los indicadores. Código: ", GetLastError());
      return(INIT_FAILED);
     }

   //--- 3. Configuración de los buffers como series temporales
   //    (índice 0 = el dato más reciente solicitado)
   ArraySetAsSeries(g_ema, true);
   ArraySetAsSeries(g_macd_main, true);
   ArraySetAsSeries(g_macd_signal, true);
   ArraySetAsSeries(g_atr, true);

   //--- 4. Configuración del objeto de trading
   g_trade.SetExpertMagicNumber(InpMagicNumber);          // El EA solo gestionará SUS órdenes
   g_trade.SetDeviationInPoints(InpSlippageMaximo);       // Control de slippage
   g_trade.SetAsyncMode(false);                           // Modo síncrono: esperamos la respuesta del servidor

   //--- 5. Detección automática del modo de ejecución (filling) soportado por el broker
   //    Evita el error TRADE_RETCODE_INVALID_FILL al cambiar de broker.
   long modos_filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((modos_filling & SYMBOL_FILLING_FOK) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((modos_filling & SYMBOL_FILLING_IOC) != 0)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);

   //--- 6. Recuperación del estado si el EA se reinicia con una posición abierta
   //    (corte de luz, recompilación, reinicio del VPS...)
   RecuperarRiesgoInicial();

   Print("NasdaqMomentumPullback iniciado en ", _Symbol,
         " | Dígitos del broker: ", _Digits,
         " | Punto: ", DoubleToString(_Point, _Digits),
         " | Modo de cuenta: ", (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING ? "HEDGING" : "NETTING"));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit: limpieza al retirar el EA                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- Liberamos los handles de los indicadores para no dejar basura en memoria
   if(g_handle_ema  != INVALID_HANDLE) IndicatorRelease(g_handle_ema);
   if(g_handle_macd != INVALID_HANDLE) IndicatorRelease(g_handle_macd);
   if(g_handle_atr  != INVALID_HANDLE) IndicatorRelease(g_handle_atr);

   //--- Limpiamos el panel de comentarios del gráfico
   Comment("");
  }

//+------------------------------------------------------------------+
//| OnTick: motor principal del EA                                   |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- 0. Obtención del tick actual. Si falla, no operamos en este tick.
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   //--- 1. Panel de estado (se refresca en cada tick, coste despreciable)
   if(InpMostrarPanel)
      ActualizarPanel(tick);

   //--- 1b. RED DE SEGURIDAD: si una posición sobrevivió a un día anterior
   //    (ej. el mercado cerró antes de la hora del cierre forzado y no hubo
   //    ticks para ejecutarlo), la cerramos en el PRIMER tick disponible.
   //    Garantiza el principio de "cero exposición nocturna" incluso en
   //    símbolos con sesión corta (acciones, índices con pausas).
   CerrarPosicionesDeDiasAnteriores();

   //--- 2. Gestión de la posición abierta (Breakeven y Trailing).
   //    Se ejecuta TICK A TICK porque proteger beneficios no admite esperas,
   //    pero las DECISIONES de entrada/salida por indicador van al cierre de vela.
   GestionarPosicionAbierta(tick);

   //--- 3. Cierre forzado diario: cero exposición nocturna.
   //    Se comprueba en cada tick para reaccionar al minuto exacto.
   if(EsHoraDeCierreForzado())
     {
      CerrarTodasLasPosiciones("Cierre forzado diario (fin de sesión)");
      return; // Tras la hora de cierre no se evalúa nada más
     }

   //--- 4. A partir de aquí, TODO se evalúa una sola vez por vela cerrada (M15).
   //    Esto elimina el ruido intradiario y las señales falsas tick a tick.
   if(!EsVelaNueva())
      return;

   //--- 5. Lectura de los indicadores sobre las velas CERRADAS [1] y [2]
   if(!CopiarIndicadores())
      return; // Si los datos no están listos (ej. inicio del terminal), esperamos a la siguiente vela

   //--- 6. Invalidación técnica: si el MACD cruza en contra de la posición
   //    abierta, cerramos a mercado SIN esperar al SL. La tesis ha muerto.
   GestionarInvalidacionTecnica();

   //--- 7. Filtros de protección diaria (Kill Switch y máximo de operaciones)
   if(!FiltrosDiariosOK())
      return;

   //--- 8. Filtro de horario: solo buscamos entradas dentro de la ventana operativa
   if(!EsHorarioOperativo())
      return;

   //--- 9. Filtro de exposición: una (1) sola posición a la vez.
   //    Nota: si la invalidación del paso 6 acaba de cerrar una posición,
   //    aquí el contador ya es 0 y se permite evaluar la señal contraria
   //    en esta misma vela (comportamiento deseado: stop & reverse implícito).
   if(ContarPosicionesPropias() > 0)
      return;

   //--- 10. Filtro de spread: si el broker abre el spread (noticias), no entramos
   double spread_puntos = (tick.ask - tick.bid) / _Point;
   if(spread_puntos > InpSpreadMaximo)
     {
      Print("Entrada descartada: spread actual (", DoubleToString(spread_puntos, 0),
            " pts) > máximo permitido (", InpSpreadMaximo, " pts).");
      return;
     }

   //--- 10b. Filtro de VOLATILIDAD MÍNIMA. Lección del backtest: en sesiones
   //    muertas (festivos, medias sesiones como Acción de Gracias) el ATR se
   //    desploma => el SL queda ridículamente cerca => el lotaje dinámico
   //    calcula un lote gigantesco para "arriesgar el 1%". Un gap posterior
   //    se salta ese SL minúsculo y la pérdida real se multiplica. Si el
   //    mercado no se mueve, NO se opera.
   if(g_atr_actual < InpATRMinimoPuntos * _Point)
     {
      Print("Entrada descartada: ATR actual (", DoubleToString(g_atr_actual / _Point, 0),
            " pts) < mínimo exigido (", InpATRMinimoPuntos, " pts). Mercado sin volatilidad.");
      return;
     }

   //--- 10c. Filtro de VOLATILIDAD MÁXIMA (opcional, 0 = desactivado).
   //    El backtest mostró que en regímenes de volatilidad extrema (2025)
   //    el precio rara vez recorre 3xATR sin un cruce contrario del MACD:
   //    la estrategia pierde su motor de beneficios. Este techo permite
   //    excluir esos regímenes (valor optimizable en el Strategy Tester).
   if(InpATRMaximoPuntos > 0 && g_atr_actual > InpATRMaximoPuntos * _Point)
     {
      Print("Entrada descartada: ATR actual (", DoubleToString(g_atr_actual / _Point, 0),
            " pts) > máximo permitido (", InpATRMaximoPuntos, " pts). Volatilidad extrema.");
      return;
     }

   //--- 11. Evaluación de los triggers de entrada
   if(HaySenalDeCompra())
      AbrirOperacion(ORDER_TYPE_BUY, tick);
   else if(HaySenalDeVenta())
      AbrirOperacion(ORDER_TYPE_SELL, tick);
  }

//+------------------------------------------------------------------+
//| Detecta la apertura de una vela nueva en el timeframe del gráfico|
//+------------------------------------------------------------------+
bool EsVelaNueva()
  {
   datetime apertura_actual = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(apertura_actual == g_ultima_vela)
      return(false);              // Seguimos dentro de la misma vela
   g_ultima_vela = apertura_actual;
   return(true);                  // Acaba de abrir una vela nueva => la [1] ya está cerrada
  }

//+------------------------------------------------------------------+
//| Copia los valores de los indicadores de las velas [1] y [2]      |
//| Devuelve false si el terminal aún no tiene los datos calculados. |
//+------------------------------------------------------------------+
bool CopiarIndicadores()
  {
   //--- Pedimos 2 valores empezando en la vela [1] (la última CERRADA).
   //    Tras ArraySetAsSeries: buffer[0] = vela [1], buffer[1] = vela [2].
   //    Para la EMA pedimos además profundidad extra si el filtro de
   //    pendiente está activo: g_ema[N] = valor de la EMA hace N velas.
   int profundidad_ema = MathMax(2, InpPendienteEMABarras + 1);
   if(CopyBuffer(g_handle_ema, 0, 1, profundidad_ema, g_ema) < profundidad_ema)
     { Print("Aviso: EMA sin datos suficientes todavía."); return(false); }

   if(CopyBuffer(g_handle_macd, 0, 1, 2, g_macd_main) < 2)     // Buffer 0 = línea principal
     { Print("Aviso: MACD (principal) sin datos suficientes."); return(false); }

   if(CopyBuffer(g_handle_macd, 1, 1, 2, g_macd_signal) < 2)   // Buffer 1 = línea de señal
     { Print("Aviso: MACD (señal) sin datos suficientes."); return(false); }

   if(CopyBuffer(g_handle_atr, 0, 1, 2, g_atr) < 2)
     { Print("Aviso: ATR sin datos suficientes."); return(false); }

   //--- Cacheamos el ATR de la última vela cerrada para el Trailing Stop
   g_atr_actual = g_atr[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| TRIGGER DE COMPRA (todas las condiciones sobre velas cerradas)   |
//+------------------------------------------------------------------+
bool HaySenalDeCompra()
  {
   double cierre_1 = iClose(_Symbol, PERIOD_CURRENT, 1);   // Cierre de la última vela cerrada

   //--- 1. Filtro de tendencia: el precio cerró POR ENCIMA de la EMA 200
   bool tendencia_alcista = (cierre_1 > g_ema[0]);

   //--- 1b. Filtro de CALIDAD de tendencia: la EMA 200 debe estar SUBIENDO
   //    respecto a hace N velas. Lección del backtest 2025: en mercados
   //    laterales volátiles el precio cruza la EMA constantemente y el
   //    filtro de posición (precio vs EMA) da señales falsas; exigir
   //    pendiente positiva descarta las entradas en rango.
   if(InpPendienteEMABarras > 0)
      tendencia_alcista = tendencia_alcista && (g_ema[0] > g_ema[InpPendienteEMABarras]);

   //--- 2. Filtro de pullback: el MACD principal está en territorio NEGATIVO
   //    (confirma que venimos de un retroceso dentro de la tendencia alcista)
   bool pullback_confirmado = (g_macd_main[0] < 0.0);

   //--- 3. Gatillo: cruce ALCISTA de la línea principal sobre la señal
   //    En la vela [2] estaba por debajo o igual; en la vela [1] cruzó hacia arriba.
   bool cruce_alcista = (g_macd_main[1] <= g_macd_signal[1] && g_macd_main[0] > g_macd_signal[0]);

   return(tendencia_alcista && pullback_confirmado && cruce_alcista);
  }

//+------------------------------------------------------------------+
//| TRIGGER DE VENTA (espejo exacto del de compra)                   |
//+------------------------------------------------------------------+
bool HaySenalDeVenta()
  {
   double cierre_1 = iClose(_Symbol, PERIOD_CURRENT, 1);

   //--- 1. Filtro de tendencia: el precio cerró POR DEBAJO de la EMA 200
   bool tendencia_bajista = (cierre_1 < g_ema[0]);

   //--- 1b. Filtro de CALIDAD de tendencia: la EMA 200 debe estar BAJANDO
   //    respecto a hace N velas (espejo del filtro de compra).
   if(InpPendienteEMABarras > 0)
      tendencia_bajista = tendencia_bajista && (g_ema[0] < g_ema[InpPendienteEMABarras]);

   //--- 2. Filtro de pullback: el MACD principal está en territorio POSITIVO
   //    (confirma el rebote alcista dentro de la tendencia bajista)
   bool pullback_confirmado = (g_macd_main[0] > 0.0);

   //--- 3. Gatillo: cruce BAJISTA de la línea principal bajo la señal
   bool cruce_bajista = (g_macd_main[1] >= g_macd_signal[1] && g_macd_main[0] < g_macd_signal[0]);

   return(tendencia_bajista && pullback_confirmado && cruce_bajista);
  }

//+------------------------------------------------------------------+
//| Apertura de una operación con SL/TP dinámicos por ATR            |
//+------------------------------------------------------------------+
void AbrirOperacion(ENUM_ORDER_TYPE tipo, const MqlTick &tick)
  {
   //--- 1. Distancias de SL y TP en PRECIO, derivadas del ATR de la vela [1].
   //    El ATR ya viene en unidades de precio, por lo que solo hay que
   //    normalizar el resultado final a los dígitos del broker (_Digits).
   double distancia_sl = g_atr_actual * InpMultiplicadorSL;
   double distancia_tp = g_atr_actual * InpMultiplicadorTP;

   if(distancia_sl <= 0.0)
     {
      Print("ERROR: ATR no válido (", DoubleToString(g_atr_actual, _Digits), "). Operación abortada.");
      return;
     }

   //--- 2. Comprobación de la distancia mínima de stops exigida por el broker
   //    (SYMBOL_TRADE_STOPS_LEVEL). Si nuestro SL queda más cerca de lo que
   //    el broker permite, abortamos en lugar de deformar el riesgo.
   double stops_minimos = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(distancia_sl < stops_minimos || distancia_tp < stops_minimos)
     {
      Print("Entrada descartada: la distancia ATR (", DoubleToString(distancia_sl / _Point, 0),
            " pts) es menor que el mínimo del broker (", DoubleToString(stops_minimos / _Point, 0), " pts).");
      return;
     }

   //--- 3. Precios de entrada, SL y TP según la dirección
   double precio_entrada, sl, tp;
   if(tipo == ORDER_TYPE_BUY)
     {
      precio_entrada = tick.ask;                                       // Compramos al Ask
      sl = NormalizeDouble(precio_entrada - distancia_sl, _Digits);
      tp = NormalizeDouble(precio_entrada + distancia_tp, _Digits);
     }
   else
     {
      precio_entrada = tick.bid;                                       // Vendemos al Bid
      sl = NormalizeDouble(precio_entrada + distancia_sl, _Digits);
      tp = NormalizeDouble(precio_entrada - distancia_tp, _Digits);
     }

   //--- 4. Cálculo del lotaje dinámico: riesgo exacto del X% de la Equity
   double sl_puntos = distancia_sl / _Point;
   double lote = CalcularLote(sl_puntos);
   if(lote <= 0.0)
      return; // El cálculo ya habrá impreso el motivo del fallo

   //--- 5. Filtro de margen libre: exigimos un colchón (ej. 150%) sobre el
   //    margen que requiere la orden, para evitar el rechazo "No money".
   if(!HayMargenSuficiente(tipo, lote, precio_entrada))
      return;

   //--- 6. Envío de la orden con reintentos ante requotes/cambios de precio.
   //    Máximo 3 intentos refrescando el precio en cada uno.
   string etiqueta = (tipo == ORDER_TYPE_BUY ? "COMPRA" : "VENTA");
   for(int intento = 1; intento <= 3; intento++)
     {
      bool enviado;
      if(tipo == ORDER_TYPE_BUY)
         enviado = g_trade.Buy(lote, _Symbol, 0.0, sl, tp, InpComentarioOrden);  // precio 0.0 = a mercado
      else
         enviado = g_trade.Sell(lote, _Symbol, 0.0, sl, tp, InpComentarioOrden);

      uint retcode = g_trade.ResultRetcode();

      //--- Éxito: la orden fue ejecutada por el servidor
      if(enviado && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
        {
         g_riesgo_inicial_pts = sl_puntos;  // Guardamos "1R" para el Breakeven/Trailing
         PrintFormat("%s ejecutada | Lote: %.2f | Precio: %s | SL: %s | TP: %s | ATR: %s | Retcode: %u",
                     etiqueta, lote,
                     DoubleToString(g_trade.ResultPrice(), _Digits),
                     DoubleToString(sl, _Digits), DoubleToString(tp, _Digits),
                     DoubleToString(g_atr_actual, _Digits), retcode);
         return;
        }

      //--- Errores RECUPERABLES: requote o precio cambiado => refrescamos y reintentamos
      if(retcode == TRADE_RETCODE_REQUOTE || retcode == TRADE_RETCODE_PRICE_CHANGED || retcode == TRADE_RETCODE_PRICE_OFF)
        {
         PrintFormat("Intento %d/3 de %s fallido (retcode %u: %s). Reintentando con precio nuevo...",
                     intento, etiqueta, retcode, g_trade.ResultRetcodeDescription());
         Sleep(200);                              // Pequeña pausa antes del reintento
         MqlTick tick_nuevo;
         if(!SymbolInfoTick(_Symbol, tick_nuevo))
            return;
         //--- Recalculamos SL/TP sobre el precio nuevo manteniendo las distancias ATR
         if(tipo == ORDER_TYPE_BUY)
           {
            sl = NormalizeDouble(tick_nuevo.ask - distancia_sl, _Digits);
            tp = NormalizeDouble(tick_nuevo.ask + distancia_tp, _Digits);
           }
         else
           {
            sl = NormalizeDouble(tick_nuevo.bid + distancia_sl, _Digits);
            tp = NormalizeDouble(tick_nuevo.bid - distancia_tp, _Digits);
           }
         continue;
        }

      //--- Error NO recuperable (sin dinero, mercado cerrado, volumen inválido...)
      PrintFormat("ERROR al abrir %s. Retcode %u: %s. Operación abortada.",
                  etiqueta, retcode, g_trade.ResultRetcodeDescription());
      return;
     }

   Print("ERROR: agotados los 3 reintentos por requotes. Señal descartada (no se persigue al precio).");
  }

//+------------------------------------------------------------------+
//| Cálculo del lotaje dinámico (riesgo % de la Equity / distancia SL)|
//+------------------------------------------------------------------+
double CalcularLote(double sl_puntos)
  {
   //--- 1. Dinero que estamos dispuestos a perder en esta operación
   double equity        = AccountInfoDouble(ACCOUNT_EQUITY);
   double riesgo_dinero = equity * InpRiesgoPorOperacion / 100.0;

   //--- 2. Valor monetario de UN PUNTO por UN LOTE en la divisa de la cuenta.
   //    Usamos tick_value/tick_size para que funcione en cualquier broker
   //    independientemente de cómo cotice el índice (2 decimales, 1, etc.).
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_value <= 0.0 || tick_size <= 0.0 || sl_puntos <= 0.0)
     {
      Print("ERROR: datos del símbolo inválidos para calcular el lote (tick_value/tick_size).");
      return(0.0);
     }
   double valor_punto_por_lote = tick_value * (_Point / tick_size);

   //--- 3. Lote bruto = dinero a arriesgar / (puntos de SL * valor del punto)
   double lote = riesgo_dinero / (sl_puntos * valor_punto_por_lote);

   //--- 4. Normalización a las restricciones del broker (mín, máx y paso)
   double lote_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lote_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lote_paso = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lote = MathFloor(lote / lote_paso) * lote_paso;   // Redondeo HACIA ABAJO (nunca arriesgar de más)

   if(lote < lote_min)
     {
      //--- La cuenta es demasiado pequeña para respetar el riesgo definido.
      //    Usamos el lote mínimo pero AVISAMOS de que el riesgo real será mayor.
      double riesgo_real_pct = (lote_min * sl_puntos * valor_punto_por_lote) / equity * 100.0;
      PrintFormat("AVISO: el lote calculado (%.4f) es inferior al mínimo del broker (%.2f). "
                  "Se usará el mínimo => riesgo real ~%.2f%% (configurado: %.2f%%).",
                  lote, lote_min, riesgo_real_pct, InpRiesgoPorOperacion);
      lote = lote_min;
     }
   if(lote > lote_max)
      lote = lote_max;

   //--- 5. TECHO ABSOLUTO de lote (backstop de seguridad). Aunque el filtro
   //    de ATR mínimo ya evita los lotes desproporcionados, este límite
   //    garantiza que NINGÚN escenario (error de datos del broker, ATR
   //    corrupto...) produzca una posición capaz de quemar la cuenta.
   if(lote > InpLoteMaximo)
     {
      PrintFormat("AVISO: lote calculado (%.2f) supera el techo de seguridad (%.2f). Se recorta al techo.",
                  lote, InpLoteMaximo);
      lote = InpLoteMaximo;
     }

   return(NormalizeDouble(lote, 2));
  }

//+------------------------------------------------------------------+
//| Verifica que hay margen libre suficiente (con colchón) para abrir|
//+------------------------------------------------------------------+
bool HayMargenSuficiente(ENUM_ORDER_TYPE tipo, double lote, double precio)
  {
   double margen_requerido = 0.0;
   if(!OrderCalcMargin(tipo, _Symbol, lote, precio, margen_requerido))
     {
      Print("ERROR: OrderCalcMargin falló. Código: ", GetLastError());
      return(false);
     }

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
//| Cuenta las posiciones abiertas que pertenecen a ESTE EA          |
//| (mismo símbolo y mismo Magic Number)                             |
//+------------------------------------------------------------------+
int ContarPosicionesPropias()
  {
   int contador = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);    // Selecciona la posición y devuelve su ticket
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         contador++;
     }
   return(contador);
  }

//+------------------------------------------------------------------+
//| Invalidación técnica: cierre a mercado si el MACD cruza en contra|
//| Se evalúa SOLO al cierre de vela (los buffers ya están copiados).|
//+------------------------------------------------------------------+
void GestionarInvalidacionTecnica()
  {
   //--- Modo 2 = invalidación desactivada (solo gestionan SL/TP/trailing)
   if(InpModoInvalidacion == 2)
      return;

   //--- Cruces detectados en la última vela cerrada
   bool cruce_bajista = (g_macd_main[1] >= g_macd_signal[1] && g_macd_main[0] < g_macd_signal[0]);
   bool cruce_alcista = (g_macd_main[1] <= g_macd_signal[1] && g_macd_main[0] > g_macd_signal[0]);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long tipo = PositionGetInteger(POSITION_TYPE);

      //--- ¿Hay cruce contrario a nuestra posición?
      bool cruce_contrario = (tipo == POSITION_TYPE_BUY  && cruce_bajista) ||
                             (tipo == POSITION_TYPE_SELL && cruce_alcista);
      if(!cruce_contrario)
         continue;

      //--- Modo 1 (recomendado): solo cerramos si la posición está EN PÉRDIDA.
      //    Lección del backtest 2025: cerrar también las posiciones en
      //    beneficio amputaba sistemáticamente la cola derecha (los +2R del
      //    TP casi desaparecieron). Si la operación va ganando, el cruce se
      //    ignora y dejan trabajar el Breakeven/Trailing, que ya protegen.
      if(InpModoInvalidacion == 1 && PositionGetDouble(POSITION_PROFIT) > 0.0)
         continue;

      CerrarPosicion(ticket, tipo == POSITION_TYPE_BUY
                             ? "Invalidación técnica: cruce bajista del MACD"
                             : "Invalidación técnica: cruce alcista del MACD");
     }
  }

//+------------------------------------------------------------------+
//| Gestión de la posición abierta: Breakeven y Trailing Stop        |
//| Se ejecuta tick a tick (la protección de beneficios no espera).  |
//+------------------------------------------------------------------+
void GestionarPosicionAbierta(const MqlTick &tick)
  {
   //--- Si todavía no conocemos el riesgo inicial (1R), no podemos gestionar
   if(g_riesgo_inicial_pts <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double precio_apertura = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl_actual       = PositionGetDouble(POSITION_SL);
      double tp_actual       = PositionGetDouble(POSITION_TP);
      long   tipo            = PositionGetInteger(POSITION_TYPE);

      //--- Beneficio actual en PUNTOS (medido contra el precio de cierre real:
      //    Bid para los largos, Ask para los cortos)
      double beneficio_pts;
      if(tipo == POSITION_TYPE_BUY)
         beneficio_pts = (tick.bid - precio_apertura) / _Point;
      else
         beneficio_pts = (precio_apertura - tick.ask) / _Point;

      //--- Umbrales en puntos derivados del riesgo inicial (1R)
      double umbral_be       = g_riesgo_inicial_pts * InpBreakevenR;
      double umbral_trailing = g_riesgo_inicial_pts * InpTrailingActivacionR;

      double nuevo_sl = sl_actual;

      //--- 1. TRAILING STOP (prioritario sobre el BE: si se cumple su umbral,
      //    el SL resultante será siempre igual o mejor que el del BE)
      if(InpUsarTrailing && beneficio_pts >= umbral_trailing && g_atr_actual > 0.0)
        {
         double distancia_trailing = g_atr_actual * InpTrailingATRMult;
         if(tipo == POSITION_TYPE_BUY)
           {
            double sl_propuesto = NormalizeDouble(tick.bid - distancia_trailing, _Digits);
            //--- Solo movemos el SL HACIA ARRIBA y con un paso mínimo (evita
            //    saturar el servidor con modificaciones de 1 punto)
            if(sl_propuesto > nuevo_sl + InpTrailingPasoMin * _Point)
               nuevo_sl = sl_propuesto;
           }
         else
           {
            double sl_propuesto = NormalizeDouble(tick.ask + distancia_trailing, _Digits);
            //--- Solo movemos el SL HACIA ABAJO
            if(nuevo_sl == 0.0 || sl_propuesto < nuevo_sl - InpTrailingPasoMin * _Point)
               nuevo_sl = sl_propuesto;
           }
        }
      //--- 2. BREAKEVEN (solo si el trailing aún no ha actuado)
      else if(InpUsarBreakeven && beneficio_pts >= umbral_be)
        {
         if(tipo == POSITION_TYPE_BUY)
           {
            double sl_be = NormalizeDouble(precio_apertura + InpBreakevenMargen * _Point, _Digits);
            if(sl_actual < sl_be)   // Solo si el SL todavía está por debajo de la entrada
               nuevo_sl = sl_be;
           }
         else
           {
            double sl_be = NormalizeDouble(precio_apertura - InpBreakevenMargen * _Point, _Digits);
            if(sl_actual > sl_be || sl_actual == 0.0)
               nuevo_sl = sl_be;
           }
        }

      //--- 3. Si hay un SL nuevo que aplicar, lo enviamos al servidor
      if(nuevo_sl != sl_actual)
        {
         //--- Respetamos la distancia mínima de stops del broker
         double stops_minimos = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
         double precio_ref    = (tipo == POSITION_TYPE_BUY ? tick.bid : tick.ask);
         if(MathAbs(precio_ref - nuevo_sl) < stops_minimos)
            continue; // Demasiado cerca: lo intentaremos en el siguiente tick

         if(!g_trade.PositionModify(ticket, nuevo_sl, tp_actual))
            PrintFormat("ERROR al modificar SL del ticket %I64u. Retcode %u: %s",
                        ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
         else
            PrintFormat("SL actualizado (ticket %I64u): %s -> %s | Beneficio actual: %.0f pts (%.2fR)",
                        ticket, DoubleToString(sl_actual, _Digits), DoubleToString(nuevo_sl, _Digits),
                        beneficio_pts, beneficio_pts / g_riesgo_inicial_pts);
        }
     }
  }

//+------------------------------------------------------------------+
//| Cierre de UNA posición con reintentos y verificación de retcode  |
//+------------------------------------------------------------------+
void CerrarPosicion(ulong ticket, string motivo)
  {
   for(int intento = 1; intento <= 3; intento++)
     {
      if(g_trade.PositionClose(ticket))
        {
         uint retcode = g_trade.ResultRetcode();
         if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL)
           {
            PrintFormat("Posición %I64u cerrada. Motivo: %s", ticket, motivo);
            return;
           }
        }
      PrintFormat("Intento %d/3 de cierre del ticket %I64u fallido. Retcode %u: %s",
                  intento, ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      Sleep(300);  // Pausa breve antes de reintentar (requotes/picos de volatilidad)
     }
   PrintFormat("ERROR CRÍTICO: no se pudo cerrar la posición %I64u tras 3 intentos. REVISAR MANUALMENTE.", ticket);
  }

//+------------------------------------------------------------------+
//| Cierra TODAS las posiciones de este EA (cierre forzado diario)   |
//+------------------------------------------------------------------+
void CerrarTodasLasPosiciones(string motivo)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         CerrarPosicion(ticket, motivo);
     }
  }

//+------------------------------------------------------------------+
//| Cierra las posiciones abiertas en un día ANTERIOR al actual.     |
//| Caso real detectado en backtest: entrada a las 22:45, mercado de |
//| acciones cerrado a las 23:00 => el cierre forzado de las 23:45   |
//| nunca se ejecutó (sin ticks no hay OnTick) y la posición pasó la |
//| noche abierta. Esta función la liquida al primer tick del día.   |
//+------------------------------------------------------------------+
void CerrarPosicionesDeDiasAnteriores()
  {
   datetime inicio_hoy = InicioDelDia();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      datetime hora_apertura = (datetime)PositionGetInteger(POSITION_TIME);
      if(hora_apertura < inicio_hoy)
         CerrarPosicion(ticket, "Cierre forzado retroactivo: posición heredada de un día anterior");
     }
  }

//+------------------------------------------------------------------+
//| Minuto del día en que TERMINA la última sesión de trading de hoy |
//| según el calendario del broker. Devuelve -1 si no hay sesión.    |
//+------------------------------------------------------------------+
int MinutoFinSesionHoy()
  {
   MqlDateTime ahora;
   TimeToStruct(TimeCurrent(), ahora);

   datetime desde, hasta;
   int fin = -1;
   //--- Recorremos todas las sesiones de trading del día de la semana actual
   //    y nos quedamos con la que termina más tarde.
   for(uint i = 0; SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)ahora.day_of_week, i, desde, hasta); i++)
     {
      //--- 'hasta' es un offset desde las 00:00 (86400 = medianoche del día siguiente)
      int minuto_fin = (hasta >= 86400) ? 24 * 60 : (int)(hasta / 60);
      if(minuto_fin > fin)
         fin = minuto_fin;
     }
   return(fin);
  }

//+------------------------------------------------------------------+
//| Minuto EFECTIVO del cierre forzado: el menor entre la hora       |
//| configurada y el fin de la sesión del símbolo menos un margen.   |
//| LECCIÓN DEL BACKTEST: si el cierre forzado se programa a una     |
//| hora en la que el mercado YA no cotiza (cierre normal o festivo),|
//| no llegan ticks, OnTick no se dispara y la posición pasa la      |
//| noche/fin de semana abierta. Anclarlo al calendario del broker   |
//| garantiza que cerramos mientras todavía hay mercado.             |
//+------------------------------------------------------------------+
int MinutoCierreEfectivo()
  {
   int minuto_cierre = InpHoraCierreForzado * 60 + InpMinutoCierreForzado;
   int fin_sesion    = MinutoFinSesionHoy();
   if(fin_sesion > 0 && fin_sesion - InpMargenFinSesion < minuto_cierre)
      minuto_cierre = fin_sesion - InpMargenFinSesion;
   return(minuto_cierre);
  }

//+------------------------------------------------------------------+
//| ¿Estamos en (o pasada) la hora del cierre forzado diario?        |
//+------------------------------------------------------------------+
bool EsHoraDeCierreForzado()
  {
   MqlDateTime ahora;
   TimeToStruct(TimeCurrent(), ahora);   // TimeCurrent() = hora del SERVIDOR del broker

   int minuto_actual = ahora.hour * 60 + ahora.min;

   return(minuto_actual >= MinutoCierreEfectivo());
  }

//+------------------------------------------------------------------+
//| ¿Estamos dentro de la ventana horaria de búsqueda de entradas?   |
//+------------------------------------------------------------------+
bool EsHorarioOperativo()
  {
   MqlDateTime ahora;
   TimeToStruct(TimeCurrent(), ahora);

   //--- No se opera en fin de semana (defensa extra; el mercado estará cerrado igualmente)
   if(ahora.day_of_week == SATURDAY || ahora.day_of_week == SUNDAY)
      return(false);

   int minuto_actual = ahora.hour * 60 + ahora.min;
   int minuto_inicio = InpHoraInicio * 60 + InpMinutoInicio;
   int minuto_fin    = InpHoraFin * 60 + InpMinutoFin;

   //--- Bloqueo previo al cierre forzado: no abrimos operaciones nuevas en los
   //    últimos X minutos de la sesión. Evita posiciones que nacen tan tarde
   //    que el mercado cierra antes de poder ejecutar el cierre forzado
   //    (sin ticks no hay OnTick => la posición quedaría abierta toda la noche).
   //    Se usa el cierre EFECTIVO (acotado por el fin de sesión del símbolo).
   if(minuto_actual >= MinutoCierreEfectivo() - InpMinutosSinEntradas)
      return(false);

   return(minuto_actual >= minuto_inicio && minuto_actual <= minuto_fin);
  }

//+------------------------------------------------------------------+
//| Devuelve la hora de inicio del día actual (00:00 hora servidor)  |
//+------------------------------------------------------------------+
datetime InicioDelDia()
  {
   return(StringToTime(TimeToString(TimeCurrent(), TIME_DATE)));
  }

//+------------------------------------------------------------------+
//| Cuenta las operaciones ABIERTAS hoy por este EA (desde historial)|
//| Basarse en el historial lo hace robusto ante reinicios del EA.   |
//+------------------------------------------------------------------+
int ContarOperacionesDeHoy()
  {
   int contador = 0;
   if(!HistorySelect(InicioDelDia(), TimeCurrent()))
      return(0);

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      //--- Solo contamos los deals de ENTRADA (aperturas de posición)
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         contador++;
     }
   //--- Sumamos también las posiciones aún abiertas (su deal de entrada ya
   //    está en el historial, así que NO se suman otra vez: el bucle anterior
   //    ya las incluye). Este comentario evita "arreglos" erróneos futuros.
   return(contador);
  }

//+------------------------------------------------------------------+
//| Pérdida/ganancia REALIZADA hoy por este EA (profit+swap+comisión)|
//+------------------------------------------------------------------+
double ResultadoRealizadoHoy()
  {
   double resultado = 0.0;
   if(!HistorySelect(InicioDelDia(), TimeCurrent()))
      return(0.0);

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
         continue;
      //--- Sumamos profit, swap y comisiones de los deals de SALIDA
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         resultado += HistoryDealGetDouble(deal, DEAL_PROFIT)
                    + HistoryDealGetDouble(deal, DEAL_SWAP)
                    + HistoryDealGetDouble(deal, DEAL_COMMISSION);
     }
   return(resultado);
  }

//+------------------------------------------------------------------+
//| Filtros de protección diaria: Kill Switch y máximo de operaciones|
//+------------------------------------------------------------------+
bool FiltrosDiariosOK()
  {
   datetime hoy = InicioDelDia();

   //--- Si el Kill Switch se activó OTRO día, lo reseteamos (día nuevo, cuenta nueva)
   if(g_killswitch_activo && g_dia_killswitch != hoy)
     {
      g_killswitch_activo = false;
      Print("Kill Switch reseteado: comienza un día nuevo de operativa.");
     }
   if(g_killswitch_activo)
      return(false);

   //--- 1. KILL SWITCH: pérdida realizada hoy vs balance al inicio del día.
   //    El balance inicial del día se reconstruye como:
   //    balance_actual - resultado_realizado_hoy  (robusto ante reinicios).
   double resultado_hoy   = ResultadoRealizadoHoy();
   double balance_inicial = AccountInfoDouble(ACCOUNT_BALANCE) - resultado_hoy;
   double limite_perdida  = balance_inicial * InpPerdidaDiariaMax / 100.0;

   if(resultado_hoy <= -limite_perdida)
     {
      g_killswitch_activo = true;
      g_dia_killswitch    = hoy;
      PrintFormat("KILL SWITCH ACTIVADO: pérdida diaria %.2f supera el límite %.2f (%.1f%% del balance inicial del día). "
                  "El EA no abrirá más operaciones hoy.", resultado_hoy, -limite_perdida, InpPerdidaDiariaMax);
      return(false);
     }

   //--- 2. MÁXIMO DE OPERACIONES POR DÍA
   if(ContarOperacionesDeHoy() >= InpMaxOperacionesDia)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Recupera el riesgo inicial (1R) si el EA arranca con posición    |
//| abierta (reinicio del terminal, recompilación, caída del VPS...) |
//+------------------------------------------------------------------+
void RecuperarRiesgoInicial()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double apertura = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl       = PositionGetDouble(POSITION_SL);
      long   tipo     = PositionGetInteger(POSITION_TYPE);

      //--- Caso normal: el SL original sigue por debajo (largo) / encima (corto)
      //    de la entrada => la distancia entrada-SL ES el riesgo inicial.
      bool sl_original = (tipo == POSITION_TYPE_BUY  && sl > 0.0 && sl < apertura) ||
                         (tipo == POSITION_TYPE_SELL && sl > apertura);
      if(sl_original)
        {
         g_riesgo_inicial_pts = MathAbs(apertura - sl) / _Point;
         PrintFormat("Posición %I64u recuperada tras reinicio. Riesgo inicial reconstruido: %.0f pts.",
                     ticket, g_riesgo_inicial_pts);
        }
      else
        {
         //--- El SL ya fue movido a BE/trailing: aproximamos 1R con el ATR actual.
         //    Es una aproximación conservadora y queda registrada en el log.
         double atr_tmp[];
         ArraySetAsSeries(atr_tmp, true);
         if(CopyBuffer(g_handle_atr, 0, 1, 1, atr_tmp) == 1 && atr_tmp[0] > 0.0)
           {
            g_riesgo_inicial_pts = atr_tmp[0] * InpMultiplicadorSL / _Point;
            PrintFormat("Posición %I64u recuperada con SL ya protegido. Riesgo 1R APROXIMADO por ATR: %.0f pts.",
                        ticket, g_riesgo_inicial_pts);
           }
        }
      return; // Solo gestionamos una posición a la vez
     }
  }

//+------------------------------------------------------------------+
//| Panel de estado en el gráfico (Comment)                          |
//+------------------------------------------------------------------+
void ActualizarPanel(const MqlTick &tick)
  {
   double spread_pts   = (tick.ask - tick.bid) / _Point;
   double resultado_hoy = ResultadoRealizadoHoy();
   int    ops_hoy       = ContarOperacionesDeHoy();

   string estado;
   if(g_killswitch_activo)
      estado = "DETENIDO (Kill Switch: pérdida diaria máxima alcanzada)";
   else if(EsHoraDeCierreForzado())
      estado = "FUERA DE SESIÓN (tras cierre forzado diario)";
   else if(!EsHorarioOperativo())
      estado = "EN ESPERA (fuera del horario de entradas)";
   else if(ContarPosicionesPropias() > 0)
      estado = "GESTIONANDO POSICIÓN ABIERTA";
   else
      estado = "BUSCANDO SEÑAL (al cierre de cada vela M15)";

   Comment(
      "═══════ NASDAQ MOMENTUM PULLBACK ═══════\n",
      "Estado............: ", estado, "\n",
      "Hora servidor.....: ", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), "\n",
      "Spread actual.....: ", DoubleToString(spread_pts, 0), " pts (máx: ", InpSpreadMaximo, ")\n",
      "ATR(", InpPeriodoATR, ") vela [1]..: ", DoubleToString(g_atr_actual, _Digits), "\n",
      "Riesgo/operación..: ", DoubleToString(InpRiesgoPorOperacion, 1), "% de la Equity\n",
      "Equity............: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), "\n",
      "Operaciones hoy...: ", ops_hoy, " / ", InpMaxOperacionesDia, "\n",
      "P/L realizado hoy.: ", DoubleToString(resultado_hoy, 2), "\n",
      "Posiciones EA.....: ", ContarPosicionesPropias(), " / 1\n",
      "════════════════════════════════════════"
     );
  }
//+------------------------------------------------------------------+
