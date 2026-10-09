-- =====================================================================
-- data_quality.sql  |  PostgreSQL
-- Part A: profile the RAW data (read-only)        -> identify + validate each issue
-- Part B: build the CLEAN layer from RAW          -> handle each issue, log counts in clean.dq_log
-- Part C: reconciliation checks on CLEAN           -> prove the cleaning did not break anything
-- Run after schema.sql and load_raw.sql. Safe to re-run (clean tables are truncated first).
-- =====================================================================

-- =====================================================================
-- PART A. PROFILING (raw layer)
-- =====================================================================

-- A1. Missing customer information: null rate per column
SELECT COUNT(*) AS customers,
       ROUND(100.0 * COUNT(*) FILTER (WHERE email  IS NULL) / COUNT(*), 1) AS email_null_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE phone  IS NULL) / COUNT(*), 1) AS phone_null_pct,
       ROUND(100.0 * COUNT(*) FILTER (WHERE region IS NULL) / COUNT(*), 1) AS region_null_pct
FROM raw.customers;

-- A2. Duplicate customers: same normalized email under different customer_ids
SELECT lower(trim(email)) AS email_key, COUNT(*) AS ids, array_agg(customer_id ORDER BY customer_id::int) AS customer_ids
FROM raw.customers
WHERE email IS NOT NULL
GROUP BY 1 HAVING COUNT(*) > 1
ORDER BY ids DESC, email_key
LIMIT 20;

-- A3. Duplicate transactions: identical order rows repeated
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT order_id) AS distinct_orders,
       COUNT(*) - COUNT(DISTINCT order_id) AS duplicate_rows
FROM raw.orders;

-- A4. Missing product information
SELECT COUNT(*) FILTER (WHERE category_id IS NULL) AS null_category,
       COUNT(*) FILTER (WHERE unit_cost   IS NULL) AS null_cost
FROM raw.products;

-- A5. Invalid dates (unparseable, impossible, or in the future)
SELECT COUNT(*) FILTER (WHERE order_date LIKE '1900-%')                     AS placeholder_1900,
       COUNT(*) FILTER (WHERE order_date ~ '^\d{4}-' AND order_date::timestamp > now()) AS future_dates,
       COUNT(*) FILTER (WHERE order_date ~ '^\d{2}-\d{2}-\d{4}')            AS day_first_format
FROM raw.orders;

-- A6. Incorrect data types: prices stored as text with currency symbols / commas
SELECT COUNT(*) FILTER (WHERE unit_price !~ '^-?[0-9]+(\.[0-9]+)?$') AS non_numeric_prices,
       MIN(unit_price) FILTER (WHERE unit_price !~ '^-?[0-9]+(\.[0-9]+)?$') AS example
FROM raw.order_items;

-- A7. Inconsistent category names: several raw ids collapse to one normalized name
SELECT regexp_replace(lower(category_name), '[^a-z]', '', 'g') AS name_key,
       COUNT(*) AS raw_variants, array_agg(category_name ORDER BY category_id::int) AS spellings
FROM raw.categories
GROUP BY 1 HAVING COUNT(*) > 1;

-- A8. Inconsistent country / region labels
SELECT country, COUNT(*) FROM raw.customers GROUP BY country ORDER BY COUNT(*) DESC;
SELECT region,  COUNT(*) FROM raw.customers GROUP BY region  ORDER BY COUNT(*) DESC;

-- A9. Negative or unrealistic values
SELECT COUNT(*) FILTER (WHERE quantity ~ '^-?[0-9]+$' AND quantity::int <= 0)                       AS non_positive_qty,
       COUNT(*) FILTER (WHERE regexp_replace(unit_price, '[^0-9.\-]', '', 'g') IN ('0', '0.00'))     AS zero_price
FROM raw.order_items;

-- A10. Order status values (cancelled / returned / refunded) and their spelling variants
SELECT order_status, COUNT(*) FROM raw.orders GROUP BY 1 ORDER BY 2 DESC;

-- A11. Outliers: heaviest quantities (inspect before deciding)
SELECT quantity::int AS qty, COUNT(*) FROM raw.order_items
WHERE quantity ~ '^-?[0-9]+$' GROUP BY 1 ORDER BY 1 DESC LIMIT 10;

-- =====================================================================
-- PART B. CLEANING (raw -> clean)
-- =====================================================================

