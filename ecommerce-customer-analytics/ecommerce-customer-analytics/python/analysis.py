#!/usr/bin/env python3
"""
analysis.py  --  Python analysis for the E-Commerce Customer Retention, Revenue & Profitability project.
Works as a plain script (python python/analysis.py) and as a notebook source: the "# %%" markers are
cell separators in VS Code / Jupytext / PyCharm (convert with `jupytext --to ipynb python/analysis.py`).

What Python adds beyond SQL: data-quality evidence, distributions and outlier detection, charts that
tell the story (trend, cohort heatmap, Lorenz curve, quadrant, Pareto), the margin bridge, correlation,
and CSV exports for Power BI.

Config:  DATABASE_URL env var, e.g. postgresql+psycopg2://user:password@localhost:5432/ecommerce
Output:  figures -> images/ ; Power BI tables -> data/processed/
Prereq:  run the SQL files first (schema, load_raw, data_quality, kpi_analysis, customer_analysis,
         retention_analysis) so the views clean.v_* exist.
"""
import os
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")                         # works without a display; remove for interactive use
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import seaborn as sns
from sqlalchemy import create_engine

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG = os.path.join(ROOT, "images")
OUT = os.path.join(ROOT, "data", "processed")
os.makedirs(IMG, exist_ok=True); os.makedirs(OUT, exist_ok=True)

sns.set_theme(style="whitegrid", context="notebook")
plt.rcParams.update({"figure.dpi": 110, "axes.spines.top": False, "axes.spines.right": False})
NAVY, TEAL, AMBER, RED, GREY = "#1F3A5F", "#2A9D8F", "#E9A23B", "#D1495B", "#8D99AE"


def save(name):
    plt.tight_layout(); plt.savefig(os.path.join(IMG, name), dpi=130); plt.close()
    print("saved", name)


def q(sql):
    return pd.read_sql(sql, engine)


# %% 0. Connect and load -------------------------------------------------------------------------
engine = create_engine(os.environ.get("DATABASE_URL", "postgresql+psycopg2://postgres:postgres@localhost:5432/ecommerce"))
orders = q("SELECT * FROM clean.v_orders_net")
orders["order_date"] = pd.to_datetime(orders.order_date); orders["order_month"] = pd.to_datetime(orders.order_month)
items = q("SELECT * FROM clean.v_item_facts")
items["order_month"] = pd.to_datetime(items.order_month)
rfm = q("SELECT * FROM clean.v_rfm")
cust = q("""SELECT c.*, m.channel_name FROM clean.customers c
            JOIN clean.marketing_channels m USING (channel_id)""")
prods = q("""SELECT p.*, c.category_name FROM clean.products p JOIN clean.categories c USING (category_id)""")
print(orders.shape, items.shape, rfm.shape)
AS_OF = orders.order_date.max()

# %% 1. Data-quality evidence (raw vs clean) -------------------------------------------------------
dq = q("SELECT table_name, issue, rows_affected, action_taken FROM clean.dq_log ORDER BY log_id")
print(dq.to_string(index=False))

raw_c = q("SELECT * FROM raw.customers")
null_by_month = (raw_c.assign(m=pd.to_datetime(raw_c.signup_date, errors="coerce", format="mixed").dt.to_period("M"))
                 .groupby("m")[["email", "phone", "region"]].apply(lambda d: d.isna().mean()))
plt.figure(figsize=(12, 3))
sns.heatmap(null_by_month.T, cmap="Reds", cbar_kws={"label": "share missing"}, xticklabels=3)
plt.title("Missing customer data by signup month (raw layer)"); plt.xlabel("")
save("01_missing_data_heatmap.png")

top = dq[dq.rows_affected > 0].sort_values("rows_affected")
plt.figure(figsize=(9, 5.5))
plt.barh(top.table_name + ": " + top.issue.str.slice(0, 48), top.rows_affected, color=NAVY)
plt.title("Data-quality issues found in the raw layer (rows affected)"); plt.xscale("log")
save("02_dq_issues.png")

