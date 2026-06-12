# BOT-ALGOTRADING — Nasdaq Momentum Pullback (MQL5)

Expert Advisor para MetaTrader 5 que opera el **NASDAQ (NAS100 / USTEC / US100, según tu broker)** en **M15** con una estrategia de **seguimiento de tendencia con entrada en pullback**, durante la sesión de Nueva York.

> Archivo principal: [`MQL5/Experts/NasdaqMomentumPullback.mq5`](MQL5/Experts/NasdaqMomentumPullback.mq5)

---

## 1. Resumen de la estrategia

Todas las señales se evalúan **estrictamente al cierre de vela M15** (vela `[1]`), nunca tick a tick.

| Bloque | Regla |
|---|---|
| Filtro de tendencia | Cierre `[1]` por encima (LONG) / debajo (SHORT) de la **EMA 200** |
| Filtro de pullback | Línea principal del **MACD (12, 26, 9)** negativa (LONG) / positiva (SHORT) |
| Gatillo de entrada | Cruce de la línea principal del MACD sobre/bajo la señal en la vela `[1]` |
| Stop Loss | `1.5 × ATR(14)` desde el precio de entrada |
| Take Profit | `3.0 × ATR(14)` → ratio Riesgo/Beneficio **1:2** |
| Lotaje | Dinámico: **1% de la Equity** según la distancia exacta del SL |
| Breakeven | Al alcanzar **+1R**, SL a entrada + margen (cubre comisiones) |
| Trailing Stop | Desde **+1.5R**, persigue al precio a distancia `1.0 × ATR` |
| Invalidación técnica | Cruce contrario del MACD al cierre de vela → cierre a mercado inmediato |
| Cierre forzado diario | Cierra todo y bloquea entradas → **cero exposición nocturna** |
| Kill Switch | Pérdida realizada del día ≥ **3%** del balance → EA detenido hasta mañana |
| Límites | Máx. **1 posición** simultánea y **4 operaciones/día** |
| Filtros de seguridad | Spread máx. 200 pts, slippage máx. 30 pts, margen libre ≥ 150% del requerido |

**Esperanza matemática de referencia** (con R:R = 1:2, sin costes): el punto de equilibrio está en un winrate del **33,3%**. Cualquier winrate sostenido por encima (más el efecto del BE/trailing, que recorta la pérdida media) produce esperanza positiva. Valídalo en el Strategy Tester antes de pasar a real.

---

## 2. ⚠️ Horarios: hora del SERVIDOR, no hora española

MetaTrader 5 trabaja con la **hora del servidor de tu broker** (`TimeCurrent()`), no con CET. La mayoría de brokers usan **GMT+2 en invierno y GMT+3 en verano** (para que la vela diaria cierre con NY).

Los valores por defecto del EA asumen **broker GMT+3 con horario de verano europeo**:

| Concepto | Hora España (CET/CEST) | Default del EA (hora servidor GMT+3) |
|---|---|---|
| Inicio de entradas | 16:00 | **17:00** |
| Fin de entradas | 22:00 | **23:00** |
| Cierre forzado diario | 22:45 | **23:45** |

Además, `InpMinutosSinEntradas` (default 45) bloquea las entradas nuevas en los últimos X minutos antes del cierre forzado, y el EA liquida al primer tick del día cualquier posición heredada de un día anterior — red de seguridad para símbolos cuya sesión termina antes de la hora del cierre forzado (sin ticks, el cierre programado no puede ejecutarse).

**Comprueba el GMT offset de tu broker** (la hora del panel del EA muestra la hora del servidor) y ajusta los inputs de horario si difiere. Recuerda también que EE.UU. y Europa cambian al horario de verano en fechas distintas (≈2 semanas en marzo y 1 en octubre/noviembre): revisa los horarios en esos periodos.

---

## 3. Instalación

1. Abre MetaTrader 5 → `Archivo` → `Abrir carpeta de datos`.
2. Copia `MQL5/Experts/NasdaqMomentumPullback.mq5` en `MQL5/Experts/`.
3. Abre MetaEditor (F4), abre el archivo y pulsa **Compilar** (F7). Debe dar `0 errors, 0 warnings`.
4. En MT5, arrastra el EA a un gráfico del **NASDAQ en M15** y activa `AlgoTrading`.

## 4. Parámetros (inputs)

Todos los parámetros son `input` y por tanto **optimizables en el Strategy Tester**, agrupados por categorías:

- **Identificación**: Magic Number y comentario de órdenes.
- **Indicadores**: periodos de EMA, MACD y ATR.
- **Gestión de riesgo**: % de riesgo, multiplicadores de SL/TP, pérdida diaria máxima, máx. operaciones/día.
- **Breakeven y Trailing**: umbrales en R, margen del BE, multiplicador ATR del trailing y paso mínimo.
- **Horario**: inicio/fin de entradas y cierre forzado (hora servidor).
- **Filtros de seguridad**: spread máximo, slippage, factor de margen libre.
- **Interfaz**: panel de estado en el gráfico.

## 5. Detalles de implementación

- **Compatibilidad hedging/netting**: al operar 1 posición máxima con Magic Number propio, funciona en ambos tipos de cuenta.
- **Normalización automática**: usa `_Digits`, `_Point` y `tick_value/tick_size` del símbolo; funciona en cualquier broker sin tocar el código.
- **Gestión de errores del servidor**: verificación de retcodes, reintentos (máx. 3) ante requotes/cambio de precio con refresco del precio, y registro detallado en el log de Expertos.
- **Filling mode** detectado automáticamente (FOK / IOC / RETURN) para evitar rechazos al cambiar de broker.
- **Robustez ante reinicios**: el contador de operaciones diarias y el Kill Switch se reconstruyen desde el historial de deals; el riesgo inicial (1R) de una posición abierta se recupera desde su SL.
- **Distancia mínima de stops** (`SYMBOL_TRADE_STOPS_LEVEL`) respetada tanto al abrir como al modificar el SL.

## 6. Backtesting recomendado

> ⚠️ **Usa el símbolo correcto.** El índice Nasdaq 100 se llama `US100`, `USTEC` o `NAS100` según el broker. `NDAQ` es la **acción de Nasdaq, Inc.** (~70–80 USD), no el índice. La cuenta MetaQuotes-Demo **no ofrece el índice** ni historial de ticks profundo ("Calidad del historial: n/a" en el informe = resultados no fiables): usa la demo de un broker real (IC Markets, Pepperstone, etc.).

1. Strategy Tester → modo **"Cada tick basado en ticks reales"** para resultados fiables con trailing/BE.
2. Periodo mínimo recomendado: 2–3 años de NAS100 en M15.
3. Optimiza primero `InpMultiplicadorSL` / `InpMultiplicadorTP` y los umbrales de BE/trailing; deja los periodos de los indicadores para el final (alto riesgo de sobreajuste).
4. Valida siempre con un tramo *out-of-sample* y después en cuenta demo ≥ 1 mes.

## 7. Aviso

Este software se proporciona con fines educativos. El trading apalancado de índices conlleva alto riesgo de pérdida del capital. Prueba siempre en demo antes de operar en real.
