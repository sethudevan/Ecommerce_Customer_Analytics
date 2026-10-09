# E-Commerce Customer Retention, Revenue & Profitability Analytics

An end-to-end analytics project for **Kaveri Living Co.**, a online home and lifestyle retailer: PostgreSQL (data modelling, cleaning, advanced SQL), Python (EDA, segmentation, cohorts, margin bridge) and Power BI (4-page executive report), finishing in prioritised, measurable recommendations.

---

## 1. Business problem

Revenue grew roughly 2.4x in two years, but management cannot say whether the growth is *profitable and repeatable*. They need to know:

- Which customers are most valuable, and which are slipping away?
- Why do customers stop purchasing?
- Which products and categories actually generate profit?
- Which regions and acquisition channels pay back?
- What should the company do, in what order, and how will it measure success?

**Stakeholders:** CEO, CFO, CMO / Head of Marketing, Head of E-commerce, Product Manager. See [documentation/business_requirements.md](documentation/business_requirements.md).

## 2. Repository structure

```
ecommerce-customer-analytics/
├── README.md
├── requirements.txt
├── data/
│   ├── raw/                  
│   └── processed/            
├── sql/
│   ├── schema.sql            raw (TEXT) + clean (typed, keyed) schemas, dq_log
│   ├── load_raw.sql          \copy the CSVs into raw.*
│   ├── data_quality.sql      profile -> clean -> reconcile -> index
│   ├── kpi_analysis.sql      foundation views, KPIs, trends, growth, region & channel performance
│   ├── customer_analysis.sql repeat rate, gaps, inactivity, CLV, RFM, customer groups, concentration
│   ├── product_analysis.sql  category/product profit, ranking, quadrant, returns, Pareto, actions
│   └── retention_analysis.sql cohorts, payback, fixed-window retention by channel/region
├── python/
│   ├── generate_data.py      synthetic data generator with injected data-quality problems
│   └── analysis.py           EDA, outliers, segmentation, cohorts, margin bridge, exports (# %% cells)
├── powerbi/
│   ├── dashboard_build_guide.md  page-by-page build instructions
│   ├── measures.dax          all DAX measures + model notes
│   ├── theme.json            colours / fonts / card style
│   ├── power_query_load.pq   data loading
│   └── dashboard.pbix       
├── documentation/
│   ├── business_requirements.md
│   └── data_dictionary.md
└── images/                   charts written by analysis.py + dashboard screenshots
```


## 3. Data model

`marketing_channels 1-* customers 1-* orders 1-* order_items *-1 products *-1 categories`, plus `orders 1-* payments`. Full column list in [documentation/data_dictionary.md](documentation/data_dictionary.md).

| Table | Rows (raw, seed 42) |
|---|---|
| marketing_channels | 8 |
| categories | 36 (30 real + 6 misspelled duplicates) |
| products | 1,500 |
| customers | 60,900 (900 are duplicates) |
| orders | 121,603 (includes repeated rows) |
| order_items | 279,169 |
| payments | 122,503 |
| **Total** | **585,719** |

## 4. Data quality: what was found and how it was handled

Every issue is profiled in `data_quality.sql` (Part A), fixed with a documented rule (Part B, logged to `clean.dq_log`) and reconciled (Part C).

| Issue | Rows (seed 42) | Treatment |
|---|---|---|
| Duplicate customers (same email, different id) | 848 merged | Mapped to the earliest id (`customer_master`); orders re-pointed |
| Missing email / phone / region | 3,560 / 2,450 / 1,846 | Kept; `has_email` flag; region back-filled from the latest order |
| Inconsistent country / region labels | 2,533 / 5,866 | Lookup tables (`country_map`, `region_map`) |
| Inconsistent category names | 6 variants | Collapsed to one canonical id |
| Missing product category / cost | 28 / 24 | "Uncategorized" / imputed from category median cost ratio, flagged |
| Duplicate order rows | 604 | One row per `order_id` |
| Invalid order dates (1900 placeholder, year 2031, unparseable) | 365 orders | Excluded and logged (cannot be placed in time) |
| Prices stored as text with currency symbols | 2,717 | Stripped and cast |
| Negative / zero quantity or price | 371 lines | Excluded as errors (refunds are tracked in payments and `is_returned`) |
| Bulk-quantity outliers (>= 50 units) | 123 lines | **Kept and flagged**, reported with and without |
| Cancelled orders | 4,884 | Excluded from revenue and profit, used for cancellation rate |
| Returned / refunded orders | 1,503 | Excluded from net revenue, analysed as return leakage |