# %% 2. Distributions and outliers ----------------------------------------------------------------
fig, ax = plt.subplots(1, 3, figsize=(15, 4))
sns.histplot(orders.net_revenue, bins=60, ax=ax[0], color=NAVY); ax[0].set_title("Order value (right-skewed)")
sns.histplot(np.log1p(orders.net_revenue.clip(lower=0)), bins=60, ax=ax[1], color=TEAL); ax[1].set_title("Order value, log scale")
sns.boxplot(x=np.log1p(orders.net_revenue.clip(lower=0)), ax=ax[2], color=AMBER); ax[2].set_title("Log order value boxplot")
save("03_order_value_distribution.png")

print("Orders with net revenue <= 0 (order discount > remaining line revenue after returns):", int((orders.net_revenue <= 0).sum()))
lv = np.log1p(orders.net_revenue.clip(lower=0))
q1, q3 = lv.quantile([.25, .75]); iqr = q3 - q1
orders["is_outlier"] = (lv < q1 - 1.5 * iqr) | (lv > q3 + 1.5 * iqr)
cmp_ = pd.DataFrame({
    "all_orders": orders.net_revenue.agg(["count", "sum", "mean", "median"]),
    "excluding_outliers": orders.loc[~orders.is_outlier, "net_revenue"].agg(["count", "sum", "mean", "median"]),
})
print("Outlier share:", round(orders.is_outlier.mean() * 100, 2), "%"); print(cmp_.round(0))
print(orders.nlargest(10, "net_revenue")[["order_id", "customer_id", "net_revenue"]])

# %% 3. Trend analysis ---------------------------------------------------------------------------
m = (orders.groupby("order_month")
     .agg(orders=("order_id", "nunique"), revenue=("net_revenue", "sum"), profit=("gross_profit", "sum"),
          customers=("customer_id", "nunique"))
     .assign(margin=lambda d: d.profit / d.revenue, aov=lambda d: d.revenue / d.orders))
fig, ax = plt.subplots(2, 1, figsize=(12, 7), sharex=True)
(m[["revenue", "profit"]] / 1e5).plot(ax=ax[0], color=[NAVY, TEAL]); ax[0].set_ylabel("INR lakh"); ax[0].set_title("Monthly revenue and profit")
m["margin"].plot(ax=ax[1], color=RED); ax[1].yaxis.set_major_formatter(mtick.PercentFormatter(1.0))
ax[1].set_title("Gross margin: dips in festive months (Oct, Nov, Jan) = deeper discounting"); ax[1].set_xlabel("")
save("04_trend_revenue_profit_margin.png")

m["year"], m["mon"] = m.index.year, m.index.month
plt.figure(figsize=(10, 4)); sns.lineplot(data=m, x="mon", y="revenue", hue="year", marker="o", palette=[GREY, TEAL, NAVY])
plt.title("Revenue by month, year over year (seasonality)"); save("05_seasonality.png")

# Revenue decomposition: new vs returning customers
first = orders.groupby("customer_id").order_date.min().rename("first_date")
o2 = orders.join(first, on="customer_id")
o2["type"] = np.where(o2.order_date == o2.first_date, "New customer", "Returning customer")
dec = o2.groupby([o2.order_date.dt.year, "type"]).net_revenue.sum().unstack() / 1e7
dec.plot(kind="bar", stacked=True, color=[TEAL, NAVY], figsize=(7, 4)); plt.ylabel("INR crore"); plt.xlabel("")
plt.title("Where revenue comes from: new vs returning customers"); plt.xticks(rotation=0); save("06_new_vs_returning.png")

# %% 4. Customer segmentation (RFM) --------------------------------------------------------------
seg_order = ["Champions", "Loyal Customers", "Potential Loyalists", "New Customers",
             "At-Risk (high value)", "At-Risk", "Needs Attention", "Lost"]
seg = (rfm.groupby("segment").agg(customers=("customer_id", "count"), revenue=("monetary", "sum"),
                                  profit=("profit", "sum"), avg_recency=("recency_days", "mean"),
                                  avg_orders=("frequency", "mean")).reindex(seg_order))
seg["pct_customers"] = seg.customers / seg.customers.sum(); seg["pct_revenue"] = seg.revenue / seg.revenue.sum()
seg[["pct_customers", "pct_revenue"]].plot(kind="bar", figsize=(11, 4), color=[GREY, NAVY])
plt.gca().yaxis.set_major_formatter(mtick.PercentFormatter(1.0)); plt.xticks(rotation=25, ha="right")
plt.title("Share of customers vs share of revenue, by RFM segment"); save("07_rfm_segments.png")
print(seg.round(2))

