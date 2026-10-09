// power_query_load.pq -- OPTION A: load the CSVs exported by python/analysis.py (simplest; no database needed).
// Home > Transform data > New Source > Blank Query > Advanced Editor. Create one query per table.
// Change FolderPath to your local path to data/processed.
let
    FolderPath = "C:\path\to\ecommerce-customer-analytics\data\processed\",
    Source     = Csv.Document(File.Contents(FolderPath & "fact_orders.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted   = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    Typed      = Table.TransformColumnTypes(Promoted, {
                    {"order_id", Int64.Type}, {"customer_id", Int64.Type}, {"order_date", type date},
                    {"net_revenue", type number}, {"cogs", type number}, {"gross_profit", type number},
                    {"channel_id", Int64.Type}})
in
    Typed

// Repeat for: fact_order_items.csv (order_item_id, order_id, product_id, category_id, quantity as Int64; line_revenue, line_cogs as number;
//             is_returned as logical; order_date as date), dim_customer.csv, dim_product.csv, dim_channel.csv,
//             dim_date.csv (Date, MonthStart as date), cohort_retention.csv (cohort_month as date).

// ---------------------------------------------------------------------------------------------
// OPTION B: connect straight to PostgreSQL (Get Data > PostgreSQL database), Import mode, and pick the views:
//   clean.v_orders_net, clean.v_item_facts, clean.v_rfm, clean.v_cohort_retention, clean.customers, clean.products,
//   clean.categories, clean.marketing_channels.
// Then rebuild dim_customer / dim_product by merging queries (Merge Queries) or keep using Option A for the
// Python-enriched dimensions (RFM segment, quadrant, Pareto class, activity status).
