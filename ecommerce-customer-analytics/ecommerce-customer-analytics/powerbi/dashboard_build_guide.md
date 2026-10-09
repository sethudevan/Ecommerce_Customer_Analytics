# Power BI build guide: `dashboard.pbix`

> **Important:** a `.pbix` is a binary file that only Power BI Desktop can create, so it is **not** included.
> This folder gives you everything to build it in about 3 to 4 hours, then save it here as `powerbi/dashboard.pbix`:
>
> | File | Use |
> |---|---|
> | `theme.json` | View > Themes > Browse for themes: applies the palette, fonts, card borders and page background |
> | `measures.dax` | All measures, plus relationship and model notes in the header |
> | `power_query_load.pq` | Loads the CSVs in `data/processed/` (or connects to PostgreSQL) |
> | this file | Page layouts, visual field wells, slicers, drill-through, tooltips, checks |

## 1. Setup (30 min)

1. Run `python python/analysis.py` so `data/processed/*.csv` exist.
2. Power BI Desktop > Get Data > Text/CSV: load the eight CSVs (see `power_query_load.pq` for types).
3. Apply `theme.json`. Set canvas to **1280 x 720** (Page format > Type: Custom). Page background `#EDF0F4`.
4. Model view: create the relationships listed at the top of `measures.dax` (single direction, one-to-many). Mark `dim_date` as a date table. Hide all `*_id` foreign keys and `dim_rfm_segment` if unused.
5. Create a blank table `_Measures` and paste the measures from `measures.dax`. Format: currency measures as `₹ #,0` (use Display units: Lakhs / Crores in visuals), percentages as `0.0%`.
6. Sort `dim_date[Month]` by `MonthNum`.

## 2. Global design rules

| Item | Setting |
|---|---|
| Palette | Navy `#1F3A5F` (primary), Teal `#2A9D8F` (profit / good), Grey `#8D99AE` (comparison), Amber `#E9A23B` (warning), Red `#D1495B` (bad). Profit is **always teal**, revenue **always navy** |
| Layout | Left strip 70 px wide with four page-navigation buttons. Top band 60 px: page title left, slicers right. Content area on a 12-column grid with 12 px gutters |
| Cards | White, 1 px `#E5E7EB` border, 6 px radius. Value 28 to 32 pt, label 10 pt grey above, delta vs last year below |
| Max visuals per page | 8 (excluding slicers and buttons). Anything more goes into a tooltip or a drill-through page |
| Titles | Action-style titles **only after** you have verified the number against SQL. Until then use descriptive titles |
| Red/green | Always pair colour with a sign or icon (colour-blind safe) |

## 3. Page 1: Executive Overview

**Purpose:** a 90-second view of business health for senior management.

| # | Visual | Fields | Why / question / decision / chart choice |
|---|---|---|---|
| 1 to 6 | **KPI cards:** Revenue, Gross Profit, Profit Margin %, Orders, Customers, AOV | `[Revenue]`, `[Gross Profit]`, `[Profit Margin %]`, `[Orders]`, `[Customers]`, `[AOV]`; delta from `[Revenue YoY %]`, `[Profit YoY %]`, `[Margin YoY (pts)]` | Executives read headline numbers first. *Are we ahead of last year?* Decides whether to dig deeper. Card + small delta: fastest to read, no distortion |
| 7 | **Revenue and profit trend** | Axis `dim_date[MonthStart]`; values `[Revenue]`, `[Gross Profit]` | *Is growth steady, do revenue and profit move together?* Targets and divergence. **Line chart**: best for time series |
| 8 | **Margin % trend** | Axis `MonthStart`; value `[Profit Margin %]`; constant line `[Margin Target %]` | *Is efficiency eroding, and in which months?* Pricing / discount calendar. **Line with target line** so the eye sees deviation |
| 9 | **Top categories by profit** | Axis `dim_product[category_name]`; value `[Product Profit]`; Top N = 8 by profit | *Which categories carry the business?* Where to invest and protect. **Sorted horizontal bar**: long labels read well |
| 10 | **Key alerts** (4 text cards or one multi-row card) | `[Alert: Margin]`, `[Alert: Repeat Rate]`, `[Alert: At-Risk]`, `[Alert: Returns]` | *What needs action this month?* Prioritises the agenda. Conditional text: shows only when a threshold is breached |

