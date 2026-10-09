-- =====================================================================
-- product_analysis.sql  |  PostgreSQL
-- Needs the views from kpi_analysis.sql.
-- Category and product profitability, ranking, quadrant, returns, trends, Pareto, basket affinity.
-- Note: order-level discounts are NOT allocated to products, so product profit slightly overstates
-- profit for heavily discounted baskets (pro-rata allocation is a possible extension).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. CATEGORY PERFORMANCE AND PROFIT SHARE
-- Decision: where to invest, reprice or fix. Revenue share >> profit share = subsidised category.
-- ---------------------------------------------------------------------
SELECT cat.category_name,
       ROUND(SUM(f.line_revenue), 0)                                           AS revenue,
       ROUND(SUM(f.line_revenue) - SUM(f.line_cogs), 0)                        AS profit,
       ROUND(100.0 * (SUM(f.line_revenue) - SUM(f.line_cogs)) / SUM(f.line_revenue), 1) AS margin_pct,
       ROUND(100.0 * SUM(f.line_revenue) / SUM(SUM(f.line_revenue)) OVER (), 1)         AS revenue_share_pct,
       ROUND(100.0 * (SUM(f.line_revenue) - SUM(f.line_cogs))
             / SUM(SUM(f.line_revenue) - SUM(f.line_cogs)) OVER (), 1)                  AS profit_share_pct
FROM clean.v_item_facts f
JOIN clean.categories cat USING (category_id)
WHERE f.order_status = 'Completed' AND NOT f.is_returned
GROUP BY cat.category_name
ORDER BY profit DESC;

-- Low-margin categories with real volume (WHERE vs HAVING)
SELECT cat.category_name,
       ROUND(SUM(f.line_revenue), 0) AS revenue,
       ROUND(100.0 * (SUM(f.line_revenue) - SUM(f.line_cogs)) / SUM(f.line_revenue), 1) AS margin_pct
FROM clean.v_item_facts f JOIN clean.categories cat USING (category_id)
WHERE f.order_status = 'Completed' AND NOT f.is_returned
GROUP BY cat.category_name
HAVING SUM(f.line_revenue) > 5000000
   AND 100.0 * (SUM(f.line_revenue) - SUM(f.line_cogs)) / SUM(f.line_revenue) < 30
ORDER BY revenue DESC;

-- ---------------------------------------------------------------------
-- 2. PRODUCT RANKING (RANK / DENSE_RANK / ROW_NUMBER)
-- A big gap between revenue_rank and profit_rank = sells a lot, earns little.
-- ---------------------------------------------------------------------
WITH prod AS (
  SELECT f.product_id, p.product_name, cat.category_name,
         SUM(f.quantity) AS units, SUM(f.line_revenue) AS revenue,
         SUM(f.line_revenue) - SUM(f.line_cogs) AS profit
  FROM clean.v_item_facts f
  JOIN clean.products   p   ON p.product_id = f.product_id
  JOIN clean.categories cat ON cat.category_id = p.category_id
  WHERE f.order_status = 'Completed' AND NOT f.is_returned
  GROUP BY f.product_id, p.product_name, cat.category_name
)
SELECT product_id, product_name, category_name, units, ROUND(revenue) AS revenue, ROUND(profit) AS profit,
       ROUND(100.0 * profit / revenue, 1)                                   AS margin_pct,
       RANK()       OVER (ORDER BY revenue DESC)                            AS revenue_rank,
       DENSE_RANK() OVER (ORDER BY profit  DESC)                            AS profit_rank,
       ROW_NUMBER() OVER (PARTITION BY category_name ORDER BY profit DESC)  AS rank_in_category
FROM prod
ORDER BY profit_rank
LIMIT 25;

-- Top 3 products per category (ROW_NUMBER inside a CTE)
WITH prod AS (
  SELECT p.category_id, f.product_id, SUM(f.line_revenue) - SUM(f.line_cogs) AS profit
  FROM clean.v_item_facts f JOIN clean.products p USING (product_id)
  WHERE f.order_status = 'Completed' AND NOT f.is_returned
  GROUP BY p.category_id, f.product_id
),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY profit DESC) AS rn FROM prod)
SELECT cat.category_name, r.product_id, ROUND(r.profit) AS profit, r.rn
FROM r JOIN clean.categories cat USING (category_id)
WHERE r.rn <= 3 ORDER BY cat.category_name, r.rn;

