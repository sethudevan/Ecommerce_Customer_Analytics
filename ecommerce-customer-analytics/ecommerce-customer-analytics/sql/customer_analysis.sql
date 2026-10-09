-- =====================================================================
-- customer_analysis.sql  |  PostgreSQL
-- Needs the views from kpi_analysis.sql.
-- Repeat purchase, order gaps, inactivity, CLV, RFM, customer groups, concentration.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. REPEAT PURCHASE RATE AND FREQUENCY
-- Business question: What share of customers come back, and how often do they buy?
-- Decision: fund (or not) a post-purchase / loyalty programme.
-- ---------------------------------------------------------------------
WITH cust AS (
  SELECT customer_id, COUNT(*) AS orders, SUM(net_revenue) AS revenue
  FROM clean.v_orders_net GROUP BY customer_id
)
SELECT COUNT(*)                                                           AS customers,
       ROUND(AVG(orders), 2)                                              AS avg_orders_per_customer,
       ROUND(100.0 * COUNT(*) FILTER (WHERE orders >= 2) / COUNT(*), 1)   AS repeat_rate_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE orders >= 3) / COUNT(*), 1)   AS three_plus_pct
FROM cust;

-- Distribution of orders per customer
SELECT LEAST(orders, 8) AS orders_capped_at_8, COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM (SELECT customer_id, COUNT(*) AS orders FROM clean.v_orders_net GROUP BY customer_id) x
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 2. TIME BETWEEN ORDERS (LAG / LEAD) -> data-driven inactivity threshold
-- ---------------------------------------------------------------------
-- Gap percentiles: use the ~80th-90th percentile as the 'inactive after N days' rule
SELECT percentile_cont(ARRAY[0.5, 0.8, 0.9]) WITHIN GROUP (ORDER BY gap_days) AS gap_days_p50_p80_p90,
       COUNT(*) AS gaps
FROM (SELECT order_date - LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS gap_days
      FROM clean.v_orders_net) g
WHERE gap_days IS NOT NULL;

-- Per-order view: previous gap and next order date
SELECT customer_id, order_date,
       order_date - LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date) AS days_since_prev,
       LEAD(order_date) OVER (PARTITION BY customer_id ORDER BY order_date)              AS next_order_date
FROM clean.v_orders_net
ORDER BY customer_id, order_date
LIMIT 20;

-- ---------------------------------------------------------------------
-- 3. INACTIVITY / CHURN BANDS
-- Definition: measured from the last date in the data (not today). 90/180 days are starting
-- points; confirm against the gap percentiles above.
-- Decision: size and trigger a win-back campaign.
-- ---------------------------------------------------------------------
WITH params AS (SELECT MAX(order_date) AS as_of FROM clean.v_orders_net),
cust AS (
  SELECT customer_id, MAX(order_date) AS last_order, COUNT(*) AS orders, SUM(net_revenue) AS revenue
  FROM clean.v_orders_net GROUP BY customer_id
)
SELECT CASE WHEN p.as_of - last_order <= 90  THEN '1. Active (0-90d)'
            WHEN p.as_of - last_order <= 180 THEN '2. At risk (91-180d)'
            ELSE '3. Inactive (180d+)' END AS status,
       COUNT(*)                            AS customers,
       ROUND(SUM(revenue), 0)              AS lifetime_revenue,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_customers
FROM cust CROSS JOIN params p
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 4. HISTORICAL CLV BY CHANNEL
-- Limitation: young customers have had less time to accumulate value. For fair comparisons use the
-- fixed-window version in retention_analysis.sql (first-365-day profit) or compare within the same cohort.
-- Decision: maximum affordable CAC per channel.
-- ---------------------------------------------------------------------
WITH clv AS (
  SELECT customer_id, channel_id, COUNT(*) AS orders, SUM(net_revenue) AS revenue, SUM(gross_profit) AS profit
  FROM clean.v_orders_net GROUP BY customer_id, channel_id
)
SELECT m.channel_name, COUNT(*) AS customers,
       ROUND(AVG(revenue), 0) AS avg_revenue_clv,
       ROUND(AVG(profit), 0)  AS avg_profit_clv,
       ROUND(AVG(orders), 2)  AS avg_orders