Slicers (synced across pages): **Year**, **Region** (`dim_customer[region]`), **Channel** (`dim_channel[channel_name]`) in the top band.
Optional: **revenue bridge waterfall** (new vs returning customer revenue) if you add a `customer_type` column to `fact_orders`.

## 4. Page 2: Customer Analytics

**Purpose:** show customer behaviour and where retention can be improved.

| # | Visual | Fields | Why / question / decision / chart choice |
|---|---|---|---|
| 1 | **Cards:** Repeat Purchase Rate, Avg Profit CLV, Inactive rate, At-Risk High-Value count | `[Repeat Purchase Rate %]`, `[Avg Profit CLV]`, `[Churn / Inactivity Rate %]`, `[At-Risk High-Value Customers]` | Headline loyalty and value. Sets retention targets and affordable CAC |
| 2 | **Segment size vs revenue share** | Axis `dim_customer[segment]` (exclude "No purchase"); values: customer count, `[Revenue]` as % of grand total | *Which segments carry the revenue?* Targeting priority. **Clustered bar** compares two shares per segment |
| 3 | **RFM table** | `segment`, count, `[Revenue]`, `[Gross Profit]`, average `recency_days`, average `frequency` | Detail with actionability: campaign sizing. **Table with data bars** (precise values plus visual cue) |
| 4 | **Cohort retention matrix** | Rows `cohort_retention[cohort_month]`; columns `month_index` (1 to 12); values `[Cohort Retention %]`; colour scale white to navy | *Do customers come back; are newer cohorts better?* Timing of nudges. **Matrix with colour scale**: the natural form for cohorts. Do **not** sync the date slicer to this visual |
| 5 | **Retention curve** | Axis `month_index`; values `[Cohort Retention %]`; legend = cohort year | *Is retention improving?* Judging programmes. **Line chart**, one line per year |
| 6 | **Activity status split** | Axis `activity_status`; values customer count | *How many customers are slipping away?* Win-back budget. **100% stacked bar** (3 categories max; avoid donut) |
| 7 | **At-risk high-value list** | Table: `customer_id`, `region`, `channel_name`, `frequency`, `profit`, `recency_days`; filter `segment = At-Risk (high value)`; sort by profit | Makes the insight actionable: the outreach list. **Table** with drill-through to customer detail |

Slicers: Region, Channel, Segment.

## 5. Page 3: Product and Profitability

**Purpose:** identify the products and categories driving revenue and profit, and those leaking it.

| # | Visual | Fields | Why / question / decision / chart choice |
|---|---|---|---|
| 1 | **Revenue vs profit by category** | Axis `category_name`; values `[Product Revenue]`, `[Product Profit]` | *Which categories earn less than their size suggests?* Reprice or reposition. **Clustered bar** |
| 2 | **Low-margin / high-volume products** | Table: `product_name`, units, `[Product Revenue]`, `[Product Margin %]`, `quadrant`; filter `quadrant = High volume / low margin` | Specific repricing candidates. **Table** with margin conditional format |
| 3 | **Top products by profit** | Top N = 10 by `[Product Profit]` | Promote and protect. **Ranked bar** |
| 4 | **Volume vs margin quadrant** | Scatter: X units, Y `[Product Margin %]`, size `[Product Revenue]`, legend `quadrant`; add median reference lines | *Which are stars, dogs, high-volume low-margin?* Promote / optimise / reprice / discontinue. **Scatter** shows four groups at once |
| 5 | **Return rate by category** | Axis `category_name`; value `[Line Return Rate %]`; conditional colour with `[Return Color]` | *Where do returns hurt?* Quality / listing / packaging investigation. **Bar** with threshold colour |
| 6 | **Pareto** | Product axis ranked by profit (use `Profit Rank (Product)` as axis), columns `[Product Profit]`, line `[Cumulative Profit %]`, constant line 80% | *How few products make most of the profit?* Range rationalisation. **Combo chart** (columns plus cumulative line) |
| 7 | **Margin trend by category** | Line, axis `MonthStart`, legend `category_name` (limit with a category slicer) | Early repricing. Use a slicer; never plot all 30 lines at once |

