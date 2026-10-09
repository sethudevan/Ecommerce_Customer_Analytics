# Data Dictionary

Two schemas: **`raw`** (all columns TEXT, delivered messy) and **`clean`** (typed, keyed; built by `sql/data_quality.sql`).
Relationships: `marketing_channels 1-* customers 1-* orders 1-* order_items *-1 products *-1 categories`, and `orders 1-* payments`.

## clean.marketing_channels
| Column | Type | Key | Description | Example |
|---|---|---|---|---|
| channel_id | INT | PK | Channel identifier | 3 |
| channel_name | VARCHAR(50) | | Channel | Social Ads |
| channel_type | VARCHAR(20) | | Paid / Organic / Owned / Referral | Paid |
| monthly_spend | NUMERIC(12,2) | | Assumed flat monthly spend (INR) | 850000.00 |

## clean.categories
| Column | Type | Key | Description | Example |
|---|---|---|---|---|
| category_id | INT | PK | Canonical category id (0 = Uncategorized) | 4 |
| category_name | VARCHAR(60) | | Standardised name | Small Appliances |
| parent_category | VARCHAR(60) | | Parent group | Kitchen |

## clean.products
| Column | Type | Key | Description | Example |
|---|---|---|---|---|
| product_id | INT | PK | Product id | 1042 |
| product_name | VARCHAR(120) | | Name | Modern Cookware 1042 |
| category_id | INT | FK categories | Category (0 if missing in raw) | 1 |
| brand | VARCHAR(50) | | Brand | Kaveri Home |
| unit_cost | NUMERIC(10,2) | | Cost per unit (imputed if missing) | 640.00 |
| list_price | NUMERIC(10,2) | | Standard price | 1199.00 |
| launch_date | DATE | | Launch date | 2022-04-11 |
| cost_imputed | BOOLEAN | | TRUE if unit_cost was missing and imputed | false |

## clean.customers
| Column | Type | Key | Description | Example |
|---|---|---|---|---|
| customer_id | INT | PK | Master id after de-duplication | 10482 |
| first_name | VARCHAR(50) | | First name | Anita |
| email | VARCHAR(120) | | Lower-cased email, may be NULL | anita.482@example.com |
| phone | VARCHAR(20) | | Phone, may be NULL | 9876543210 |
| signup_date | DATE | | Registration date | 2023-04-17 |
| country | VARCHAR(40) | | Standardised country | India |
| region | VARCHAR(40) | | Standardised state / region (back-filled from orders) | Karnataka |
| city | VARCHAR(50) | | City | Hosur |
| channel_id | INT | FK marketing_channels | Acquisition channel | 3 |
| gender | VARCHAR(10) | | F / M / O | F |
| has_email | BOOLEAN | | Whether an email existed in raw | true |

## clean.orders
| Column | Type | Key | Description | Example |
|---|---|---|---|---|
| order_id | BIGINT | PK | Order id | 700345 |
| customer_id | INT | FK customers | Master customer id | 10482 |
| order_date | TIMESTAMP | | Order timestamp (invalid dates excluded) | 2024-02-11 14:22:05 |
| order_status | VARCHAR(20) | | Completed / Cancelled / Returned / Refunded | Completed |
| shipping_fee | NUMERIC(8,2) | | Fee charged to customer | 49.00 |
| shipping_cost | NUMERIC(8,2) | | Cost to the company | 85.00 |
| order_discount | NUMERIC(10,2) | | Order-level discount | 150.00 |
| delivery_region | VARCHAR(40) | | Standardised delivery region | Tamil Nadu |

## clean.order_items
| Column | Type | Key | Description | Example |
|---|---|---|---|---|
| order_item_id | BIGINT | PK | Line id | 1520011 |
| order_id | BIGINT | FK orders | Parent order | 700345 |
| product_id | INT | FK products | Product | 1042 |
| quantity | INT | | Units (> 0) | 2 |
| unit_price | NUMERIC(10,2) | | Selling price (> 0) | 1139.00 |
| line_discount | NUMERIC(10,2) | | Extra line discount | 0.00 |
| is_returned | BOOLEAN | | Line was returned | false |
| is_outlier | BOOLEAN | | Bulk line (quantity >= 50), kept and flagged | false |

## clean.payments
| Column | Type | Key | Description | Example |
|---|---|---|---|---|
| payment_id | BIGINT | PK | Payment id | 900231 |
| order_id | BIGINT | FK orders | Order | 700345 |
| payment_method | VARCHAR(20) | | UPI / Card / COD / Wallet | UPI |
| payment_status | VARCHAR(20) | | Success / Failed / Refunded | Success |
| amount | NUMERIC(12,2) | | Amount (negative for refunds) | 3548.00 |
| payment_date | TIMESTAMP | | Timestamp | 2024-02-11 14:23:10 |

## Helper and audit objects
| Object | Purpose |
|---|---|
| clean.dq_log | One row per data-quality issue with rows affected and action taken |
| clean.customer_master | Maps every raw customer id to its master id |
| clean.category_map | Maps raw category ids to the canonical id |
| clean.region_map / country_map | Label standardisation lookups |
| clean.v_item_facts, clean.v_orders_net | Revenue / profit definitions (see kpi_analysis.sql) |
| clean.v_rfm | RFM scores and segments |
| clean.v_cohort_retention | Cohort x month retention, censoring-safe |
