-- ============================================================================
-- OLIST E-COMMERCE DELIVERY ANALYSIS
-- Business question:
--   Does delivery delay predict lower customer review scores, and does this
--   effect vary meaningfully by seller state/region — which regions should be
--   prioritized for logistics review?
--
-- Scope: ONLY orders, order_items, sellers, order_reviews (loaded from
-- data/Raw/*.csv into the MySQL database `olist`).
--
-- Grain strategy (validated in section 4):
--   orders        : 1 row per order           (order_id unique)
--   order_items   : 1 row per item            (order_id repeated -> one-to-many)
--   sellers       : 1 row per seller          (seller_id unique)
--   order_reviews : 1 row per review record   (order_id repeated for 547 orders)
--
--   The analytical grain of the final analysis is ONE ROW PER ORDER.
--   Reviews are pre-aggregated to order grain (mean review_score per order).
--   Items are pre-aggregated to order grain (one seller_state per order).
--   Orders whose items span more than one seller_state (509 of 96,470) are
--   excluded from the state analysis because they cannot be attributed to a
--   single state. No DISTINCT is used to hide duplication.
-- ============================================================================

USE olist;

-- ----------------------------------------------------------------------------
-- 2. DATA-QUALITY CHECKS
-- ----------------------------------------------------------------------------

-- Row counts of the four in-scope tables
SELECT 'orders' AS tbl, COUNT(*) AS rows_ FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'sellers',    COUNT(*) FROM sellers
UNION ALL SELECT 'order_reviews', COUNT(*) FROM order_reviews;

-- order_status distribution (only 'delivered' is in scope)
SELECT order_status, COUNT(*) AS n
FROM orders
GROUP BY order_status
ORDER BY n DESC;

-- NULL counts on the two date columns used for delivery_delay
SELECT
  COUNT(*) AS delivered_rows,
  SUM(order_delivered_customer_date IS NULL) AS null_actual_date,
  SUM(order_estimated_delivery_date  IS NULL) AS null_estimated_date
FROM orders
WHERE order_status = 'delivered';

-- review_score range and distribution (valid range expected: 1..5)
SELECT review_score, COUNT(*) AS n
FROM order_reviews
GROUP BY review_score
ORDER BY review_score;

-- ----------------------------------------------------------------------------
-- 3. DELIVERY-DELAY CALCULATION
-- ----------------------------------------------------------------------------
-- delivery_delay = order_delivered_customer_date - order_estimated_delivery_date
--   positive = late, 0 = on estimated date, negative = early.
-- Dates were loaded as DATETIME after verifying the CSV format
-- '%Y-%m-%d %H:%M:%S' (all values parsed; zero failures).
-- Delay is computed in seconds and converted to fractional days so that the
-- time-of-day component of the actual delivery timestamp is preserved.
-- No rows are removed for being zero, negative, or extreme.

WITH delivered AS (
    SELECT
        order_id,
        customer_id,
        order_delivered_customer_date,
        order_estimated_delivery_date,
        TIMESTAMPDIFF(SECOND,
                      order_estimated_delivery_date,
                      order_delivered_customer_date) / 86400.0 AS delivery_delay
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date  IS NOT NULL
)
SELECT
    COUNT(*)                                    AS n_orders,
    ROUND(MIN(delivery_delay), 2)               AS min_delay_days,
    ROUND(MAX(delivery_delay), 2)               AS max_delay_days,
    ROUND(AVG(delivery_delay), 2)               AS avg_delay_days,
    ROUND(STDDEV_SAMP(delivery_delay), 2)       AS std_delay_days,
    SUM(delivery_delay = 0)                     AS n_zero,
    SUM(delivery_delay < 0)                     AS n_early,
    SUM(delivery_delay > 0)                     AS n_late
FROM delivered;

-- Extreme EARLY deliveries: verify the underlying dates are plausible
SELECT order_id,
       order_estimated_delivery_date,
       order_delivered_customer_date,
       ROUND(TIMESTAMPDIFF(SECOND, order_estimated_delivery_date,
                                  order_delivered_customer_date) / 86400.0, 2) AS delivery_delay
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
ORDER BY TIMESTAMPDIFF(SECOND, order_estimated_delivery_date,
                             order_delivered_customer_date)
LIMIT 5;

-- Extreme LATE deliveries: verify the underlying dates are plausible
-- (delivered date must be >= purchase date; estimated date after purchase)
SELECT order_id,
       order_purchase_timestamp,
       order_estimated_delivery_date,
       order_delivered_customer_date,
       ROUND(TIMESTAMPDIFF(SECOND, order_estimated_delivery_date,
                                  order_delivered_customer_date) / 86400.0, 2) AS delivery_delay
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
ORDER BY TIMESTAMPDIFF(SECOND, order_estimated_delivery_date,
                             order_delivered_customer_date) DESC
LIMIT 5;

-- Sanity check: any delivered order whose actual date precedes its purchase date?
-- (expected 0 -> would indicate a data error)
SELECT COUNT(*) AS impossible_deliveries
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
  AND order_delivered_customer_date < order_purchase_timestamp;

-- ----------------------------------------------------------------------------
-- 4. GRAIN / DUPLICATE CHECKS
-- ----------------------------------------------------------------------------

-- 4a. Is order_id unique in orders?
SELECT COUNT(*) AS rows_, COUNT(DISTINCT order_id) AS distinct_orders FROM orders;

-- 4b. How many items per order? (max multiplicity = 21)
SELECT items_per_order, COUNT(*) AS n_orders
FROM (SELECT order_id, COUNT(*) AS items_per_order
      FROM order_items GROUP BY order_id) t
GROUP BY items_per_order
ORDER BY items_per_order;

-- 4c. Is order_id unique in order_reviews? (No: 547 orders have 2-3 records)
SELECT reviews_per_order, COUNT(*) AS n_orders
FROM (SELECT order_id, COUNT(*) AS reviews_per_order
      FROM order_reviews GROUP BY order_id) t
GROUP BY reviews_per_order
ORDER BY reviews_per_order;

-- 4d. Row counts after each join (documents where duplication appears)
--     orders x order_items : explodes to item grain (112,650 rows for orders
--                            that have items)
--     orders x order_reviews: explodes for the 547 multi-review orders
--     orders x (pre-agg items) x (pre-agg reviews): returns to order grain
SELECT 'orders only'            AS step, COUNT(*) AS rows_ FROM orders
UNION ALL
SELECT 'orders x order_items',
       (SELECT COUNT(*) FROM orders o JOIN order_items i USING (order_id))
UNION ALL
SELECT 'orders x order_reviews',
       (SELECT COUNT(*) FROM orders o JOIN order_reviews r USING (order_id));

-- 4e. Multi-state orders: orders whose items come from >1 seller_state
--     (these cannot be attributed to a single state -> excluded later)
SELECT n_states, COUNT(*) AS n_orders
FROM (SELECT o.order_id, COUNT(DISTINCT s.seller_state) AS n_states
      FROM orders o
      JOIN order_items i USING (order_id)
      JOIN sellers s USING (seller_id)
      WHERE o.order_status = 'delivered'
      GROUP BY o.order_id) t
GROUP BY n_states
ORDER BY n_states;

-- ----------------------------------------------------------------------------
-- 5. JOIN CONSTRUCTION (analytical grain = 1 row per order)
-- ----------------------------------------------------------------------------
-- CTE order_grain builds exactly one row per delivered order with:
--   * delivery_delay        (from orders)
--   * seller_state          (from items -> sellers, pre-aggregated;
--                            only orders with a single state qualify)
--   * review_score_order    (from order_reviews, pre-aggregated as the mean
--                            of all review records on that order)
--
-- Each source table is aggregated BEFORE the joins, so no join is
-- one-to-many and no DISTINCT is needed to remove duplicates.

-- ----------------------------------------------------------------------------
-- 6 + 7. STATE-LEVEL AGGREGATION + WINDOW-FUNCTION RANKING
-- ----------------------------------------------------------------------------

WITH delivered AS (
    -- All delivered orders with both dates (delay = actual - estimated)
    SELECT
        order_id,
        TIMESTAMPDIFF(SECOND,
                      order_estimated_delivery_date,
                      order_delivered_customer_date) / 86400.0 AS delivery_delay
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date  IS NOT NULL
),
order_state AS (
    -- Items -> sellers, pre-aggregated to ONE state per order.
    -- Orders spanning multiple seller_states get n_states > 1 and are
    -- excluded from the state analysis (they have no single home state).
    SELECT
        i.order_id,
        MIN(s.seller_state) AS seller_state,
        COUNT(DISTINCT s.seller_state) AS n_states
    FROM order_items i
    JOIN sellers s ON i.seller_id = s.seller_id
    GROUP BY i.order_id
),
order_review AS (
    -- Reviews pre-aggregated to ONE row per order (mean score).
    -- 547 orders carry 2-3 review records; averaging keeps them at order grain.
    SELECT
        order_id,
        AVG(review_score) AS review_score_order,
        COUNT(*)          AS n_reviews
    FROM order_reviews
    GROUP BY order_id
),
order_grain AS (
    -- Final analytical grain: one row per delivered, reviewed, single-state order
    SELECT
        d.order_id,
        d.delivery_delay,
        os.seller_state,
        orev.review_score_order,
        orev.n_reviews
    FROM delivered d
    JOIN order_state   os   ON d.order_id = os.order_id
    JOIN order_review  orev ON d.order_id = orev.order_id
    WHERE os.n_states = 1
),
state_agg AS (
    SELECT
        seller_state,
        COUNT(*) AS order_volume,
        AVG(delivery_delay)      AS avg_delivery_delay,
        AVG(delivery_delay > 0)  AS pct_late_orders,
        AVG(review_score_order)  AS avg_review_score,
        AVG(CASE WHEN review_score_order <= 2 THEN 1.0 ELSE 0.0 END) AS pct_low_review
    FROM order_grain
    GROUP BY seller_state
)
SELECT
    seller_state,
    order_volume,
    ROUND(avg_delivery_delay, 2)                       AS avg_delivery_delay,
    ROUND(100 * pct_late_orders, 1)                    AS pct_late_orders,
    ROUND(avg_review_score, 3)                         AS avg_review_score,
    ROUND(100 * pct_low_review, 1)                     AS pct_low_review,
    RANK() OVER (ORDER BY avg_delivery_delay DESC)     AS delay_rank
FROM state_agg
ORDER BY delay_rank, seller_state;

-- ----------------------------------------------------------------------------
-- 8. PRIORITY-STATE OUTPUT
-- ----------------------------------------------------------------------------
-- Same CTE chain; states are then filtered by a minimum order volume so that
-- small-state averages are not over-interpreted. Threshold is chosen after
-- inspecting the volume distribution (see next query) and documented below.

WITH delivered AS (
    SELECT
        order_id,
        TIMESTAMPDIFF(SECOND,
                      order_estimated_delivery_date,
                      order_delivered_customer_date) / 86400.0 AS delivery_delay
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date  IS NOT NULL
),
order_state AS (
    SELECT i.order_id, MIN(s.seller_state) AS seller_state,
           COUNT(DISTINCT s.seller_state) AS n_states
    FROM order_items i
    JOIN sellers s ON i.seller_id = s.seller_id
    GROUP BY i.order_id
),
order_review AS (
    SELECT order_id, AVG(review_score) AS review_score_order
    FROM order_reviews
    GROUP BY order_id
),
order_grain AS (
    SELECT d.order_id, d.delivery_delay, os.seller_state, orev.review_score_order
    FROM delivered d
    JOIN order_state  os   ON d.order_id = os.order_id
    JOIN order_review orev ON d.order_id = orev.order_id
    WHERE os.n_states = 1
),
state_agg AS (
    SELECT seller_state,
           COUNT(*) AS order_volume,
           AVG(delivery_delay)     AS avg_delivery_delay,
           AVG(delivery_delay > 0) AS pct_late_orders,
           AVG(review_score_order) AS avg_review_score,
           AVG(CASE WHEN review_score_order <= 2 THEN 1.0 ELSE 0.0 END) AS pct_low_review
    FROM order_grain
    GROUP BY seller_state
),
ranked AS (
    SELECT *,
           RANK() OVER (ORDER BY avg_delivery_delay DESC) AS delay_rank
    FROM state_agg
)
SELECT seller_state, order_volume,
       ROUND(avg_delivery_delay, 2) AS avg_delivery_delay,
       ROUND(100 * pct_late_orders, 1) AS pct_late_orders,
       ROUND(avg_review_score, 3)   AS avg_review_score,
       ROUND(100 * pct_low_review, 1) AS pct_low_review,
       delay_rank
FROM ranked
WHERE order_volume >= 1000      -- minimum-volume threshold (documented in README
                                -- and OVERNIGHT_REVIEW; see section 9 to inspect
                                -- the distribution that justifies it)
ORDER BY delay_rank;

-- ----------------------------------------------------------------------------
-- 9. VALIDATION QUERIES
-- ----------------------------------------------------------------------------

-- 9a. Volume distribution: justifies the 1000-order threshold
--     (states below the threshold have unstable averages)
WITH delivered AS (
    SELECT order_id,
           TIMESTAMPDIFF(SECOND, order_estimated_delivery_date,
                                 order_delivered_customer_date) / 86400.0 AS delivery_delay
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date  IS NOT NULL
),
order_state AS (
    SELECT i.order_id, MIN(s.seller_state) AS seller_state,
           COUNT(DISTINCT s.seller_state) AS n_states
    FROM order_items i JOIN sellers s ON i.seller_id = s.seller_id
    GROUP BY i.order_id
),
order_review AS (
    SELECT order_id, AVG(review_score) AS review_score_order
    FROM order_reviews GROUP BY order_id
)
SELECT os.seller_state,
       COUNT(*) AS order_volume,
       ROUND(AVG(d.delivery_delay), 2) AS avg_delivery_delay,
       ROUND(AVG(orev.review_score_order), 3) AS avg_review_score
FROM delivered d
JOIN order_state  os   ON d.order_id = os.order_id
JOIN order_review orev ON d.order_id = orev.order_id
WHERE os.n_states = 1
GROUP BY os.seller_state
ORDER BY order_volume DESC;

-- 9b. Overall association: average review score by delay band
--     (order grain: single-state delivered orders with a review, i.e. the same
--      analysis set as section 6, so these band numbers match the notebook)
WITH delivered AS (
    SELECT order_id,
           TIMESTAMPDIFF(SECOND, order_estimated_delivery_date,
                                 order_delivered_customer_date) / 86400.0 AS delivery_delay
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date  IS NOT NULL
),
order_state AS (
    SELECT i.order_id, MIN(s.seller_state) AS seller_state,
           COUNT(DISTINCT s.seller_state) AS n_states
    FROM order_items i JOIN sellers s ON i.seller_id = s.seller_id
    GROUP BY i.order_id
),
order_review AS (
    SELECT order_id, AVG(review_score) AS review_score_order
    FROM order_reviews GROUP BY order_id
),
order_grain AS (
    SELECT d.delivery_delay, orev.review_score_order
    FROM delivered d
    JOIN order_state  os   ON d.order_id = os.order_id
    JOIN order_review orev ON d.order_id = orev.order_id
    WHERE os.n_states = 1
)
SELECT
    CASE
        WHEN delivery_delay <= -7 THEN '1. very early (<= -7d)'
        WHEN delivery_delay <=  0 THEN '2. early/on-time (-7d..0d)'
        WHEN delivery_delay <=  3 THEN '3. late 1-3d'
        WHEN delivery_delay <=  7 THEN '4. late 4-7d'
        WHEN delivery_delay <= 14 THEN '5. late 8-14d'
        ELSE                            '6. late 15d+'
    END AS delay_band,
    COUNT(*) AS n_orders,
    ROUND(AVG(delivery_delay), 2)      AS avg_delay,
    ROUND(AVG(review_score_order), 3)  AS avg_review_score,
    ROUND(100 * AVG(CASE WHEN review_score_order <= 2 THEN 1.0 ELSE 0.0 END), 1)
                                       AS pct_low_review
FROM order_grain
GROUP BY delay_band
ORDER BY delay_band;

-- 9c. Sample records behind the priority states (spot-check correctness)
--     Uses the same order-grain construction as the main analysis.
WITH delivered AS (
    SELECT order_id, order_purchase_timestamp,
           order_estimated_delivery_date, order_delivered_customer_date,
           TIMESTAMPDIFF(SECOND, order_estimated_delivery_date,
                                 order_delivered_customer_date) / 86400.0 AS delivery_delay
    FROM orders
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_estimated_delivery_date  IS NOT NULL
),
order_state AS (
    SELECT i.order_id, MIN(s.seller_state) AS seller_state,
           COUNT(DISTINCT s.seller_state) AS n_states
    FROM order_items i JOIN sellers s ON i.seller_id = s.seller_id
    GROUP BY i.order_id
),
order_review AS (
    SELECT order_id, AVG(review_score) AS review_score_order
    FROM order_reviews GROUP BY order_id
)
SELECT d.order_id,
       d.order_purchase_timestamp,
       d.order_estimated_delivery_date,
       d.order_delivered_customer_date,
       ROUND(d.delivery_delay, 2) AS delivery_delay,
       orev.review_score_order,
       os.seller_state
FROM delivered d
JOIN order_state  os   ON d.order_id = os.order_id
JOIN order_review orev ON d.order_id = orev.order_id
WHERE os.n_states = 1
  AND os.seller_state = 'SP'
ORDER BY d.delivery_delay DESC
LIMIT 10;