v = np.sort(rfm.monetary.clip(lower=0).values); cum = np.cumsum(v) / v.sum(); x = np.arange(1, len(v) + 1) / len(v)
trap = getattr(np, 'trapezoid', None) or np.trapz   # numpy 2.x renamed trapz
gini = 1 - 2 * trap(cum, x)
plt.figure(figsize=(5.5, 5)); plt.plot(x, cum, color=NAVY, label=f"Customers (Gini {gini:.2f})")
plt.plot([0, 1], [0, 1], "--", color=GREY, label="Perfect equality"); plt.legend()
plt.xlabel("Share of customers (lowest to highest value)"); plt.ylabel("Share of revenue"); plt.title("Customer value concentration")
save("08_lorenz_curve.png")

# Cross-check rule-based RFM with k-means (optional dependency)
try:
    from sklearn.preprocessing import StandardScaler
    from sklearn.cluster import KMeans
    X = StandardScaler().fit_transform(np.log1p(rfm[["recency_days", "frequency", "monetary"]].clip(lower=0)))  # clip: a few customers have ~0 net revenue
    inertia = [KMeans(k, n_init=5, random_state=42).fit(X).inertia_ for k in range(2, 9)]
    print("k-means inertia k=2..8:", [round(i) for i in inertia], "(elbow check; rule-based RFM stays primary)")
except ImportError:
    print("scikit-learn not installed; skipping the k-means cross-check")

# %% 5. Cohorts and retention --------------------------------------------------------------------
coh = q("SELECT * FROM clean.v_cohort_retention")
coh["cohort_month"] = pd.to_datetime(coh.cohort_month)
mat = coh.pivot(index="cohort_month", columns="month_index", values="retention_pct")
mat.index = mat.index.strftime("%Y-%m")
plt.figure(figsize=(13, 9))
sns.heatmap(mat.iloc[:, 1:13], annot=True, fmt=".0f", cmap="Blues", vmin=0, vmax=25,
            cbar_kws={"label": "% of cohort active"}, linewidths=.3)
plt.title("Monthly cohort retention (% of the cohort ordering again in month k; blank = not yet observable)")
plt.xlabel("Months since first purchase"); plt.ylabel("First-purchase cohort")
save("09_cohort_heatmap.png")

coh["year"] = coh.cohort_month.dt.year
curve = coh[coh.month_index.between(1, 12)].groupby(["year", "month_index"]).retention_pct.mean().unstack(0)
curve.plot(figsize=(9, 4), marker="o", color=[GREY, TEAL, NAVY]); plt.ylabel("avg % active")
plt.title("Retention curve by cohort year"); plt.xlabel("Months since first purchase"); save("10_retention_curves.png")

gaps = orders.sort_values(["customer_id", "order_date"]).groupby("customer_id").order_date.diff().dt.days.dropna()
plt.figure(figsize=(9, 4)); sns.histplot(gaps[gaps < 400], bins=80, color=NAVY)
for p, c in zip([.5, .8, .9], [TEAL, AMBER, RED]):
    plt.axvline(gaps.quantile(p), color=c, ls="--", label=f"p{int(p*100)} = {gaps.quantile(p):.0f} days")
plt.legend(); plt.title("Days between consecutive orders -> data-driven inactivity threshold"); save("11_order_gaps.png")

# %% 6. Product analysis -------------------------------------------------------------------------
ok = items[(items.order_status == "Completed") & (~items.is_returned)]
prod = (ok.groupby("product_id").agg(units=("quantity", "sum"), revenue=("line_revenue", "sum"), cogs=("line_cogs", "sum"))
        .assign(profit=lambda d: d.revenue - d.cogs, margin=lambda d: (d.revenue - d.cogs) / d.revenue).query("units >= 20"))
prod = prod.join(prods.set_index("product_id")[["product_name", "category_name"]])
plt.figure(figsize=(9, 6))
plt.scatter(prod.units, prod.margin, s=prod.revenue / prod.revenue.max() * 400, alpha=.35, color=NAVY)
plt.axvline(prod.units.median(), ls="--", c=GREY); plt.axhline(prod.margin.median(), ls="--", c=GREY)
plt.xscale("log"); plt.xlabel("Units sold (log)"); plt.ylabel("Margin"); plt.gca().yaxis.set_major_formatter(mtick.PercentFormatter(1.0))
plt.title("Product volume vs margin (bubble = revenue)"); save("12_product_quadrant.png")

