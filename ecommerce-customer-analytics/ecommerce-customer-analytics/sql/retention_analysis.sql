-- =====================================================================
-- retention_analysis.sql  |  PostgreSQL
-- Needs the views from kpi_analysis.sql.
-- Cohorts (by first purchase month), retention curves, payback, time-to-first-purchase,
-- fixed-window retention and CLV by channel, and retention by region.
-- Beware right-censoring: recent cohorts have not had time to reach later months.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. COHORT RETENTION (long format: one row per cohort x month index)
-- Business question: Of customers who first bought in month M, what share buys again in M+k?
-- Decision: timing of post-purchase communication; detect worsening acquisition quality.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW clean.v_cohort_retention AS
WITH first_order AS (
  SELECT customer_id, date_trunc('month', MIN(order_date))::date AS cohort_month
  FROM clean.v_orders_net GROUP BY customer_id
),
activity AS (
  SELECT DISTINCT o.customer_id, f.cohort_month,
         (date_part('year', age(date_trunc('month', o.order_date), f.cohort_month)) * 12
          + date_part('month', age(date_trunc('month', o.order_date), f.cohort_month)))::int AS month_index
  FROM clean.v_orders_net o JOIN first_order f USING (customer_id)
),
sizes AS (SELECT cohort_month, COUNT(*) AS cohort_size FROM first_order GROUP BY cohort_month),
last_m AS (SELECT date_trunc('month', MAX(order_date))::date AS last_month FROM clean.v_orders_net)
SELECT a.cohort_month, s.cohort_size, a.month_index,
       COUNT(DISTINCT a.customer_id) AS active_customers,
       ROUND(100.0 * COUNT(DISTINCT a.customer_id) / s.cohort_size, 1) AS retention_pct
FROM activity a
JOIN sizes s USING (cohort_month)
CROSS JOIN last_m l
-- censoring guard: only months that have actually happened for that cohort
WHERE a.cohort_month + (a.month_index * INTERVAL '1 month') <= l.last_month
GROUP BY a.cohort_month, s.cohort_size, a.month_index
ORDER BY a.cohort_month, a.month_index;

-- Pivot: retention % for months 0..6 (one row per cohort)
SELECT cohort_month, MAX(cohort_size) AS cohort_size,
       MAX(retention_pct) FILTER (WHERE month_index = 0) AS m0,
       MAX(retention_pct) FILTER (WHERE month_index = 1) AS m1,
       MAX(retention_pct) FILTER (WHERE month_index = 2) AS m2,
       MAX(retention_pct) FILTER (WHERE month_index = 3) AS m3,
       MAX(retention_pct) FILTER (WHERE month_index = 6) AS m6,
       MAX(retention_pct) FILTER (WHERE month_index = 12) AS m12
FROM clean.v_cohort_retention
GROUP BY cohort_month ORDER BY cohort_month;

-- Average retention curve by cohort year (are newer cohorts better or worse?)
SELECT date_part('year', cohort_month)::int AS cohort_year, month_index,
       ROUND(AVG(retention_pct), 1) AS avg_retention_pct, COUNT(*) AS cohorts_in_average
FROM clean.v_cohort_retention
WHERE month_index BETWEEN 1 AND 12
GROUP BY 1, 2 ORDER BY 1, 2;

-- ---------------------------------------------------------------------
-- 2. TIME FROM SIGNUP TO FIRST PURCHASE (acquisition month vs first purchase month)
-- ---------------------------------------------------------------------
WITH fp AS (SELECT customer_id, MIN(order_date) AS first_order FROM clean.v_orders_net GROUP BY customer_id)
SELECT date_trunc('month', c.signup_date)::date AS signup_month,
       COUNT(*)                                  AS signups,
       COUNT(fp.customer_id)                     AS converted,
       ROUND(100.0 * COUNT(fp.customer_id) / COUNT(*), 1) AS conversion_pct,
       ROUND((percentile_cont(0.5) WITHIN GROUP (ORDER BY fp.first_order - c.signup_date))::numeric, 0) AS median_days_to_first_order
FROM clean.customers c LEFT JOIN fp ON fp.customer_id = c.customer_id
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 3. CUMULATIVE PROFIT PER CUSTOMER BY COHORT (payback curve)
-- The month where this passes the cohort's CAC is the payback month.
-- ---------------------------------------------------------------------
WITH fo AS (
  SELECT customer_id, date_trunc('month', MIN(order_date))::date AS cohort_month
  FROM clean.v_orders_net GROUP BY customer_id
),
rev AS (
  SELECT fo.cohort_month,
         (date_part('year', age(o.order_month, fo.cohort_month)) * 12
          + date_part('month', age(o.order_month, fo.cohort_month)))::int AS month_index,
         SUM(o.gross_profit) AS profit
  FROM clean.v_orders_net o JOIN fo USING (customer_id)
  GROUP BY 1, 2
),
sz AS (SELECT cohort_month, COUNT(*) AS n FROM fo GROUP BY 1)
SELECT r.cohort_month, r.month_index,
       ROUND(SUM(r.profit) OVER (PARTITION BY r.cohort_month ORDER BY r.month_index) / sz.n, 0) AS cum_profit_per_customer