-- ---------- helper functions ----------
CREATE OR REPLACE FUNCTION clean.to_num(t TEXT) RETURNS NUMERIC AS $$
  SELECT NULLIF(regexp_replace(t, '[^0-9.\-]', '', 'g'), '')::numeric
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION clean.to_ts(t TEXT) RETURNS TIMESTAMP AS $$
BEGIN
  IF t IS NULL THEN RETURN NULL; END IF;
  IF t ~ '^\d{4}-\d{2}-\d{2}' THEN RETURN t::timestamp;
  ELSIF t ~ '^\d{2}-\d{2}-\d{4}' THEN
    RETURN to_date(split_part(t, ' ', 1), 'DD-MM-YYYY')
           + COALESCE(NULLIF(split_part(t, ' ', 2), '')::time, TIME '00:00');
  END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN
  RETURN NULL;   -- impossible dates (e.g. month 13) become NULL and are excluded + logged
END $$ LANGUAGE plpgsql IMMUTABLE;

-- ---------- reference maps for inconsistent labels ----------
DROP TABLE IF EXISTS clean.region_map, clean.country_map;
CREATE TABLE clean.region_map (raw_key TEXT PRIMARY KEY, region_std TEXT);
INSERT INTO clean.region_map VALUES
  ('maharashtra','Maharashtra'),('maharastra','Maharashtra'),('mh','Maharashtra'),
  ('ka','Karnataka'),('karnataka','Karnataka'),
  ('tamil nadu','Tamil Nadu'),('tamilnadu','Tamil Nadu'),('tn','Tamil Nadu'),
  ('delhi','Delhi'),('dl','Delhi'),('new delhi','Delhi'),
  ('telangana','Telangana'),('telengana','Telangana'),('ts','Telangana'),
  ('gj','Gujarat'),('gujarat','Gujarat'),
  ('wb','West Bengal'),('west bengal','West Bengal'),
  ('up','Uttar Pradesh'),('uttar pradesh','Uttar Pradesh'),
  ('kerala','Kerala'),('kl','Kerala'),
  ('rajasthan','Rajasthan'),('rj','Rajasthan'),
  ('pb','Punjab'),('punjab','Punjab'),
  ('as','Assam'),('assam','Assam'),
  ('dubai','Dubai'),('dxb','Dubai'),
  ('sg','Singapore'),('singapore','Singapore');

CREATE TABLE clean.country_map (raw_key TEXT PRIMARY KEY, country_std TEXT);
INSERT INTO clean.country_map VALUES
  ('bharat','India'),('in','India'),('india','India'),
  ('ae','UAE'),('u.a.e','UAE'),('uae','UAE'),('united arab emirates','UAE'),
  ('sg','Singapore'),('singapore','Singapore');

-- ---------- start fresh ----------
TRUNCATE clean.payments, clean.order_items, clean.orders, clean.customers, clean.products,
         clean.categories, clean.marketing_channels, clean.dq_log RESTART IDENTITY CASCADE;
DROP TABLE IF EXISTS clean.customer_master, clean.category_map;

-- ---------- 1. marketing_channels ----------
INSERT INTO clean.marketing_channels
SELECT channel_id::int, trim(channel_name), trim(channel_type), clean.to_num(monthly_spend)
FROM raw.marketing_channels;

-- ---------- 2. categories: collapse spelling variants to one canonical id ----------
CREATE TABLE clean.category_map AS
SELECT category_id::int AS raw_id,
       MIN(category_id::int) OVER (PARTITION BY regexp_replace(lower(category_name), '[^a-z]', '', 'g')) AS canonical_id
FROM raw.categories;

INSERT INTO clean.categories
SELECT r.category_id::int, trim(regexp_replace(r.category_name, '\s+', ' ', 'g')), trim(r.parent_category)
FROM raw.categories r
JOIN clean.category_map m ON m.raw_id = r.category_id::int AND m.raw_id = m.canonical_id;
INSERT INTO clean.categories VALUES (0, 'Uncategorized', 'Unknown');

INSERT INTO clean.dq_log(table_name, issue, rows_affected, action_taken)
SELECT 'categories', 'Inconsistent category names', COUNT(*) FILTER (WHERE raw_id <> canonical_id),
       'Mapped spelling variants to the lowest id per normalized name (clean.category_map)'
FROM clean.category_map;

-- ---------- 3. products: missing category / cost ----------
WITH ratio AS (   -- typical cost-to-price ratio per canonical category (median), used only for missing costs
  SELECT m.canonical_id AS category_id,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY clean.to_num(p.unit_cost) / NULLIF(clean.to_num(p.list_price), 0)) AS med_ratio
  FROM raw.products p JOIN clean.category_map m ON m.raw_id = p.category_id::int
  WHERE p.unit_cost IS NOT NULL
  GROUP BY m.canonical_id
)
INSERT INTO clean.products (product_id, product_name, category_id, brand, unit_cost, list_price, launch_date, cost_imputed)
SELECT p.product_id::int, trim(p.product_name), COALESCE(m.canonical_id, 0), trim(p.brand),
       COALESCE(clean.to_num(p.unit_cost), ROUND((clean.to_num(p.list_price) * COALESCE(r.med_ratio, 0.55))::numeric, 2)),
       clean.to_num(p.list_price), p.launch_date::date,
       p.unit_cost IS NULL
