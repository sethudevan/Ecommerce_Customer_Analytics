-- =====================================================================
-- kpi_analysis.sql  |  PostgreSQL
-- Foundation views + headline KPIs, trends, growth, basket economics,
-- and region / channel performance.
-- Definitions (state these in interviews):
--   Net revenue  = item revenue (qty*unit_price - line_discount) - order discount, for COMPLETED orders,
--                  excluding returned lines. Cancelled orders are excluded everywhere.
--   COGS         = quantity * unit_cost
--   Gross profit = net revenue - COGS + shipping_fee - shipping_cost
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. FOUNDATION VIEWS (one definition of revenue/profit for everything)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW clean.v_item_facts AS
SELECT oi.order_item_id, o.order_id, o.customer_id,
       o.order_date::date                       AS order_date,
       date_trunc('month', o.order_date)::date  AS order_month,
       o.order_status, o.delivery_region, c.channel_id,
       p.product_id, p.category_id, oi.quantity,
       oi.quantity * oi.unit_price - oi.line_discount AS line_revenue,
       oi.quantity * p.unit_cost                      AS line_cogs,
       oi.is_returned
FROM clean.order_items oi
JOIN clean.orders    o ON o.order_id    = oi.order_id
JOIN clean.customers c ON c.customer_id = o.customer_id
JOIN clean.products  p ON p.product_id  = oi.product_id
WHERE o.order_status <> 'Cancelled';

CREATE OR REPLACE VIEW clean.v_orders_net AS
SELECT o.order_id, o.customer_id, o.order_date::date AS order_date,
       date_trunc('month', o.order_date)::date AS order_month,
       o.delivery_region, c.channel_id,
       SUM(f.line_revenue) - o.order_discount                      AS net_revenue,
       SUM(f.line_cogs)                                            AS cogs,
       SUM(f.line_revenue) - o.order_discount - SUM(f.line_cogs)
         + o.shipping_fee - o.shipping_cost                        AS gross_profit
FROM clean.orders o
JOIN clean.customers c    ON c.customer_id = o.customer_id
JOIN clean.v_item_facts f ON f.order_id = o.order_id
WHERE o.order_status = 'Completed' AND NOT f.is_returned
GROUP BY o.order_id, o.customer_id, o.order_date, o.delivery_region,
         c.channel_id, o.order_discount, o.shipping_fee, o.shipping_cost;

-- Edge case worth knowing: if returned lines are removed but the order-level discount stays, a few orders end up
-- with ~0 or slightly negative net_revenue. They are kept on purpose (real discount leakage); the Python notebook
-- clips them to 0 only where a log transform needs it.

-- ---------------------------------------------------------------------
-- 1. HEADLINE KPI SUMMARY
-- Business question: What is the overall health of the business?
-- ---------------------------------------------------------------------
WITH n AS (SELECT * FROM clean.v_orders_net),
asof AS (SELECT MAX(order_date) AS d FROM n),
cust AS (SELECT customer_id, COUNT(*) AS orders FROM n GROUP BY customer_id)
SELECT ROUND(SUM(net_revenue))                                              AS total_revenue,
       ROUND(SUM(gross_profit))                                             AS gross_profit,
       ROUND(100.0 * SUM(gross_profit) / SUM(net_revenue), 1)               AS profit_margin_pct,
       COUNT(*)                                                             AS total_orders,
       ROUND(SUM(net_revenue) / COUNT(*))                                   AS aov,
       COUNT(DISTINCT customer_id)                                          AS total_customers,
       (SELECT COUNT(DISTINCT customer_id) FROM n, asof WHERE n.order_date > asof.d - 90) AS active_customers_90d,
       ROUND(100.0 * (SELECT COUNT(*) FROM cust WHERE orders >= 2) / (SELECT COUNT(*) FROM cust), 1) AS repeat_purchase_rate_pct,
       ROUND(SUM(net_revenue) / COUNT(DISTINCT customer_id))                AS revenue_per_customer
FROM n;

-- Cancellation and return rates (operational KPIs)
SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE order_status = 'Cancelled') / COUNT(*), 2)                   AS cancellation_rate_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE order_status IN ('Returned','Refunded')) / COUNT(*), 2)      AS fully_returned_order_pct
FROM clean.orders;

SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_returned) / COUNT(*), 2) AS line_return_rate_pct,
       ROUND(100.0 * SUM(line_revenue) FILTER (WHERE is_returned) / SUM(line_revenue), 2) AS return_rate_by_value_pct
FROM clean.v_item_facts;