**Validation after cleaning:** zero orphan foreign keys; 14 regions, 3 countries, 31 categories (30 + Uncategorized); payments match recomputed order totals for 99.6% of completed orders (the 0.4% are explained by excluded error lines).

![Data-quality issues](images/02_dq_issues.png)

## 5. Methods

- **One definition of revenue and profit** in two views (`v_item_facts`, `v_orders_net`), so SQL, Python and Power BI agree.
  Net revenue = items minus line and order discounts, completed orders only, returned lines excluded. Gross profit = net revenue - COGS + shipping fee - shipping cost.
- **SQL techniques:** CTEs, subqueries, conditional aggregation (`FILTER`), `LEFT JOIN` anti-patterns, `LAG`/`LEAD`, running totals, moving averages, MoM/YoY, `RANK`/`DENSE_RANK`/`ROW_NUMBER`, `NTILE`, `percentile_cont`, date arithmetic.
- **Inactivity threshold from data**, not guesswork: order-gap percentiles (p50 / p80 / p90 = 50 / 98 / 136 days).
- **RFM** with `NTILE(5)` and deterministic tie-breaking; **cohorts** by first purchase month with **right-censoring handled** (unreachable cells are blank, not zero); **fixed-window** repeat metrics so channels are compared fairly.
- **Python** adds log-scale IQR outlier detection, Lorenz curve / Gini, margin bridge (mix vs rate), Spearman correlation and a k-means cross-check of the RFM segments. No predictive model: every question here is answered descriptively.

## 6. Results on the seed-42 dataset

> These numbers come from running this repository on the synthetic dataset; they may differ slightly on other library versions. Treat them as *what the method finds in a simulation with known patterns*.

### Headline KPIs

| KPI | Value |
|---|---|
| Net revenue (3 years) | ₹32.8 crore (2023: ₹6.4 cr, 2024: ₹11.1 cr, 2025: ₹15.3 cr) |
| Gross profit / margin | ₹11.5 crore / 35.1% (2023: 34.9%, 2024: 35.3%, 2025: 34.9%) |
| Completed orders / AOV | 114,199 / ₹2,871 |
| Customers who purchased | 50,677 |
| Active customers (last 90 days) | 11,574 |
| Repeat purchase rate | 47.2% (52.8% bought only once) |
| Cancellation rate / line return rate | 4.05% / 4.53% |

![Revenue, profit and margin trend](images/04_trend_revenue_profit_margin.png)

### Insights (finding, metric, likely cause, action, KPI)

| # | Finding | Evidence | Cause (tested?) | Recommendation | KPI |
|---|---|---|---|---|---|
| 1 | **Margin is flat year over year but dips every festive month.** Growth is not eroding margin, discounting is | Margin about 36 to 38% in normal months vs about 27 to 28.5% in Oct, Nov and Jan | Deeper festive discounts (discount-vs-list query in `product_analysis.sql`) | Cap discount depth on low-margin categories; test festive offers against a control | Gross margin %, avg discount vs list |
| 2 | **Growth now depends on returning customers.** Returning customers' share of revenue rose from 42.5% (2023) to 59% (2025) | `kpi_analysis.sql` section 4 | Larger base of past buyers | Protect the base: retention is the profit engine | Returning-customer revenue share |
| 3 | **Half of customers never return, and the loss is early.** Month-1 retention is about 16%, month-12 about 4%; no worsening in newer cohorts | Cohort heatmap, `retention_analysis.sql` | Short window: median gap between orders is 50 days | Post-purchase journey timed inside the first 50 to 100 days, with a holdout group | 90-day repeat rate |
| 4 | **Social Ads brings the most customers but the weakest ones.** 13,131 new customers (about as many as Organic Search), 31.9% repeat within 365 days vs 60 to 66% for Referral / Email / Organic; profit per buyer ₹1,326 vs about ₹2,600 to ₹3,200 for Email, Direct, Referral and Organic Search | `kpi_analysis.sql` section 7, `retention_analysis.sql` section 4 | Discounted first orders (avg discount vs list about 8% vs about 5% elsewhere; first-order margin 32.7%) | Cut the weakest campaigns and run an incremental test before reallocating | CLV:CAC and payback by channel |
| 5 | **All paid channels return less than their spend in this simulation** (profit-to-spend 0.39 to 0.70) | Channel scorecard | Assumed spend levels in the generator; flat-spend shortcut | Treat as a prompt to build a proper spend-by-month table, not as a verdict | Profit-to-spend ratio |
| 6 | **Small Appliances: 10.6% of revenue but 2.3% of profit** (margin 8.2%) | Category query | Thin product margin plus discounting | Reprice, renegotiate supplier cost, or reduce promotions | Category margin % |
| 7 | **Table Lamps return 21.9% of lines** (vs 4.5% overall), costing about ₹13 lakh profit | Returns query | To be investigated: breakage, packaging, listing accuracy | Quality and packaging review; fix listings | Return rate by category |
| 8 | **Profit is concentrated.** 28% of products make 80% of profit; 38.7% of customers make 80% of profit (Gini 0.56) | Pareto queries, Lorenz curve | Normal long tail | Range review of the C-class tail after a basket-affinity check | Share of profit from top decile |
| 9 | **High-value customers are going quiet.** RFM "At-Risk (high value)": 7,078 customers (14%) holding 23% of historical revenue | `v_rfm` | Gaps longer than their normal rhythm | Personal win-back outreach in the first 30 days of lapse | At-risk high-value count and recovery rate |
| 10 | **Dubai and Singapore cost more to serve.** Shipping is about 8% of revenue vs about 2.7% in India (Assam 5.0%); margins about 30% vs about 35% | Region query | Cross-border logistics | Revisit shipping fees / thresholds, or fulfilment partner | Shipping cost % of revenue |
| 11 | **Under-₹500 baskets lose money more often** (7.7% of orders loss-making vs 1.2 to 1.8% elsewhere) | Basket band query | Fixed shipping cost | Raise free-shipping threshold or add a small-order fee | Loss-making order share |