-- ---------------------------------------------------------------------
-- 3. VOLUME vs MARGIN QUADRANT
-- Decision: promote (high margin/low volume), reprice (high volume/low margin), review dogs.
-- ---------------------------------------------------------------------
WITH p AS (
  SELECT f.product_id, SUM(f.quantity) AS units, SUM(f.line_revenue) AS revenue,
         SUM(f.line_revenue) - SUM(f.line_cogs) AS profit,
         100.0 * (SUM(f.line_revenue) - SUM(f.line_cogs)) / NULLIF(SUM(f.line_revenue), 0) AS margin_pct
  FROM clean.v_item_facts f
  WHERE f.order_status = 'Completed' AND NOT f.is_returned
  GROUP BY f.product_id HAVING SUM(f.quantity) >= 20
),
q AS (SELECT *, NTILE(4) OVER (ORDER BY units) AS vol_q, NTILE(4) OVER (ORDER BY margin_pct) AS margin_q FROM p)
SELECT CASE WHEN vol_q = 4 AND margin_q = 1 THEN 'High volume / low margin'
            WHEN vol_q = 1 AND margin_q = 4 THEN 'High margin / low volume'
            WHEN vol_q = 4 AND margin_q = 4 THEN 'Stars'
            WHEN vol_q = 1 AND margin_q = 1 THEN 'Dogs'
            ELSE 'Core' END AS quadrant,
       COUNT(*) AS products, ROUND(SUM(revenue)) AS revenue, ROUND(SUM(profit)) AS profit,
       ROUND(AVG(margin_pct), 1) AS avg_margin_pct
FROM q GROUP BY 1 ORDER BY revenue DESC;

-- ---------------------------------------------------------------------
-- 4. RETURNS: category and product level (profit leakage)
-- ---------------------------------------------------------------------
SELECT cat.category_name, COUNT(*) AS lines,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_returned) / COUNT(*), 1) AS return_rate_pct,
       ROUND(SUM(f.line_revenue) FILTER (WHERE f.is_returned), 0)        AS returned_revenue,
       ROUND(SUM(f.line_revenue - f.line_cogs) FILTER (WHERE f.is_returned), 0) AS profit_lost
FROM clean.v_item_facts f JOIN clean.categories cat USING (category_id)
GROUP BY cat.category_name ORDER BY return_rate_pct DESC;

-- Products with high return rates (min 100 lines to avoid tiny-sample extremes)
SELECT f.product_id, p.product_name, COUNT(*) AS lines,
       ROUND(100.0 * COUNT(*) FILTER (WHERE f.is_returned) / COUNT(*), 1) AS return_rate_pct
FROM clean.v_item_facts f JOIN clean.products p USING (product_id)
GROUP BY f.product_id, p.product_name HAVING COUNT(*) >= 100
ORDER BY return_rate_pct DESC LIMIT 20;

