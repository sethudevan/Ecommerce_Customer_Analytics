# Business Requirements: Kaveri Living Co. Customer, Revenue & Profitability Analytics

> Kaveri Living Co. is a **fictional** online home and lifestyle retailer. All data is synthetic.

## 1. Background
Direct-to-consumer retailer selling about 1,500 products in 30 categories (kitchen, decor, furniture, bedding and bath, lighting, cleaning, outdoor), mainly in India with small UAE and Singapore markets. Revenue grew strongly over three years (illustrative scale: about 60,000 registered customers, about 114,000 completed orders).

## 2. Business problem
Management wants to know whether growth is **profitable and repeatable**: who the valuable customers are, why customers stop buying, which products and categories make the profit, which regions and acquisition channels pay back, and what to do about it.

## 3. Stakeholders and their decisions
| Stakeholder | Decisions this analysis informs |
|---|---|
| CEO | Growth vs profit priorities, targets, where to place bets |
| CFO | Margin protection, discount policy, return and refund leakage |
| CMO / Head of Marketing | Channel budget allocation, CAC limits, campaign audiences |
| Head of E-commerce | Retention programmes, regional logistics, site and fulfilment |
| Product Manager | Assortment, pricing, quality, discontinuation |

## 4. Business questions
1. Why are revenue and profit changing? (trend, decomposition, margin bridge)
2. Which customers are most valuable, and which are at risk? (RFM, CLV, inactivity)
3. Why do customers stop purchasing? (cohort retention, order gaps, first-order experience)
4. Which products and categories generate the most profit? (profitability, quadrant, Pareto, returns)
5. Which regions perform best? (revenue, profit, AOV, shipping cost, retention)
6. Which channels perform best? (CAC, CLV, repeat rate, payback)
7. How can retention and profitability be improved? (prioritised recommendations)

## 5. Scope
In scope: SQL analysis in PostgreSQL, Python EDA, a four-page Power BI report, written insights and recommendations.
Out of scope: forecasting, machine-learning churn prediction, real-time pipelines, causal inference (recommendations include test designs instead).

## 6. Metric definitions (single source of truth: `sql/kpi_analysis.sql` views)
| Metric | Definition |
|---|---|
| Net revenue | Item revenue (quantity x unit price - line discount) minus order discount; Completed orders only; returned lines excluded; Cancelled excluded |
| COGS | Quantity x unit cost |
| Gross profit | Net revenue - COGS + shipping fee - shipping cost |
| Profit margin | Gross profit / net revenue (ratio of sums) |
| AOV | Net revenue / completed orders |
| Active customer | Purchased in the 90 days before the last date in the data |
| Inactive customer | No purchase for more than 180 days (threshold checked against order-gap percentiles) |
| Repeat purchase rate | Customers with 2 or more completed orders / customers with 1 or more |
| Cohort | Month of a customer's first completed order |
| CLV (historical) | Cumulative gross profit per customer |
| CAC | Channel monthly spend x months / customers acquired (flat-spend shortcut) |
| Return rate | Returned order lines / all non-cancelled order lines |

## 7. Assumptions and limitations
- Synthetic data with planted behaviours, so findings demonstrate the method, not a real business.
- Channel attribution is first-touch; organic and direct have zero attributed spend.
- Spend is assumed flat across months (no spend-by-month table).
- Order-level discounts are not allocated to products.
- CLV is historical, not predictive; young customers have had less time to accumulate value.
- All comparisons across channels, cohorts or regions should show sample sizes.

## 8. Success measures (targets to be set from baselines)
Gross margin %, 90-day repeat rate, at-risk high-value customers (count and recovery rate), CLV:CAC by channel, return rate by category, share of products with negative profit.
