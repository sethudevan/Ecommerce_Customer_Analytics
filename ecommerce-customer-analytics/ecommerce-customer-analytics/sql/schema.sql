-- =====================================================================
-- schema.sql  |  PostgreSQL 13+
-- Creates two schemas:
--   raw   : everything stored as TEXT, exactly as delivered (messy)
--   clean : typed tables with keys, built by data_quality.sql
-- Run order: schema.sql -> load_raw.sql -> data_quality.sql -> kpi_analysis.sql
--            -> customer_analysis.sql -> product_analysis.sql -> retention_analysis.sql
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS clean;

-- ---------- RAW (all text; no constraints, duplicates allowed) ----------
DROP TABLE IF EXISTS raw.payments, raw.order_items, raw.orders, raw.customers,
                     raw.products, raw.categories, raw.marketing_channels CASCADE;

CREATE TABLE raw.marketing_channels (channel_id TEXT, channel_name TEXT, channel_type TEXT, monthly_spend TEXT);
CREATE TABLE raw.categories         (category_id TEXT, category_name TEXT, parent_category TEXT);
CREATE TABLE raw.products           (product_id TEXT, product_name TEXT, category_id TEXT, brand TEXT,
                                     unit_cost TEXT, list_price TEXT, launch_date TEXT);
CREATE TABLE raw.customers          (customer_id TEXT, first_name TEXT, email TEXT, phone TEXT, signup_date TEXT,
                                     country TEXT, region TEXT, city TEXT, channel_id TEXT, gender TEXT);
CREATE TABLE raw.orders             (order_id TEXT, customer_id TEXT, order_date TEXT, order_status TEXT,
                                     shipping_fee TEXT, shipping_cost TEXT, order_discount TEXT, delivery_region TEXT);
CREATE TABLE raw.order_items        (order_item_id TEXT, order_id TEXT, product_id TEXT, quantity TEXT,
                                     unit_price TEXT, line_discount TEXT, is_returned TEXT);
CREATE TABLE raw.payments           (payment_id TEXT, order_id TEXT, payment_method TEXT, payment_status TEXT,
                                     amount TEXT, payment_date TEXT);

-- ---------- CLEAN (typed, with keys) ----------
DROP TABLE IF EXISTS clean.payments, clean.order_items, clean.orders, clean.customers,
                     clean.products, clean.categories, clean.marketing_channels CASCADE;

CREATE TABLE clean.marketing_channels (
  channel_id    INT PRIMARY KEY,
  channel_name  VARCHAR(50) NOT NULL,
  channel_type  VARCHAR(20),
  monthly_spend NUMERIC(12,2)
);
CREATE TABLE clean.categories (
  category_id     INT PRIMARY KEY,
  category_name   VARCHAR(60) NOT NULL,
  parent_category VARCHAR(60)
);
CREATE TABLE clean.products (
  product_id    INT PRIMARY KEY,
  product_name  VARCHAR(120),
  category_id   INT REFERENCES clean.categories(category_id),
  brand         VARCHAR(50),
  unit_cost     NUMERIC(10,2),
  list_price    NUMERIC(10,2),
  launch_date   DATE,
  cost_imputed  BOOLEAN DEFAULT FALSE
);
CREATE TABLE clean.customers (
  customer_id  INT PRIMARY KEY,           -- master id after de-duplication
  first_name   VARCHAR(50),
  email        VARCHAR(120),
  phone        VARCHAR(20),
  signup_date  DATE,
  country      VARCHAR(40),
  region       VARCHAR(40),
  city         VARCHAR(50),
  channel_id   INT REFERENCES clean.marketing_channels(channel_id),
  gender       VARCHAR(10),
  has_email    BOOLEAN
);
CREATE TABLE clean.orders (
  order_id        BIGINT PRIMARY KEY,
  customer_id     INT REFERENCES clean.customers(customer_id),
  order_date      TIMESTAMP NOT NULL,
  order_status    VARCHAR(20),
  shipping_fee    NUMERIC(8,2),
  shipping_cost   NUMERIC(8,2),
  order_discount  NUMERIC(10,2),
  delivery_region VARCHAR(40)
);
CREATE TABLE clean.order_items (
  order_item_id BIGINT PRIMARY KEY,
  order_id      BIGINT REFERENCES clean.orders(order_id),
  product_id    INT REFERENCES clean.products(product_id),
  quantity      INT,
  unit_price    NUMERIC(10,2),
  line_discount NUMERIC(10,2),
  is_returned   BOOLEAN,
  is_outlier    BOOLEAN DEFAULT FALSE
);
CREATE TABLE clean.payments (
  payment_id     BIGINT PRIMARY KEY,
  order_id       BIGINT REFERENCES clean.orders(order_id),
  payment_method VARCHAR(20),
  payment_status VARCHAR(20),
  amount         NUMERIC(12,2),
  payment_date   TIMESTAMP
);

-- Data-quality audit log (filled by data_quality.sql)
DROP TABLE IF EXISTS clean.dq_log;
CREATE TABLE clean.dq_log (
  log_id        SERIAL PRIMARY KEY,
  logged_at     TIMESTAMP DEFAULT now(),
  table_name    TEXT,
  issue         TEXT,
  rows_affected BIGINT,
  action_taken  TEXT
);