FROM raw.products p
LEFT JOIN clean.category_map m ON m.raw_id = p.category_id::int
LEFT JOIN ratio r ON r.category_id = m.canonical_id;

INSERT INTO clean.dq_log(table_name, issue, rows_affected, action_taken)
SELECT 'products', 'Missing category', COUNT(*) FILTER (WHERE category_id IS NULL), 'Assigned to category 0 (Uncategorized)' FROM raw.products
UNION ALL
SELECT 'products', 'Missing unit_cost', COUNT(*) FILTER (WHERE unit_cost IS NULL),
       'Imputed from category median cost/price ratio; flagged cost_imputed = TRUE' FROM raw.products;

-- ---------- 4. customers: de-duplicate on normalized email, standardize labels ----------
CREATE TABLE clean.customer_master AS
SELECT customer_id::int AS customer_id,
       CASE WHEN email IS NULL THEN customer_id::int
            ELSE MIN(customer_id::int) OVER (PARTITION BY lower(trim(email))) END AS master_id
FROM raw.customers;

INSERT INTO clean.customers
SELECT c.customer_id::int, initcap(trim(c.first_name)), lower(trim(c.email)), c.phone,
       clean.to_ts(c.signup_date)::date,
       COALESCE(cm.country_std, trim(c.country)),
       rm.region_std,                                  -- NULL stays NULL here; back-filled from orders below
       trim(c.city), c.channel_id::int, c.gender, c.email IS NOT NULL
FROM raw.customers c
JOIN clean.customer_master m ON m.customer_id = c.customer_id::int AND m.customer_id = m.master_id
LEFT JOIN clean.country_map cm ON cm.raw_key = lower(trim(c.country))
LEFT JOIN clean.region_map  rm ON rm.raw_key = lower(trim(c.region));

INSERT INTO clean.dq_log(table_name, issue, rows_affected, action_taken)
SELECT 'customers', 'Duplicate customers (same email, different id)', COUNT(*) FILTER (WHERE customer_id <> master_id),
       'Mapped to earliest id via clean.customer_master; only master rows kept' FROM clean.customer_master
UNION ALL SELECT 'customers', 'Missing email', COUNT(*) FILTER (WHERE email IS NULL), 'Kept; has_email = FALSE' FROM raw.customers
UNION ALL SELECT 'customers', 'Missing phone', COUNT(*) FILTER (WHERE phone IS NULL), 'Kept as NULL' FROM raw.customers
UNION ALL SELECT 'customers', 'Missing region', COUNT(*) FILTER (WHERE region IS NULL), 'Back-filled from latest order delivery_region where possible' FROM raw.customers
UNION ALL SELECT 'customers', 'Inconsistent country labels',
       COUNT(*) FILTER (WHERE lower(trim(country)) NOT IN ('india','uae','singapore')), 'Standardized via clean.country_map' FROM raw.customers
UNION ALL SELECT 'customers', 'Inconsistent region labels',
       COUNT(*) FILTER (WHERE region IS NOT NULL AND region <> (SELECT region_std FROM clean.region_map x WHERE x.raw_key = lower(trim(region)))),
       'Standardized via clean.region_map' FROM raw.customers;

-- ---------- 5. orders ----------
WITH dedup AS (   -- duplicate transactions: identical rows repeated -> keep one per order_id
  SELECT DISTINCT ON (order_id) *
  FROM raw.orders ORDER BY order_id
),
parsed AS (
  SELECT d.order_id::bigint AS order_id, cm.master_id AS customer_id, clean.to_ts(d.order_date) AS order_date,
         initcap(trim(d.order_status)) AS order_status,
         COALESCE(clean.to_num(d.shipping_fee), 0) AS shipping_fee,
         COALESCE(clean.to_num(d.shipping_cost), 0) AS shipping_cost,
         COALESCE(clean.to_num(d.order_discount), 0) AS order_discount,
         COALESCE(rm.region_std, trim(d.delivery_region)) AS delivery_region
  FROM dedup d
  JOIN clean.customer_master cm ON cm.customer_id = d.customer_id::int
  LEFT JOIN clean.region_map rm ON rm.raw_key = lower(trim(d.delivery_region))
)
INSERT INTO clean.orders
SELECT * FROM parsed
WHERE order_date BETWEEN TIMESTAMP '2022-01-01' AND now()      -- drops NULL, 1900 placeholder and future dates
  AND customer_id IN (SELECT customer_id FROM clean.customers);