p = prod.sort_values("profit", ascending=False).reset_index()
p["cum_pct"] = p.profit.cumsum() / p.profit.sum()
fig, ax = plt.subplots(figsize=(10, 4)); ax.bar(range(len(p)), p.profit / 1e5, width=1, color=NAVY, alpha=.6)
ax2 = ax.twinx(); ax2.plot(range(len(p)), p.cum_pct, c=RED); ax2.axhline(.8, ls="--", c=GREY)
ax2.yaxis.set_major_formatter(mtick.PercentFormatter(1.0)); ax.set_ylabel("Profit, INR lakh"); ax.set_xlabel("Products ranked by profit")
ax.set_title(f"Pareto: {(p.cum_pct <= .8).sum()} of {len(p)} products make 80% of profit"); save("13_product_pareto.png")

cat = (ok.merge(prods[["product_id", "category_name"]], on="product_id")
       .groupby("category_name").agg(revenue=("line_revenue", "sum"), cogs=("line_cogs", "sum")))
cat["profit"] = cat.revenue - cat.cogs; cat["margin"] = cat.profit / cat.revenue
cat["rev_share"] = cat.revenue / cat.revenue.sum(); cat["profit_share"] = cat.profit / cat.profit.sum()
c = cat.sort_values("profit_share", ascending=True)
fig, ax = plt.subplots(figsize=(8, 9)); y = np.arange(len(c))
ax.barh(y - .2, c.rev_share, .4, color=GREY, label="Revenue share"); ax.barh(y + .2, c.profit_share, .4, color=TEAL, label="Profit share")
ax.set_yticks(y); ax.set_yticklabels(c.index); ax.xaxis.set_major_formatter(mtick.PercentFormatter(1.0)); ax.legend()
ax.set_title("Revenue share vs profit share by category (gap = subsidised / quiet-engine)"); save("14_category_share.png")

ret = (items.merge(prods[["product_id", "category_name"]], on="product_id").groupby("category_name")
       .is_returned.mean().sort_values(ascending=False).head(12) * 100)
plt.figure(figsize=(8, 4.5)); plt.barh(ret.index[::-1], ret.values[::-1], color=[RED if v > 15 else NAVY for v in ret.values[::-1]])
plt.xlabel("% of lines returned"); plt.title("Return rate by category (top 12)"); save("15_return_rates.png")

# Margin bridge: why did margin move between the last two years? (mix vs rate effect)
yrs = sorted(ok.order_month.dt.year.unique()); y0, y1 = yrs[-2], yrs[-1]
g = (ok.merge(prods[["product_id", "category_name"]], on="product_id")
     .assign(year=lambda d: d.order_month.dt.year).groupby(["year", "category_name"]).agg(rev=("line_revenue", "sum"), cogs=("line_cogs", "sum")))
g["margin"] = 1 - g.cogs / g.rev; g["share"] = g.rev / g.groupby(level=0).rev.transform("sum")
a, b = g.loc[y0], g.loc[y1]; both = a.index.intersection(b.index)
mix = ((b.share[both] - a.share[both]) * a.margin[both]).sum()
rate = (b.share[both] * (b.margin[both] - a.margin[both])).sum()
tot = (1 - b.cogs.sum() / b.rev.sum()) - (1 - a.cogs.sum() / a.rev.sum())
print(f"Item-margin change {y0}->{y1}: total {tot*100:+.2f} pts = mix {mix*100:+.2f} + rate {rate*100:+.2f}")
plt.figure(figsize=(6, 4)); vals = [mix * 100, rate * 100, tot * 100]
plt.bar(["Mix effect", "Rate effect", "Total"], vals, color=[AMBER, TEAL, NAVY]); plt.axhline(0, c="black", lw=.8)
plt.ylabel("margin points"); plt.title(f"Margin bridge {y0} -> {y1}"); save("16_margin_bridge.png")