FROM rev r JOIN sz USING (cohort_month)
WHERE r.cohort_month IN (DATE '2023-03-01', DATE '2024-03-01', DATE '2025-03-01')
ORDER BY 1, 2
LIMIT 40;

-- ---------------------------------------------------------------------
-- 4. FIXED-WINDOW RETENTION AND 12-MONTH PROFIT BY CHANNEL (fair comparison)
-- Only customers whose first order is at least N days before the last date in the data are eligible
-- for an N-day metric (otherwise young customers would drag the average down).
-- ---------------------------------------------------------------------
WITH asof AS (SELECT MAX(order_date) AS d FROM clean.v_orders_net),
fo AS (
  SELECT customer_id, MIN(order_date) AS first_order FROM clean.v_orders_net GROUP BY customer_id
),
agg AS (
  SELECT f.customer_id, f.first_order, c.channel_id,
         BOOL_OR(o.order_date > f.first_order AND o.order_date <= f.first_order + 90)  AS repeat_90,
         BOOL_OR(o.order_date > f.first_order AND o.order_date <= f.first_order + 365) AS repeat_365,
         COALESCE(SUM(o.gross_profit) FILTER (WHERE o.order_date <= f.first_order + 365), 0) AS profit_first_365d
  FROM fo f
  JOIN clean.customers c ON c.customer_id = f.customer_id
  JOIN clean.v_orders_net o ON o.customer_id = f.customer_id
  GROUP BY f.customer_id, f.first_order, c.channel_id
)
SELECT m.channel_name,
       COUNT(*) FILTER (WHERE a.first_order <= asof.d - 90)  AS eligible_90d,
       ROUND(100.0 * COUNT(*) FILTER (WHERE a.first_order <= asof.d - 90 AND a.repeat_90)
             / NULLIF(COUNT(*) FILTER (WHERE a.first_order <= asof.d - 90), 0), 1)   AS repeat_within_90d_pct,
       COUNT(*) FILTER (WHERE a.first_order <= asof.d - 365) AS eligible_365d,
       ROUND(100.0 * COUNT(*) FILTER (WHERE a.first_order <= asof.d - 365 AND a.repeat_365)
             / NULLIF(COUNT(*) FILTER (WHERE a.first_order <= asof.d - 365), 0), 1)  AS repeat_within_365d_pct,
       ROUND(AVG(a.profit_first_365d) FILTER (WHERE a.first_order <= asof.d - 365), 0) AS profit_per_customer_first_365d
FROM agg a CROSS JOIN asof
JOIN clean.marketing_channels m ON m.channel_id = a.channel_id
GROUP BY m.channel_name
ORDER BY repeat_within_365d_pct DESC;

-- ---------------------------------------------------------------------
-- 5. RETENTION BY REGION (90-day repeat, eligible customers only)
-- ---------------------------------------------------------------------
WITH asof AS (SELECT MAX(order_date) AS d FROM clean.v_orders_net),
fo AS (SELECT customer_id, MIN(order_date) AS first_order FROM clean.v_orders_net GROUP BY customer_id),
agg AS (
  SELECT f.customer_id, f.first_order, c.region,
         BOOL_OR(o.order_date > f.first_order AND o.order_date <= f.first_order + 90) AS repeat_90
  FROM fo f JOIN clean.customers c ON c.customer_id = f.customer_id
  JOIN clean.v_orders_net o ON o.customer_id = f.customer_id
  GROUP BY f.customer_id, f.first_order, c.region
)
SELECT region, COUNT(*) AS eligible_customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE repeat_90) / COUNT(*), 1) AS repeat_within_90d_pct
FROM agg CROSS JOIN asof
WHERE first_order <= asof.d - 90 AND region IS NOT NULL
GROUP BY region HAVING COUNT(*) >= 200
ORDER BY repeat_within_90d_pct DESC;

-- ---------------------------------------------------------------------
-- 6. RETENTION LIFT FROM A GOOD FIRST EXPERIENCE (hypothesis test, not causal proof)
-- Do customers whose FIRST order had a returned item repeat less often?
-- ---------------------------------------------------------------------
WITH asof AS (SELECT MAX(order_date) AS d FROM clean.v_orders_net),
first_ord AS (
  SELECT DISTINCT ON (o.customer_id) o.customer_id, o.order_id, o.order_date::date AS first_date
  FROM clean.orders o WHERE o.order_status <> 'Cancelled' ORDER BY o.customer_id, o.order_date, o.order_id
),
flag AS (
  SELECT f.customer_id, f.first_date,
         BOOL_OR(i.is_returned) AS first_order_had_return,
         EXISTS (SELECT 1 FROM clean.v_orders_net n WHERE n.customer_id = f.customer_id
                 AND n.order_date > f.first_date AND n.order_date <= f.first_date + 180) AS repeated_180d
  FROM first_ord f JOIN clean.order_items i ON i.order_id = f.order_id
  GROUP BY f.customer_id, f.first_date
)
SELECT first_order_had_return, COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE repeated_180d) / COUNT(*), 1) AS repeat_within_180d_pct
FROM flag CROSS JOIN asof WHERE first_date <= asof.d - 180
GROUP BY 1 ORDER BY 1;