FROM clv JOIN clean.marketing_channels m USING (channel_id)
GROUP BY m.channel_name ORDER BY avg_profit_clv DESC;

-- ---------------------------------------------------------------------
-- 5. RFM SEGMENTATION (view)
-- R: days since last completed order (as of last date in data); F: number of orders; M: net revenue.
-- NTILE(5) scores; frequency has many ties, so ties are broken by monetary value and then customer_id
-- (customer_id makes the result deterministic and reproducible).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW clean.v_rfm AS
WITH params AS (SELECT MAX(order_date) AS as_of FROM clean.v_orders_net),
base AS (
  SELECT customer_id,
         (SELECT as_of FROM params) - MAX(order_date) AS recency_days,
         COUNT(*)           AS frequency,
         SUM(net_revenue)   AS monetary,
         SUM(gross_profit)  AS profit
  FROM clean.v_orders_net GROUP BY customer_id
),
scored AS (
  SELECT *,
         6 - NTILE(5) OVER (ORDER BY recency_days, customer_id) AS r_score,   -- most recent = 5
         NTILE(5) OVER (ORDER BY frequency, monetary, customer_id) AS f_score,
         NTILE(5) OVER (ORDER BY monetary, customer_id)   AS m_score
  FROM base
)
SELECT *,
  CASE
    WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
    WHEN r_score >= 3 AND f_score >= 4                  THEN 'Loyal Customers'
    WHEN r_score >= 4 AND f_score BETWEEN 2 AND 3       THEN 'Potential Loyalists'
    WHEN r_score >= 4 AND f_score = 1                   THEN 'New Customers'
    WHEN r_score <= 2 AND f_score >= 4                  THEN 'At-Risk (high value)'
    WHEN r_score <= 2 AND f_score BETWEEN 2 AND 3       THEN 'At-Risk'
    WHEN r_score = 1  AND f_score = 1                   THEN 'Lost'
    ELSE 'Needs Attention'
  END AS segment
FROM scored;

-- Segment summary: size, revenue share, profit share, recency
-- Decision: loyalty rewards (Champions), win-back (At-Risk), onboarding (New), suppress (Lost).
SELECT segment, COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)        AS pct_customers,
       ROUND(SUM(monetary), 0)                                    AS revenue,
       ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_revenue,
       ROUND(100.0 * SUM(profit)   / SUM(SUM(profit))   OVER (), 1) AS pct_profit,
       ROUND(AVG(recency_days), 0)                                AS avg_recency_days,
       ROUND(AVG(frequency), 2)                                   AS avg_orders
FROM clean.v_rfm GROUP BY segment ORDER BY revenue DESC;

-- Validation: segment sizes by score combination (watch for one segment swallowing the base)
SELECT r_score, f_score, COUNT(*) FROM clean.v_rfm GROUP BY 1, 2 ORDER BY 1 DESC, 2 DESC;