-- ---------------------------------------------------------------------
-- 5. PROFITABILITY TRENDS BY CATEGORY (YoY margin change, 3-month average)
-- ---------------------------------------------------------------------
WITH m AS (
  SELECT cat.category_name, f.order_month,
         SUM(f.line_revenue) - SUM(f.line_cogs) AS profit,
         100.0 * (SUM(f.line_revenue) - SUM(f.line_cogs)) / SUM(f.line_revenue) AS margin_pct
  FROM clean.v_item_facts f JOIN clean.categories cat USING (category_id)
  WHERE f.order_status = 'Completed' AND NOT f.is_returned
  GROUP BY 1, 2
)
SELECT category_name, order_month, ROUND(profit) AS profit, ROUND(margin_pct, 1) AS margin_pct,
       ROUND(margin_pct - LAG(margin_pct, 12) OVER (PARTITION BY category_name ORDER BY order_month), 1) AS margin_change_yoy_pts,
       ROUND(AVG(margin_pct) OVER (PARTITION BY category_name ORDER BY order_month
                                   ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1)                      AS margin_3m_avg
FROM m
ORDER BY category_name, order_month
LIMIT 40;

-- Category margin by year: did the margin change inside categories, or because the mix shifted?
WITH y AS (
  SELECT cat.category_name, date_part('year', f.order_month)::int AS year,
         SUM(f.line_revenue) AS revenue, SUM(f.line_cogs) AS cogs
  FROM clean.v_item_facts f JOIN clean.categories cat USING (category_id)
  WHERE f.order_status = 'Completed' AND NOT f.is_returned
  GROUP BY 1, 2
)
SELECT category_name, year, ROUND(revenue) AS revenue,
       ROUND(100.0 * (revenue - cogs) / revenue, 1)                  AS margin_pct,
       ROUND(100.0 * revenue / SUM(revenue) OVER (PARTITION BY year), 1) AS revenue_share_in_year_pct
FROM y ORDER BY category_name, year;

-- Discount depth by month (how much below list price are we selling?)
SELECT f.order_month,
       ROUND(100.0 * (1 - SUM(i.quantity * i.unit_price) / SUM(i.quantity * p.list_price)), 1) AS avg_discount_vs_list_pct
FROM clean.v_item_facts f
JOIN clean.order_items i ON i.order_item_id = f.order_item_id
JOIN clean.products p    ON p.product_id = f.product_id
GROUP BY f.order_month ORDER BY f.order_month;

-- ---------------------------------------------------------------------
-- 6. PARETO (80/20) ON PRODUCT PROFIT
-- Decision: range rationalisation; products with negative profit are discontinuation candidates
-- (after the basket-affinity check below).
-- ---------------------------------------------------------------------
WITH prod AS (
  SELECT product_id, SUM(line_revenue) - SUM(line_cogs) AS profit
  FROM clean.v_item_facts WHERE order_status = 'Completed' AND NOT is_returned
  GROUP BY product_id
),
ranked AS (
  SELECT product_id, profit,
         SUM(profit) OVER (ORDER BY profit DESC)  AS cum_profit,
         SUM(profit) OVER ()                      AS total_profit,
         ROW_NUMBER() OVER (ORDER BY profit DESC) AS rn,
         COUNT(*) OVER ()                         AS n
  FROM prod
)
SELECT CASE WHEN cum_profit / total_profit <= 0.8  THEN 'A (top 80% of profit)'
            WHEN cum_profit / total_profit <= 0.95 THEN 'B (next 15%)'
            ELSE 'C (last 5%)' END AS pareto_class,
       COUNT(*) AS products,
       ROUND(100.0 * COUNT(*) / MAX(n), 1) AS pct_of_products,
       ROUND(SUM(profit)) AS profit,
       COUNT(*) FILTER (WHERE profit < 0) AS negative_profit_products
FROM ranked GROUP BY 1 ORDER BY 1;

-- Pareto at category level
WITH cat AS (
  SELECT category_id, SUM(line_revenue) - SUM(line_cogs) AS profit
  FROM clean.v_item_facts WHERE order_status = 'Completed' AND NOT is_returned GROUP BY category_id
)
SELECT c.category_name, ROUND(cat.profit) AS profit,
       ROUND(100.0 * SUM(cat.profit) OVER (ORDER BY cat.profit DESC) / SUM(cat.profit) OVER (), 1) AS cum_profit_pct
FROM cat JOIN clean.categories c USING (category_id) ORDER BY cat.profit DESC;

-- ---------------------------------------------------------------------
-- 7. ACTION LIST: promote / optimise / reprice / investigate / discontinue (rule-based starting point)
-- ---------------------------------------------------------------------
WITH s AS (
  SELECT f.product_id,
         SUM(f.quantity) AS units,
         SUM(f.line_revenue) FILTER (WHERE NOT f.is_returned) AS revenue,
         SUM(f.line_revenue - f.line_cogs) FILTER (WHERE NOT f.is_returned) AS profit,
         100.0 * COUNT(*) FILTER (WHERE f.is_returned) / COUNT(*) AS return_rate_pct,
         COUNT(*) AS lines
  FROM clean.v_item_facts f WHERE f.order_status IN ('Completed','Returned','Refunded')
  GROUP BY f.product_id HAVING COUNT(*) >= 50
),
t AS (
  SELECT *, 100.0 * profit / NULLIF(revenue, 0) AS margin_pct,
         NTILE(4) OVER (ORDER BY units) AS vol_q, NTILE(4) OVER (ORDER BY 100.0 * profit / NULLIF(revenue, 0)) AS margin_q
  FROM s
)
SELECT CASE WHEN return_rate_pct >= 15                               THEN 'Investigate (returns)'
            WHEN profit < 0 OR (vol_q = 1 AND margin_q = 1)          THEN 'Review / potentially discontinue'
            WHEN vol_q >= 3 AND margin_q = 1                         THEN 'Reprice / cut discounts'
            WHEN vol_q <= 2 AND margin_q = 4                         THEN 'Promote'
            WHEN vol_q >= 3 AND margin_q >= 3                        THEN 'Protect / optimise cost'
            ELSE 'Maintain' END AS suggested_action,
       COUNT(*) AS products, ROUND(SUM(revenue)) AS revenue, ROUND(SUM(profit)) AS profit
FROM t GROUP BY 1 ORDER BY revenue DESC;

-- ---------------------------------------------------------------------
-- 8. BASKET AFFINITY CHECK before discontinuing a product
-- In psql:  \set product_id 1001   (otherwise replace :product_id with a literal id)
-- ---------------------------------------------------------------------
\set product_id 1001
SELECT :product_id AS product_id,
       COUNT(DISTINCT a.order_id)                                                            AS orders_with_product,
       COUNT(DISTINCT a.order_id) FILTER (WHERE EXISTS (
         SELECT 1 FROM clean.order_items b WHERE b.order_id = a.order_id AND b.product_id <> a.product_id)) AS orders_with_other_items,
       ROUND(AVG(o.net_revenue), 0)                                                          AS avg_basket_value
FROM clean.order_items a
JOIN clean.v_orders_net o ON o.order_id = a.order_id
WHERE a.product_id = :product_id;