**Findings that did *not* hold, which is also useful to say in interviews:**
- *A first order with a returned item did not reduce repeat purchase* (48.6% vs 48.3% repeat within 180 days).
- *Region retention differences are small* (about 34 to 39% repeat within 90 days); regions differ on cost to serve, not loyalty.
- *The 90/180-day inactivity bands label 65% of customers "inactive"* because the data spans three years; the at-risk band (91 to 180 days, 12% of customers) is the actionable one.
- *The highest-profit "customers" include several bulk-order outliers* (single orders of ₹2 to ₹18 lakh). Re-run the customer groups excluding `is_outlier` lines before building a VIP list.

![Cohort retention](images/09_cohort_heatmap.png)
![Product quadrant](images/12_product_quadrant.png)

### Recommendations, prioritised

| # | Recommendation | Impact | Effort | Urgency | Priority |
|---|---|---|---|---|---|
| R1 | Win-back for at-risk high-value customers (with holdout) | High | Low | High | **Do first** |
| R2 | Discount discipline in festive months and low-margin categories | High | Low | High | **Do first** |
| R3 | Post-purchase journey inside the first 50 to 100 days | High | Low | High | **Do first** |
| R4 | Reprice / cut promotions on high-volume, low-margin products (staged tests) | High | Medium | Medium | Plan |
| R5 | Rebalance channel budget towards channels with better CLV:CAC, tested incrementally | High | Medium | Medium | Plan |
| R6 | Fix return drivers (Table Lamps first) | Medium | Medium | Medium | Plan |
| R7 | Cross-border shipping fee / fulfilment review | Medium | High | Low | Phase later |

Success is measured by gross margin %, 90-day repeat rate, at-risk high-value recovery, CLV:CAC by channel and return rate, with targets set from these baselines and every action tested against a control group.

## 7. Power BI dashboard

Four pages (Executive Overview, Customer Analytics, Product & Profitability, Region & Channel). A `.pbix` can only be authored in Power BI Desktop, so this repo ships everything needed to build it quickly: [`dashboard_build_guide.md`](powerbi/dashboard_build_guide.md) (layout, field wells, slicers, drill-through, tooltips, clutter rules), [`measures.dax`](powerbi/measures.dax), [`theme.json`](powerbi/theme.json) and [`power_query_load.pq`](powerbi/power_query_load.pq). Save the finished report as `powerbi/dashboard.pbix` and add four page screenshots to `images/`.

## 8. Limitations

- Synthetic data; patterns were planted, so results show the method works, not facts about a business.
- First-touch channel attribution; organic and direct have no attributed spend; spend is assumed flat.
- Order-level discounts are not allocated to products; CLV is historical, not predictive.
- A few orders end with about zero or slightly negative net revenue when returned lines are removed but the order discount stays; they are kept on purpose and clipped only for log transforms in Python.
- Recommendations are hypotheses to test; observational data cannot prove causal impact.

## 9. Skills demonstrated

Relational modelling, advanced PostgreSQL, data cleaning and validation, KPI design, RFM and cohort analysis, retention and CLV, profitability analysis, Python EDA, Power BI modelling and DAX, business storytelling, stakeholder-specific communication.

## 10. Tech stack

PostgreSQL, Python (pandas, NumPy, Matplotlib, Seaborn, SQLAlchemy, scikit-learn), Power BI Desktop.

---
*Author: Sethupathi M*
