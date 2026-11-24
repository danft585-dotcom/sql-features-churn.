-- =============================================================================
-- 00_esquema_y_datos.sql
-- Esquema mínimo de e-commerce + datos de ejemplo para probar la consulta de
-- features (01_features_churn.sql).
-- Motor: PostgreSQL 13+
--
-- Los datos están pensados para cubrir casos borde:
--   1 Ana       -> cliente activa, compra todos los meses y sube su gasto en octubre
--   2 Bruno     -> compraba mucho y dejó de comprar en agosto (riesgo de churn)
--   3 Carla     -> cliente nueva (alta en septiembre 2026)
--   4 Diego     -> se registró pero nunca compró (todas las métricas deben dar 0)
--   5 Elena     -> solo compras antiguas (2025), fuera de la ventana de tendencia
--   6 Facundo   -> tiene pedidos cancelados que NO deben contar
--   7 Gabriela  -> tiene una compra POSTERIOR a la fecha de corte (no debe filtrarse
--                  al dataset: evita data leakage)
-- =============================================================================

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
    user_id      INTEGER PRIMARY KEY,
    nombre       VARCHAR(50) NOT NULL,
    signup_date  DATE        NOT NULL,
    pais         VARCHAR(30)
);

CREATE TABLE orders (
    order_id     INTEGER PRIMARY KEY,
    user_id      INTEGER     NOT NULL REFERENCES users (user_id),
    order_date   DATE        NOT NULL,
    status       VARCHAR(20) NOT NULL  -- 'completed' | 'cancelled' | 'returned'
);

CREATE TABLE order_items (
    order_item_id SERIAL PRIMARY KEY,
    order_id      INTEGER        NOT NULL REFERENCES orders (order_id),
    product_id    INTEGER        NOT NULL,
    quantity      INTEGER        NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price >= 0)
);

INSERT INTO users (user_id, nombre, signup_date, pais) VALUES
    (1, 'Ana',      DATE '2025-06-10', 'México'),
    (2, 'Bruno',    DATE '2025-08-01', 'Argentina'),
    (3, 'Carla',    DATE '2026-09-15', 'Chile'),
    (4, 'Diego',    DATE '2026-03-01', 'México'),
    (5, 'Elena',    DATE '2025-01-20', 'Colombia'),
    (6, 'Facundo',  DATE '2026-02-11', 'Argentina'),
    (7, 'Gabriela', DATE '2026-04-05', 'Perú');

INSERT INTO orders (order_id, user_id, order_date, status) VALUES
    -- Ana: compra todos los meses
    (101, 1, DATE '2026-05-12', 'completed'),
    (102, 1, DATE '2026-06-08', 'completed'),
    (103, 1, DATE '2026-07-15', 'completed'),
    (104, 1, DATE '2026-08-03', 'completed'),
    (105, 1, DATE '2026-09-21', 'completed'),
    (106, 1, DATE '2026-10-05', 'completed'),
    (107, 1, DATE '2026-10-28', 'completed'),
    -- Bruno: gastaba fuerte, último pedido en agosto
    (201, 2, DATE '2025-11-20', 'completed'),
    (202, 2, DATE '2026-01-14', 'completed'),
    (203, 2, DATE '2026-03-30', 'completed'),
    (204, 2, DATE '2026-06-02', 'completed'),
    (205, 2, DATE '2026-08-22', 'completed'),
    -- Carla: nueva
    (301, 3, DATE '2026-09-20', 'completed'),
    (302, 3, DATE '2026-10-18', 'completed'),
    -- Diego: sin pedidos
    -- Elena: solo compras antiguas
    (501, 5, DATE '2025-03-02', 'completed'),
    (502, 5, DATE '2025-07-19', 'completed'),
    (503, 5, DATE '2025-10-30', 'completed'),
    -- Facundo: cancelaciones + una compra válida
    (601, 6, DATE '2026-03-10', 'cancelled'),
    (602, 6, DATE '2026-05-25', 'completed'),
    (603, 6, DATE '2026-10-12', 'cancelled'),
    -- Gabriela: compra posterior a la fecha de corte (2026-11-01)
    (701, 7, DATE '2026-07-07', 'completed'),
    (702, 7, DATE '2026-10-09', 'completed'),
    (703, 7, DATE '2026-11-10', 'completed');

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (101, 10, 1,  50.00),
    (102, 11, 2,  30.00),
    (103, 10, 1,  50.00), (103, 12, 1, 20.00),
    (104, 13, 1,  45.00),
    (105, 11, 1,  30.00), (105, 14, 1, 35.00),
    (106, 15, 1, 120.00),
    (107, 10, 2,  50.00),
    (201, 20, 1, 300.00),
    (202, 21, 2, 150.00),
    (203, 20, 1, 300.00), (203, 22, 1, 80.00),
    (204, 23, 1, 250.00),
    (205, 21, 1, 150.00),
    (301, 30, 1,  40.00),
    (302, 31, 3,  25.00),
    (501, 50, 1,  90.00),
    (502, 51, 1,  60.00),
    (503, 50, 2,  90.00),
    (601, 60, 1, 500.00),
    (602, 61, 1,  75.00),
    (603, 60, 1, 500.00),
    (701, 70, 1,  60.00),
    (702, 71, 2,  45.00),
    (703, 70, 5,  60.00);