INSERT INTO clean.dq_log(table_name, issue, rows_affected, action_taken)
SELECT 'orders', 'Duplicate transactions (repeated order rows)', COUNT(*) - COUNT(DISTINCT order_id),
       'Kept one row per order_id (DISTINCT ON); matching duplicate item rows removed too' FROM raw.orders
UNION ALL
SELECT 'orders', 'Invalid dates (unparseable, 1900 placeholder, future)',
       (SELECT COUNT(DISTINCT order_id) FROM raw.orders) - (SELECT COUNT(*) FROM clean.orders),
       'Excluded from clean layer (cannot be placed in time); orders and their items/payments dropped' ;

-- back-fill missing customer region from the most recent delivery region
WITH last_region AS (
  SELECT DISTINCT ON (customer_id) customer_id, delivery_region
  FROM clean.orders ORDER BY customer_id, order_date DESC
)
UPDATE clean.customers c SET region = l.delivery_region
FROM last_region l WHERE l.customer_id = c.customer_id AND c.region IS NULL;

-- ---------- 6. order_items ----------
WITH dedup AS (
  SELECT DISTINCT ON (order_item_id) * FROM raw.order_items ORDER BY order_item_id
),
parsed AS (
  SELECT d.order_item_id::bigint AS order_item_id, d.order_id::bigint AS order_id, d.product_id::int AS product_id,
         clean.to_num(d.quantity)::int AS quantity, clean.to_num(d.unit_price) AS unit_price,
         COALESCE(clean.to_num(d.line_discount), 0) AS line_discount,
         lower(trim(d.is_returned)) IN ('true','t','1','y','yes') AS is_returned
  FROM dedup d
)
INSERT INTO clean.order_items (order_item_id, order_id, product_id, quantity, unit_price, line_discount, is_returned, is_outlier)
SELECT p.order_item_id, p.order_id, p.product_id, p.quantity, p.unit_price, p.line_discount, p.is_returned,
       p.quantity >= 50                                      -- bulk orders flagged, not removed
FROM parsed p
WHERE p.quantity > 0 AND p.unit_price > 0                    -- negative / zero values are data errors here
  AND p.order_id   IN (SELECT order_id   FROM clean.orders)
  AND p.product_id IN (SELECT product_id FROM clean.products);

INSERT INTO clean.dq_log(table_name, issue, rows_affected, action_taken)
SELECT 'order_items', 'Prices stored as text with currency symbol / commas',
       COUNT(*) FILTER (WHERE unit_price !~ '^-?[0-9]+(\.[0-9]+)?$'), 'Stripped symbols and cast to NUMERIC' FROM raw.order_items
UNION ALL SELECT 'order_items', 'Negative or zero quantity / zero price',
       COUNT(*) FILTER (WHERE clean.to_num(quantity) <= 0 OR clean.to_num(unit_price) <= 0), 'Excluded (treated as errors, not refunds; refunds live in payments/is_returned)' FROM raw.order_items
UNION ALL SELECT 'order_items', 'Outliers (quantity >= 50)', COUNT(*) FILTER (WHERE is_outlier), 'Kept and flagged is_outlier = TRUE; report metrics with and without' FROM clean.order_items;

-- ---------- 7. payments ----------
INSERT INTO clean.payments
SELECT DISTINCT ON (payment_id) payment_id::bigint, order_id::bigint, trim(payment_method), initcap(trim(payment_status)),
       clean.to_num(amount), clean.to_ts(payment_date)
FROM raw.payments
WHERE order_id::bigint IN (SELECT order_id FROM clean.orders)
ORDER BY payment_id;

INSERT INTO clean.dq_log(table_name, issue, rows_affected, action_taken)
SELECT 'orders', 'Cancelled orders', COUNT(*) FILTER (WHERE order_status = 'Cancelled'),
       'Kept in clean.orders; excluded from revenue/profit in views; used for cancellation rate' FROM clean.orders
UNION ALL
SELECT 'orders', 'Returned / Refunded orders', COUNT(*) FILTER (WHERE order_status IN ('Returned','Refunded')),
       'Kept; excluded from net revenue, included in return-rate analysis' FROM clean.orders;

ANALYZE;

SELECT * FROM clean.dq_log ORDER BY log_id;

-- =====================================================================
-- PART C. VALIDATION / RECONCILIATION (every check should be explainable)
-- =====================================================================