Slicers: Year, Category, Quadrant. Drill-through target: **Product detail**.

## 6. Page 4: Region and Channel Performance

**Purpose:** identify geographic and acquisition opportunities.

| # | Visual | Fields | Why / question / decision / chart choice |
|---|---|---|---|
| 1 | **Revenue and profit by region** | Bar: axis `dim_customer[region]`; values `[Revenue]`, `[Gross Profit]` (relate region through fact_orders.delivery_region if you prefer delivery region) | *Where does profit come from?* Regional investment. **Bar for precision**; add a filled map only if you geocode, since maps misrepresent small regions |
| 2 | **Region table** | `region`, `[Customers]`, `[AOV]`, `[Profit Margin %]`, `[Repeat Purchase Rate %]`, `[Profit per Customer]` with conditional formatting | *Which regions are valuable vs merely large?* Regional retention programmes. **Table** + colour scale |
| 3 | **Retention by region** | Bar of `[Repeat Purchase Rate %]` by region (note sample sizes in a tooltip) | Where do customers stay? Local fulfilment/service fixes |
| 4 | **Revenue and profit by channel** | Clustered bar by `channel_name` | *Which channels earn their keep?* Budget allocation |
| 5 | **CAC vs CLV by channel** | Scatter: X `[CAC]`, Y `[Avg Profit CLV]`, size `[New Customers]`, legend `channel_name`; add a 1:1 line (CLV = CAC) | *Which channels pay back?* Reallocate spend. Points above the line pay back. Organic/Direct have CAC 0, so label them |
| 6 | **Profit to spend by channel** | Bar of `[Profit to Spend]` (paid channels only) | Quick payback ranking for the CMO |

Slicers: Year, Region, Channel type.

## 7. Interactions you should configure

| Feature | How |
|---|---|
| **Drill-through: Customer detail** | New page, add `dim_customer[customer_id]` to Drill-through. Show orders over time, profit, recency, categories bought. Add a Back button |
| **Drill-through: Product detail** | Drill-through field `dim_product[product_id]`: monthly units, margin, return rate, channel mix |
| **Drill-through: Category detail** | Drill-through field `category_name`: products in the category, margin trend |
| **Report-page tooltips** | New hidden page (Page size: Tooltip). Small KPI card plus a sparkline for the hovered region / category. Set as tooltip on the region bar and category bar |
| **Navigation** | Four page buttons with "Page navigation" action; highlight the active page using a bookmark per page; Reset-filters bookmark button |
| **Sync slicers** | View > Sync slicers: Year, Region and Channel across pages 1 to 4. Exclude the cohort matrix from slicer interaction (Format > Edit interactions) |
| **Conditional formatting** | Margin cell: red below `[Margin Target %]`; return bars: `[Return Color]`; cohort matrix: single-hue gradient; alert cards hidden when blank |

## 8. Keeping it uncluttered

1. One question per page; at most 8 visuals.
2. Put detail behind drill-through and tooltips, not on the canvas.
3. Remove gridlines, redundant legends and axis titles that repeat the visual title.
4. Sort bars. Top N with the rest hidden.
5. No 3D, no pies beyond 3 slices, no dual axes unless the Pareto needs it.
6. Consistent number format: ₹ lakh / crore, one decimal for percentages.
7. Show **sample sizes** (customer counts) next to every region/channel rate.
8. Test: someone unfamiliar should say what to do next within 30 seconds.

## 9. Validate before publishing

| Check | Expected (seed 42 dataset, see README) |
|---|---|
| Total Revenue card | about ₹32.8 crore across all years (matches `kpi_analysis.sql` headline) |
| Profit Margin % | about 35.1% |
| Orders / Customers | about 114,199 / 50,677 |
| Repeat Purchase Rate | about 47.2% |
| Cohort matrix | Month-1 retention about 15 to 19% for most cohorts |

If a card is off, compare it with the SQL query first. The SQL and the dashboard must agree before you present.

## 10. Performance and publishing

Import mode, star schema, hide unused columns, avoid high-cardinality slicers (no `customer_id` slicer), check **Performance Analyzer** for visuals above 500 ms. Export each page to PDF and screenshots into `images/` for the README (`01_executive_overview.png` ... `04_region_channel.png`).