# %% 7. Correlation analysis ---------------------------------------------------------------------
cs = (orders.groupby("customer_id").agg(orders=("order_id", "count"), revenue=("net_revenue", "sum"), profit=("gross_profit", "sum"))
      .assign(aov=lambda d: d.revenue / d.orders, repeat=lambda d: (d.orders >= 2).astype(int)))
fo = orders.sort_values("order_date").groupby("customer_id").first()
cs["first_order_value"] = fo.net_revenue; cs["first_order_margin"] = fo.gross_profit / fo.net_revenue
plt.figure(figsize=(7, 5.5)); sns.heatmap(cs.corr(method="spearman"), annot=True, fmt=".2f", cmap="RdBu_r", center=0)
plt.title("Spearman correlation (robust to skew)\ncorrelation is not causation"); save("17_correlation.png")

# %% 8. Exports for Power BI ---------------------------------------------------------------------
rfm["activity_status"] = np.select([rfm.recency_days <= 90, rfm.recency_days <= 180],
                                   ["Active (0-90d)", "At risk (91-180d)"], "Inactive (180d+)")
cust_dim = cust.merge(rfm[["customer_id", "recency_days", "frequency", "monetary", "profit", "r_score", "f_score",
                           "m_score", "segment", "activity_status"]], on="customer_id", how="left")
cust_dim["segment"] = cust_dim.segment.fillna("No purchase")
cust_dim["activity_status"] = cust_dim.activity_status.fillna("Never purchased")
quad = prod.copy(); quad["vol_q"] = pd.qcut(quad.units.rank(method="first"), 4, labels=False) + 1
quad["margin_q"] = pd.qcut(quad.margin.rank(method="first"), 4, labels=False) + 1
quad["quadrant"] = np.select([(quad.vol_q == 4) & (quad.margin_q == 1), (quad.vol_q == 1) & (quad.margin_q == 4),
                              (quad.vol_q == 4) & (quad.margin_q == 4), (quad.vol_q == 1) & (quad.margin_q == 1)],
                             ["High volume / low margin", "High margin / low volume", "Stars", "Dogs"], "Core")
pr = quad.sort_values("profit", ascending=False); pr["cum"] = pr.profit.cumsum() / pr.profit.sum()
quad["pareto_class"] = pd.cut(pr.cum.reindex(quad.index), [0, .8, .95, 10], labels=["A", "B", "C"])
prod_dim = prods.merge(quad[["quadrant", "pareto_class"]], left_on="product_id", right_index=True, how="left")
dates = pd.DataFrame({"Date": pd.date_range(orders.order_date.min().replace(day=1), AS_OF + pd.offsets.MonthEnd(0))})
dates["Year"], dates["Quarter"], dates["Month"] = dates.Date.dt.year, "Q" + dates.Date.dt.quarter.astype(str), dates.Date.dt.strftime("%b")
dates["MonthStart"], dates["MonthNum"] = dates.Date.dt.to_period("M").dt.start_time, dates.Date.dt.month

tables = {"fact_orders": orders.drop(columns=["is_outlier"]).assign(is_outlier=orders.is_outlier),
          "fact_order_items": items, "dim_customer": cust_dim, "dim_product": prod_dim,
          "dim_channel": q("SELECT * FROM clean.marketing_channels"), "dim_date": dates,
          "cohort_retention": coh.drop(columns=["year"]), "dim_rfm_segment": seg.reset_index()[["segment"]]}
for name, df in tables.items():
    df.to_csv(os.path.join(OUT, f"{name}.csv"), index=False); print(f"exported {name:18s} {len(df):>8,d} rows")

# %% 9. Findings log (plain language, each tied to a metric above) ---------------------------------
tot_rev = orders.net_revenue.sum(); ret_rate = cs.repeat.mean()
print("\n=== FINDINGS (this run) ===")
print(f"Revenue INR {tot_rev/1e7:.1f} crore over {orders.order_month.nunique()} months; gross margin {orders.gross_profit.sum()/tot_rev:.1%}")
print(f"Repeat purchase rate {ret_rate:.1%}; customer value concentration (Gini) {gini:.2f}")
print(f"Margin bridge {y0}->{y1}: mix {mix*100:+.2f} pts, rate {rate*100:+.2f} pts")
print(f"Gap percentiles (days): p50 {gaps.quantile(.5):.0f}, p80 {gaps.quantile(.8):.0f}, p90 {gaps.quantile(.9):.0f}")