-- ---------------------------------------------------------------------
-- 6. CUSTOMER GROUPS: highest value, high frequency, high spend, at-risk high value, low value
-- ---------------------------------------------------------------------
WITH c AS (
  SELECT customer_id, COUNT(*) AS orders, SUM(net_revenue) AS revenue, SUM(gross_profit) AS profit,
         MAX(order_date) AS last_order, SUM(net_revenue) / COUNT(*) AS aov
  FROM clean.v_orders_net GROUP BY customer_id
),
lim AS (
  SELECT (SELECT MAX(order_date) FROM clean.v_orders_net) AS as_of,
         percentile_cont(0.90) WITHIN GROUP (ORDER BY profit) AS p90_profit,
         percentile_cont(0.90) WITHIN GROUP (ORDER BY orders) AS p90_orders,
         percentile_cont(0.90) WITHIN GROUP (ORDER BY aov)    AS p90_aov,
         percentile_cont(0.25) WITHIN GROUP (ORDER BY profit) AS p25_profit
  FROM c
),
flagged AS (
  SELECT c.*, l.as_of - c.last_order AS days_inactive,
         c.profit >= l.p90_profit                                            AS highest_value,
         c.orders >= l.p90_orders                                            AS high_frequency,
         c.aov    >= l.p90_aov                                               AS high_spend_per_order,
         (c.profit >= l.p90_profit AND l.as_of - c.last_order > 90)          AS at_risk_high_value,
         c.profit <= l.p25_profit                                            AS low_value
  FROM c CROSS JOIN lim l
)
SELECT COUNT(*) FILTER (WHERE highest_value)        AS highest_value_customers,
       COUNT(*) FILTER (WHERE high_frequency)       AS high_frequency_customers,
       COUNT(*) FILTER (WHERE high_spend_per_order) AS high_spend_customers,
       COUNT(*) FILTER (WHERE at_risk_high_value)   AS at_risk_high_value_customers,
       ROUND(SUM(profit) FILTER (WHERE at_risk_high_value)) AS profit_at_risk_historical,
       COUNT(*) FILTER (WHERE low_value)            AS low_value_customers
FROM flagged;

-- Priority win-back list: at-risk high-value customers, biggest profit first
-- (swap the final SELECT to export the list for the CRM team)
WITH c AS (
  SELECT customer_id, COUNT(*) AS orders, SUM(gross_profit) AS profit, MAX(order_date) AS last_order
  FROM clean.v_orders_net GROUP BY customer_id
),
lim AS (SELECT (SELECT MAX(order_date) FROM clean.v_orders_net) AS as_of,
               percentile_cont(0.90) WITHIN GROUP (ORDER BY profit) AS p90_profit FROM c)
SELECT c.customer_id, cu.first_name, cu.region, m.channel_name, c.orders,
       ROUND(c.profit) AS lifetime_profit, c.last_order, l.as_of - c.last_order AS days_inactive
FROM c CROSS JOIN lim l
JOIN clean.customers cu USING (customer_id)
JOIN clean.marketing_channels m ON m.channel_id = cu.channel_id
WHERE c.profit >= l.p90_profit AND l.as_of - c.last_order > 90
ORDER BY c.profit DESC
LIMIT 25;

-- ---------------------------------------------------------------------
-- 7. CUSTOMER CONCENTRATION (Pareto on customers)
-- Question: what share of customers produces 80% of profit?
-- ---------------------------------------------------------------------
WITH c AS (SELECT customer_id, SUM(gross_profit) AS profit FROM clean.v_orders_net GROUP BY customer_id),
ranked AS (
  SELECT customer_id, profit,
         SUM(profit) OVER (ORDER BY profit DESC) AS cum_profit,
         SUM(profit) OVER ()                     AS total_profit,
         ROW_NUMBER() OVER (ORDER BY profit DESC) AS rn,
         COUNT(*) OVER ()                         AS n
  FROM c
)
SELECT MAX(rn) FILTER (WHERE cum_profit / total_profit <= 0.8)  AS customers_for_80pct_profit,
       n                                                          AS total_customers,
       ROUND(100.0 * MAX(rn) FILTER (WHERE cum_profit / total_profit <= 0.8) / n, 1) AS pct_of_customers
FROM ranked GROUP BY n;

-- ---------------------------------------------------------------------
-- 8. REVENUE RANK vs PROFIT RANK per customer (who looks valuable but is not?)
-- ---------------------------------------------------------------------
WITH c AS (
  SELECT customer_id, SUM(net_revenue) AS revenue, SUM(gross_profit) AS profit
  FROM clean.v_orders_net GROUP BY customer_id
),
r AS (
  SELECT *, RANK() OVER (ORDER BY revenue DESC) AS revenue_rank, RANK() OVER (ORDER BY profit DESC) AS profit_rank
  FROM c
)
SELECT customer_id, ROUND(revenue) AS revenue, ROUND(profit) AS profit, revenue_rank, profit_rank,
       profit_rank - revenue_rank AS rank_gap
FROM r WHERE revenue_rank <= 500
ORDER BY rank_gap DESC LIMIT 15;