-- ---------------------------------------------------------------------
-- 2. MONTHLY REVENUE, PROFIT, MARGIN, AOV
-- Decision: review discount calendar / pricing when revenue rises but margin falls.
-- ---------------------------------------------------------------------
SELECT order_month,
       COUNT(*)                                               AS orders,
       ROUND(SUM(net_revenue), 0)                             AS revenue,
       ROUND(SUM(gross_profit), 0)                            AS profit,
       ROUND(100.0 * SUM(gross_profit) / SUM(net_revenue), 1) AS margin_pct,
       ROUND(SUM(net_revenue) / COUNT(*), 0)                  AS aov
FROM clean.v_orders_net
GROUP BY order_month
ORDER BY order_month;

-- ---------------------------------------------------------------------
-- 3. GROWTH: MoM, YoY, YTD running total, 3-month moving average
-- Decision: set realistic targets; tell seasonality from structural growth.
-- ---------------------------------------------------------------------
WITH monthly AS (
  SELECT order_month, SUM(net_revenue) AS revenue, SUM(gross_profit) AS profit
  FROM clean.v_orders_net GROUP BY order_month
)
SELECT order_month,
       ROUND(revenue, 0) AS revenue,
       ROUND(100.0 * (revenue - LAG(revenue, 1)  OVER w) / NULLIF(LAG(revenue, 1)  OVER w, 0), 1) AS revenue_mom_pct,
       ROUND(100.0 * (revenue - LAG(revenue, 12) OVER w) / NULLIF(LAG(revenue, 12) OVER w, 0), 1) AS revenue_yoy_pct,
       ROUND(100.0 * (profit  - LAG(profit, 12)  OVER w) / NULLIF(LAG(profit, 12)  OVER w, 0), 1) AS profit_yoy_pct,
       ROUND(SUM(revenue) OVER (PARTITION BY date_part('year', order_month) ORDER BY order_month), 0) AS ytd_revenue,
       ROUND(AVG(revenue) OVER (ORDER BY order_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0)    AS moving_avg_3m
FROM monthly
WINDOW w AS (ORDER BY order_month)
ORDER BY order_month;

-- Yearly summary: did margin move with revenue?
SELECT date_part('year', order_month)::int AS year,
       ROUND(SUM(net_revenue)) AS revenue, ROUND(SUM(gross_profit)) AS profit,
       ROUND(100.0 * SUM(gross_profit) / SUM(net_revenue), 1) AS margin_pct,
       COUNT(*) AS orders, ROUND(SUM(net_revenue) / COUNT(*)) AS aov
FROM clean.v_orders_net GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 4. REVENUE DECOMPOSITION: new vs returning customers (what drove growth?)
-- ---------------------------------------------------------------------
WITH first_order AS (
  SELECT customer_id, MIN(order_date) AS first_date FROM clean.v_orders_net GROUP BY customer_id
)
SELECT date_part('year', o.order_month)::int AS year,
       ROUND(SUM(o.net_revenue) FILTER (WHERE o.order_date = f.first_date))  AS new_customer_revenue,
       ROUND(SUM(o.net_revenue) FILTER (WHERE o.order_date > f.first_date))  AS returning_customer_revenue,
       ROUND(100.0 * SUM(o.net_revenue) FILTER (WHERE o.order_date > f.first_date) / SUM(o.net_revenue), 1) AS returning_share_pct
FROM clean.v_orders_net o JOIN first_order f USING (customer_id)
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 5. BASKET SIZE BANDS (CASE WHEN): are small baskets profitable after shipping?
-- Decision: free-shipping threshold / small-order fee.
-- ---------------------------------------------------------------------
SELECT CASE WHEN net_revenue < 500  THEN '1. Under 500'
            WHEN net_revenue < 1500 THEN '2. 500-1,499'
            WHEN net_revenue < 3000 THEN '3. 1,500-2,999'
            ELSE '4. 3,000+' END                                AS basket_band,
       COUNT(*)                                                  AS orders,
       ROUND(100.0 * SUM(gross_profit) / SUM(net_revenue), 1)    AS margin_pct,
       COUNT(*) FILTER (WHERE gross_profit < 0)                  AS loss_making_orders,
       ROUND(100.0 * COUNT(*) FILTER (WHERE gross_profit < 0) / COUNT(*), 1) AS loss_making_pct
FROM clean.v_orders_net
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 6. REGIONAL PERFORMANCE
-- Business question: Which regions produce profit, which only produce revenue?
-- Decision: regional logistics review / expansion (Head of E-commerce, CFO).
-- ---------------------------------------------------------------------
WITH cust AS (
  SELECT delivery_region AS region, customer_id, COUNT(*) AS orders,
         SUM(net_revenue) AS revenue, SUM(gross_profit) AS profit
  FROM clean.v_orders_net GROUP BY delivery_region, customer_id
),
ship AS (   -- shipping cost as % of revenue by region, from completed orders
  SELECT o.delivery_region AS region, SUM(o.shipping_cost) AS shipping_cost, SUM(n.net_revenue) AS revenue
  FROM clean.orders o JOIN clean.v_orders_net n USING (order_id) GROUP BY o.delivery_region
)
SELECT c.region,
       COUNT(*)                                                     AS customers,
       ROUND(SUM(c.revenue), 0)                                     AS revenue,
       ROUND(SUM(c.profit), 0)                                      AS profit,
       ROUND(100.0 * SUM(c.profit) / SUM(c.revenue), 1)             AS margin_pct,
       ROUND(SUM(c.revenue) / SUM(c.orders), 0)                     AS aov,
       ROUND(100.0 * COUNT(*) FILTER (WHERE c.orders >= 2) / COUNT(*), 1) AS repeat_rate_pct,
       ROUND(SUM(c.profit) / COUNT(*), 0)                           AS profit_per_customer,
       ROUND(100.0 * s.shipping_cost / s.revenue, 1)                AS shipping_cost_pct_of_revenue
FROM cust c JOIN ship s USING (region)
GROUP BY c.region, s.shipping_cost, s.revenue
ORDER BY profit DESC;

-- ---------------------------------------------------------------------
-- 7. CHANNEL PERFORMANCE: volume, CAC, profit per customer, payback
-- Business question: Which acquisition channels pay back?
-- Decision: marketing budget reallocation (CMO). NOTE: spend x months is a shortcut that assumes flat
-- spend over the 36 months; use a spend-by-month table in a real project. Organic/Direct have spend = 0,
-- which flatters them (they also benefit from brand demand created by paid channels).
-- ---------------------------------------------------------------------
WITH new_cust AS (
  SELECT channel_id, COUNT(*) AS new_customers FROM clean.customers GROUP BY channel_id
),
buyers AS (
  SELECT channel_id, COUNT(DISTINCT customer_id) AS buyers,
         SUM(net_revenue) AS revenue, SUM(gross_profit) AS profit
  FROM clean.v_orders_net GROUP BY channel_id
),
months AS (
  SELECT (date_part('year', age(MAX(order_month), MIN(order_month))) * 12
          + date_part('month', age(MAX(order_month), MIN(order_month))) + 1)::numeric AS n FROM clean.v_orders_net
)
SELECT m.channel_name, m.channel_type, n.new_customers, b.buyers,
       ROUND(100.0 * b.buyers / n.new_customers, 1)                              AS conversion_to_buyer_pct,
       ROUND(m.monthly_spend * mo.n / n.new_customers, 0)                        AS cac,
       ROUND(b.revenue / b.buyers, 0)                                            AS revenue_per_buyer,
       ROUND(b.profit  / b.buyers, 0)                                            AS profit_per_buyer,
       ROUND(CASE WHEN m.monthly_spend > 0 THEN b.profit / (m.monthly_spend * mo.n) END, 2) AS profit_to_spend_ratio
FROM clean.marketing_channels m
JOIN new_cust n ON n.channel_id = m.channel_id
JOIN buyers   b ON b.channel_id = m.channel_id
CROSS JOIN months mo
ORDER BY profit_per_buyer DESC;

-- Channel first-order quality: discounting and margin of the FIRST order (are bargain hunters coming in?)
WITH first_o AS (
  SELECT DISTINCT ON (customer_id) customer_id, order_id, net_revenue, gross_profit
  FROM clean.v_orders_net ORDER BY customer_id, order_date, order_id
),
disc AS (
  SELECT f.order_id, SUM(i.line_discount) AS line_disc,
         SUM(i.quantity * p.list_price) AS list_value, SUM(i.quantity * i.unit_price) AS sold_value
  FROM first_o f JOIN clean.order_items i USING (order_id) JOIN clean.products p USING (product_id)
  GROUP BY f.order_id
)
SELECT m.channel_name, COUNT(*) AS first_orders,
       ROUND(AVG(f.net_revenue), 0) AS first_order_aov,
       ROUND(100.0 * SUM(f.gross_profit) / SUM(f.net_revenue), 1) AS first_order_margin_pct,
       ROUND(100.0 * (1 - SUM(d.sold_value) / SUM(d.list_value)), 1) AS avg_discount_vs_list_pct
FROM first_o f
JOIN disc d USING (order_id)
JOIN clean.customers c ON c.customer_id = f.customer_id
JOIN clean.marketing_channels m ON m.channel_id = c.channel_id
GROUP BY m.channel_name ORDER BY first_order_margin_pct;
