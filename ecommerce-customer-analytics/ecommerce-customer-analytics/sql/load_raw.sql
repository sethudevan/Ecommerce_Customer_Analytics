-- load_raw.sql  |  run from psql in the repo root:  psql -d ecommerce -f sql/load_raw.sql
-- \copy runs client-side, so paths are relative to where psql was started.
TRUNCATE raw.marketing_channels, raw.categories, raw.products, raw.customers,
         raw.orders, raw.order_items, raw.payments;

\copy raw.marketing_channels FROM 'data/raw/marketing_channels.csv' CSV HEADER
\copy raw.categories         FROM 'data/raw/categories.csv'         CSV HEADER
\copy raw.products           FROM 'data/raw/products.csv'           CSV HEADER
\copy raw.customers          FROM 'data/raw/customers.csv'          CSV HEADER
\copy raw.orders             FROM 'data/raw/orders.csv'             CSV HEADER
\copy raw.order_items        FROM 'data/raw/order_items.csv'        CSV HEADER
\copy raw.payments           FROM 'data/raw/payments.csv'           CSV HEADER

SELECT 'marketing_channels' AS table_name, COUNT(*) AS rows FROM raw.marketing_channels UNION ALL
SELECT 'categories',  COUNT(*) FROM raw.categories  UNION ALL
SELECT 'products',    COUNT(*) FROM raw.products    UNION ALL
SELECT 'customers',   COUNT(*) FROM raw.customers   UNION ALL
SELECT 'orders',      COUNT(*) FROM raw.orders      UNION ALL
SELECT 'order_items', COUNT(*) FROM raw.order_items UNION ALL
SELECT 'payments',    COUNT(*) FROM raw.payments;
