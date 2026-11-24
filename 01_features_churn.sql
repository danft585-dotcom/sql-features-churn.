-- =============================================================================
-- 01_features_churn.sql
-- Genera el dataset de entrenamiento (una fila por usuario) para un modelo de
-- predicción de abandono (churn) en un e-commerce.
-- Motor: PostgreSQL 13+
--
-- Features principales:
--   recency_dias        -> días desde la última compra
--   frequency_pedidos   -> cantidad de pedidos únicos
--   monetary_total      -> gasto total acumulado
--   trend_gasto         -> gasto del último mes - promedio mensual histórico
--
-- Reglas clave:
--   * Solo se usa información ANTERIOR a la fecha de corte (evita data leakage).
--   * Solo cuentan pedidos con status = 'completed'.
--   * Usuarios sin actividad reciben 0 (no NULL) en las agregaciones.
-- =============================================================================

WITH
-- -----------------------------------------------------------------------------
-- 1. Parámetros del snapshot: cambiar acá la fecha de corte y la ventana.
-- -----------------------------------------------------------------------------
parametros AS (
    SELECT
        DATE '2026-11-01'                                         AS fecha_corte,       -- exclusiva
        12                                                        AS meses_historia,    -- ventana para la tendencia
        DATE_TRUNC('month', DATE '2026-11-01' - 1)::DATE          AS ultimo_mes_cerrado
),

-- -----------------------------------------------------------------------------
-- 2. Pedidos válidos con su importe total (un registro por pedido).
-- -----------------------------------------------------------------------------
pedidos_validos AS (
    SELECT
        ord.order_id,
        ord.user_id,
        ord.order_date,
        SUM(itm.quantity * itm.unit_price) AS importe_pedido
    FROM orders            AS ord
    INNER JOIN order_items AS itm ON itm.order_id = ord.order_id
    CROSS JOIN parametros  AS par
    WHERE ord.status = 'completed'
      AND ord.order_date < par.fecha_corte
    GROUP BY
        ord.order_id,
        ord.user_id,
        ord.order_date
),

-- -----------------------------------------------------------------------------
-- 3. Funciones de ventana a nivel pedido:
--    ROW_NUMBER -> identifica el pedido más reciente de cada usuario
--    LAG        -> días transcurridos desde el pedido anterior
-- -----------------------------------------------------------------------------
pedidos_con_ventanas AS (
    SELECT
        ped.order_id,
        ped.user_id,
        ped.order_date,
        ped.importe_pedido,
        ROW_NUMBER() OVER (
            PARTITION BY ped.user_id
            ORDER BY ped.order_date DESC, ped.order_id DESC
        ) AS orden_reciente,
        ped.order_date - LAG(ped.order_date) OVER (
            PARTITION BY ped.user_id
            ORDER BY ped.order_date, ped.order_id
        ) AS dias_desde_pedido_anterior
    FROM pedidos_validos AS ped
),

-- -----------------------------------------------------------------------------
-- 4. Métricas RFM y complementarias por usuario.
-- -----------------------------------------------------------------------------
metricas_usuario AS (
    SELECT
        pcv.user_id,
        MAX(pcv.order_date)                                        AS fecha_ultima_compra,
        MIN(pcv.order_date)                                        AS fecha_primera_compra,
        COUNT(DISTINCT pcv.order_id)                               AS frequency_pedidos,
        SUM(pcv.importe_pedido)                                    AS monetary_total,
        AVG(pcv.importe_pedido)                                    AS ticket_promedio,
        AVG(pcv.dias_desde_pedido_anterior)                        AS dias_promedio_entre_pedidos,
        MAX(CASE WHEN pcv.orden_reciente = 1
                 THEN pcv.importe_pedido END)                      AS importe_ultimo_pedido,
        SUM(CASE WHEN pcv.order_date >= par.fecha_corte - 90
                 THEN pcv.importe_pedido ELSE 0 END)               AS gasto_ultimos_90d
    FROM pedidos_con_ventanas AS pcv
    CROSS JOIN parametros     AS par
    GROUP BY pcv.user_id
),

-- -----------------------------------------------------------------------------
-- 5. Calendario mensual por usuario (incluye meses SIN compras para que el
--    promedio histórico no quede inflado). Empieza en el mes de alta o al inicio
--    de la ventana de historia, lo que ocurra después.
-- -----------------------------------------------------------------------------
calendario_usuario AS (
    SELECT
        usr.user_id,
        mes.mes_inicio::DATE AS mes_inicio
    FROM users             AS usr
    CROSS JOIN parametros  AS par
    CROSS JOIN LATERAL GENERATE_SERIES(
        GREATEST(
            DATE_TRUNC('month', usr.signup_date),
            par.ultimo_mes_cerrado - MAKE_INTERVAL(months => par.meses_historia)
        ),
        par.ultimo_mes_cerrado,
        INTERVAL '1 month'
    ) AS mes (mes_inicio)
    WHERE usr.signup_date < par.fecha_corte
),