-- C1. Row counts raw vs clean, with the difference explained by dq_log
SELECT 'orders' AS tbl, (SELECT COUNT(*) FROM raw.orders) AS raw_rows, (SELECT COUNT(*) FROM clean.orders) AS clean_rows UNION ALL
SELECT 'order_items', (SELECT COUNT(*) FROM raw.order_items), (SELECT COUNT(*) FROM clean.order_items) UNION ALL
SELECT 'customers',   (SELECT COUNT(*) FROM raw.customers),   (SELECT COUNT(*) FROM clean.customers)   UNION ALL
SELECT 'payments',    (SELECT COUNT(*) FROM raw.payments),    (SELECT COUNT(*) FROM clean.payments);

-- C2. Orphan foreign keys (expect 0 rows each)
SELECT 'orders without customer' AS check_name, COUNT(*) AS violations FROM clean.orders o
  LEFT JOIN clean.customers c USING (customer_id) WHERE c.customer_id IS NULL
UNION ALL SELECT 'items without order', COUNT(*) FROM clean.order_items i
  LEFT JOIN clean.orders o USING (order_id) WHERE o.order_id IS NULL
UNION ALL SELECT 'items without product', COUNT(*) FROM clean.order_items i
  LEFT JOIN clean.products p USING (product_id) WHERE p.product_id IS NULL
UNION ALL SELECT 'products without category', COUNT(*) FROM clean.products p
  LEFT JOIN clean.categories c USING (category_id) WHERE c.category_id IS NULL
UNION ALL SELECT 'customers without channel', COUNT(*) FROM clean.customers c
  LEFT JOIN clean.marketing_channels m USING (channel_id) WHERE m.channel_id IS NULL;

-- C3. Orders with no remaining items (caused by excluded bad lines) -- investigate if the share is not tiny
SELECT COUNT(*) AS orders_without_items,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM clean.orders), 2) AS pct_of_orders
FROM clean.orders o WHERE NOT EXISTS (SELECT 1 FROM clean.order_items i WHERE i.order_id = o.order_id);

-- C4. Payments vs item totals for fully-kept, completed orders (tolerance 1 rupee)
WITH calc AS (
  SELECT o.order_id, SUM(i.quantity * i.unit_price - i.line_discount) - o.order_discount + o.shipping_fee AS expected
  FROM clean.orders o JOIN clean.order_items i USING (order_id)
  WHERE o.order_status = 'Completed'
  GROUP BY o.order_id, o.order_discount, o.shipping_fee
)
SELECT COUNT(*) AS orders_compared,
       COUNT(*) FILTER (WHERE abs(c.expected - p.amount) > 1) AS mismatches,
       ROUND(100.0 * COUNT(*) FILTER (WHERE abs(c.expected - p.amount) > 1) / COUNT(*), 2) AS mismatch_pct
FROM calc c JOIN clean.payments p ON p.order_id = c.order_id AND p.payment_status = 'Success';
-- Small mismatches are expected where bad item lines were excluded; large ones mean a cleaning bug.

-- C5. Distinct label counts after standardization (expect 14 regions, 3 countries, 30 categories + Uncategorized)
SELECT (SELECT COUNT(DISTINCT region)  FROM clean.customers) AS regions,
       (SELECT COUNT(DISTINCT country) FROM clean.customers) AS countries,
       (SELECT COUNT(*) FROM clean.categories)               AS categories_incl_uncategorized;

-- C6. Outlier review: top order values (decide: bulk/B2B vs error)
SELECT o.order_id, o.customer_id, o.order_date::date,
       ROUND(SUM(i.quantity * i.unit_price - i.line_discount), 0) AS order_value,
       BOOL_OR(i.is_outlier) AS has_flagged_line
FROM clean.orders o JOIN clean.order_items i USING (order_id)
GROUP BY o.order_id, o.customer_id, o.order_date
ORDER BY order_value DESC LIMIT 20;

-- =====================================================================
-- PART D. INDEXES (speed up joins used by every analysis file)
-- =====================================================================
CREATE INDEX IF NOT EXISTS ix_orders_customer_date ON clean.orders (customer_id, order_date);
CREATE INDEX IF NOT EXISTS ix_orders_status        ON clean.orders (order_status);
CREATE INDEX IF NOT EXISTS ix_items_order          ON clean.order_items (order_id);
CREATE INDEX IF NOT EXISTS ix_items_product        ON clean.order_items (product_id);
CREATE INDEX IF NOT EXISTS ix_customers_channel    ON clean.customers (channel_id);
CREATE INDEX IF NOT EXISTS ix_payments_order       ON clean.payments (order_id);
ANALYZE;
