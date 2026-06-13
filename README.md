# BOT-ALGOTRADING — Nasdaq Momentum Pullback (MQL5)

Expert Advisor para MetaTrader 5 que opera el **NASDAQ (NAS100 / USTEC / US100, según tu broker)** en **M15** con una estrategia de **seguimiento de tendencia con entrada en pullback**, durante la sesión de Nueva York.

> Archivo principal: [`MQL5/Experts/NasdaqMomentumPullback.mq5`](MQL5/Experts/NasdaqMomentumPullback.mq5)

---

## 1. Resumen de la estrategia

Todas las señales se evalúan **estrictamente al cierre de vela M15** (vela `[1]`), nunca tick a tick.

> **v2.0 — Rediseño de la señal de entrada.** La validación forward (optimización 2023–2025 + test ciego 2025–2026) demostró que la señal original (cruce MACD + EMA200) **no tenía edge repetible**: de 114 combinaciones de parámetros, 52 eran rentables en el periodo de optimización pero **0 sobrevivían al periodo forward**. Era una estrategia dependiente del régimen alcista de 2023–24. La v2 conserva intacta toda la arquitectura de gestión de riesgo y añade dos cambios estructurales en la entrada (ver abajo). El histórico completo de este proceso está en el log de commits.

| Bloque | Regla |
|---|---|
| **Filtro de régimen (NUEVO)** | **ADX(14) ≥ umbral** (default 23): solo se opera con tendencia real; en rango el EA no entra. Es la corrección de raíz del fallo forward. |
| Filtro de tendencia | Cierre `[1]` por encima (LONG) / debajo (SHORT) de la **EMA 200** |
| Gatillo de entrada (seleccionable) | **Modo 0** = cruce MACD original · **Modo 1 (NUEVO, default)** = pullback a la **EMA rápida (50)**: el precio retrocede a tocar la media y reanuda con una vela de confirmación a favor |
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

**Protecciones contra gaps y sesiones anómalas** (lecciones de backtest sobre USTEC):

- El cierre forzado se **ancla al calendario de sesiones del broker** (`SymbolInfoSessionTrade`): si la sesión del símbolo termina antes de la hora configurada, el EA cierra `InpMargenFinSesion` minutos (default 15) antes del fin de sesión real, mientras todavía hay ticks.
- `InpATRMinimoPuntos` (default 500): si el ATR cae por debajo (festivos, medias sesiones tipo Acción de Gracias), **no se opera**. Evita que un SL minúsculo produzca un lote gigantesco que un gap posterior convierta en pérdida catastrófica.
- `InpLoteMaximo` (default 5.0): techo absoluto de lote como última barrera. Ajústalo a tu tamaño de cuenta.

**Filtros de régimen de mercado** (añadidos tras el análisis del backtest 2023–2026, donde la estrategia ganaba en 2023–24 y se degradaba en el régimen lateral-volátil de 2025):

- `InpPendienteEMABarras` (default 0 = off): exige que la EMA 200 esté subiendo (largos) o bajando (cortos) respecto a hace N velas. Filtra el rango, pero en backtest también eliminó operaciones ganadoras: optimízalo (10–40) en lugar de fijarlo a mano.
- `InpModoInvalidacion` (default 0 = comportamiento original): 1 = el cruce contrario del MACD solo cierra posiciones en pérdida; 2 = invalidación desactivada. Optimizable.
- `InpATRMaximoPuntos` (default 0 = off): techo de volatilidad opcional para excluir regímenes extremos. Optimizable.

**Criterio de optimización personalizado (`OnTester`)**: el EA expone la métrica `(beneficio neto / drawdown máximo) × √nº de operaciones` y descarta combinaciones con menos de 50 trades. En el Strategy Tester selecciona **"Custom max"** como criterio de optimización: evita que el optimizador elija curvas con pocas operaciones afortunadas o con drawdowns inasumibles.

### Plan de test de la v2 (señal rediseñada)

Antes de optimizar, haz **un único backtest** con los defaults nuevos (`InpModoEntrada=1`, `InpUsarADX=true`, `InpADXMinimo=23`, `InpEMARapida=50`) sobre USTEC M15 2023–2026 y compara la curva con la v1. Después, optimiza con **forward 1/3** y "Custom max" estos parámetros:

| Parámetro (texto en MT5) | Variable | Inicio | Paso | Stop |
|---|---|---|---|---|
| ADX mínimo para considerar que hay tendencia | `InpADXMinimo` | 18 | 3 | 33 |
| Periodo de la EMA rápida (pullback en modo 1) | `InpEMARapida` | 20 | 10 | 60 |
| SL = ATR x este multiplicador | `InpMultiplicadorSL` | 1.0 | 0.5 | 2.5 |
| TP = ATR x este multiplicador | `InpMultiplicadorTP` | 2.0 | 0.5 | 4.0 |

**Criterio de aceptación honesto**: solo es candidata a real una configuración que sea rentable **tanto en optimización como en forward** (lo que la v1 nunca logró). Si ninguna lo consigue, la conclusión correcta es que la señal sigue sin edge — no forzar la elección de "la menos mala".

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