-- -----------------------------------------------------------------------------
-- 6. Gasto por usuario y mes (0 cuando no hubo compras).
-- -----------------------------------------------------------------------------
gasto_mensual AS (
    SELECT
        cal.user_id,
        cal.mes_inicio,
        COALESCE(SUM(ped.importe_pedido), 0) AS gasto_mes
    FROM calendario_usuario   AS cal
    LEFT JOIN pedidos_validos AS ped
           ON ped.user_id = cal.user_id
          AND DATE_TRUNC('month', ped.order_date) = cal.mes_inicio
    GROUP BY
        cal.user_id,
        cal.mes_inicio
),

-- -----------------------------------------------------------------------------
-- 7. Tendencia: AVG ... OVER (PARTITION BY) calcula, para cada mes, el promedio
--    de los meses ANTERIORES del mismo usuario. Nos quedamos con el último mes
--    cerrado y comparamos su gasto contra ese promedio histórico.
-- -----------------------------------------------------------------------------
gasto_con_promedio AS (
    SELECT
        gme.user_id,
        gme.mes_inicio,
        gme.gasto_mes,
        AVG(gme.gasto_mes) OVER (
            PARTITION BY gme.user_id
            ORDER BY gme.mes_inicio
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS promedio_mensual_historico,
        COUNT(*) OVER (
            PARTITION BY gme.user_id
            ORDER BY gme.mes_inicio
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS meses_en_historico
    FROM gasto_mensual AS gme
),

tendencia_usuario AS (
    SELECT
        gcp.user_id,
        gcp.gasto_mes                                       AS gasto_ultimo_mes,
        COALESCE(gcp.promedio_mensual_historico, 0)         AS promedio_mensual_historico,
        gcp.meses_en_historico,
        gcp.gasto_mes
          - COALESCE(gcp.promedio_mensual_historico, 0)     AS trend_gasto
    FROM gasto_con_promedio AS gcp
    CROSS JOIN parametros   AS par
    WHERE gcp.mes_inicio = par.ultimo_mes_cerrado
),

-- -----------------------------------------------------------------------------
-- 8. Dataset base: TODOS los usuarios registrados antes del corte (LEFT JOIN),
--    con manejo explícito de nulos.
-- -----------------------------------------------------------------------------
dataset_base AS (
    SELECT
        usr.user_id,
        usr.pais,
        par.fecha_corte,
        par.fecha_corte - usr.signup_date                            AS antiguedad_dias,
        CASE WHEN met.user_id IS NULL THEN 0 ELSE 1 END              AS tiene_compras,

        -- Recency: sin compras -> días desde el alta (el máximo tiempo posible
        -- sin comprar), nunca NULL.
        COALESCE(par.fecha_corte - met.fecha_ultima_compra,
                 par.fecha_corte - usr.signup_date)                  AS recency_dias,
        COALESCE(met.frequency_pedidos, 0)                           AS frequency_pedidos,
        COALESCE(met.monetary_total, 0)::NUMERIC(12, 2)              AS monetary_total,

        COALESCE(tdu.gasto_ultimo_mes, 0)::NUMERIC(12, 2)            AS gasto_ultimo_mes,
        COALESCE(tdu.promedio_mensual_historico, 0)::NUMERIC(12, 2)  AS promedio_mensual_historico,
        COALESCE(tdu.trend_gasto, 0)::NUMERIC(12, 2)                 AS trend_gasto,

        COALESCE(met.ticket_promedio, 0)::NUMERIC(12, 2)             AS ticket_promedio,
        COALESCE(met.importe_ultimo_pedido, 0)::NUMERIC(12, 2)       AS importe_ultimo_pedido,
        COALESCE(met.gasto_ultimos_90d, 0)::NUMERIC(12, 2)           AS gasto_ultimos_90d,
        -- Con 0 o 1 pedido no hay intervalo: se usa la antigüedad como valor neutro-alto.
        COALESCE(met.dias_promedio_entre_pedidos,
                 par.fecha_corte - usr.signup_date)::NUMERIC(10, 1)  AS dias_promedio_entre_pedidos
    FROM users                  AS usr
    CROSS JOIN parametros       AS par
    LEFT JOIN metricas_usuario  AS met ON met.user_id = usr.user_id
    LEFT JOIN tendencia_usuario AS tdu ON tdu.user_id = usr.user_id
    WHERE usr.signup_date < par.fecha_corte
)

-- -----------------------------------------------------------------------------
-- 9. Resultado final + scores RFM (1 = peor, 5 = mejor) con NTILE.
-- -----------------------------------------------------------------------------
SELECT
    dsb.*,
    NTILE(5) OVER (ORDER BY dsb.recency_dias DESC)    AS score_recency,
    NTILE(5) OVER (ORDER BY dsb.frequency_pedidos)    AS score_frequency,
    NTILE(5) OVER (ORDER BY dsb.monetary_total)       AS score_monetary,
    RANK()   OVER (ORDER BY dsb.monetary_total DESC)  AS ranking_gasto
FROM dataset_base AS dsb
ORDER BY dsb.user_id;
