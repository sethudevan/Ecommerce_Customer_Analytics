#!/usr/bin/env python3
"""
generate_data.py  --  synthetic data for "Kaveri Living Co." (fictional online home & lifestyle retailer)

Creates seven MESSY raw CSVs in data/raw/ (marketing_channels, categories, products, customers,
orders, order_items, payments) and a private ground-truth file in data/_ground_truth/.

The data is SYNTHETIC. Behaviour (loyalty, channel quality, seasonality, returns, shipping cost) is
simulated with known parameters so you can test whether your SQL/Python recovers it. Realistic
data-quality problems are injected afterwards (see inject_* functions).

Usage:   python python/generate_data.py --customers 60000 --seed 42
Needs:   numpy, pandas
Do NOT present planted patterns as real-world findings. Keep data/_ground_truth/ out of git.
"""
import argparse, json, os
import numpy as np
import pandas as pd

DATA_START = pd.Timestamp("2023-01-01")
DATA_END = pd.Timestamp("2025-12-31")

# ----------------------------------------------------------------------------- reference data
CHANNELS = [  # id, name, type, share, conversion to first order, retention quality, monthly spend (INR)
    (1, "Organic Search", "Organic", 0.22, 0.90, 1.15, 150000),
    (2, "Paid Search", "Paid", 0.20, 0.88, 1.00, 900000),
    (3, "Social Ads", "Paid", 0.22, 0.80, 0.55, 850000),      # planted: high volume, weak retention
    (4, "Email", "Owned", 0.07, 0.92, 1.35, 120000),
    (5, "Referral", "Referral", 0.09, 0.93, 1.30, 200000),
    (6, "Affiliates", "Paid", 0.08, 0.85, 0.85, 400000),
    (7, "Marketplace", "Paid", 0.05, 0.88, 0.65, 300000),
    (8, "Direct", "Organic", 0.07, 0.91, 1.25, 0),
]
# parent, category, base margin, mean list price, return prob, popularity weight
CATEGORIES = [
    ("Kitchen", "Cookware", .38, 1400, .03, 1.4), ("Kitchen", "Dinnerware", .45, 1100, .05, 1.0),
    ("Kitchen", "Storage & Organization", .48, 600, .02, 1.2), ("Kitchen", "Small Appliances", .14, 2800, .06, 1.1),  # planted: low margin
    ("Kitchen", "Cutlery", .42, 500, .02, .8), ("Kitchen", "Bakeware", .44, 700, .02, .6),
    ("Home Decor", "Wall Art", .58, 900, .05, .9), ("Home Decor", "Vases & Planters", .55, 650, .07, .8),
    ("Home Decor", "Candles & Fragrance", .60, 450, .02, 1.3), ("Home Decor", "Clocks", .50, 900, .04, .5),
    ("Home Decor", "Mirrors", .46, 1600, .08, .5), ("Home Decor", "Photo Frames", .56, 400, .03, .7),
    ("Furniture", "Chairs", .30, 4500, .10, .5), ("Furniture", "Tables", .28, 7500, .11, .4),
    ("Furniture", "Shelving", .33, 3800, .09, .5), ("Furniture", "Storage Furniture", .31, 6200, .10, .4),
    ("Bedding & Bath", "Bedsheets", .52, 1300, .04, 1.3), ("Bedding & Bath", "Cushions", .57, 550, .03, 1.0),
    ("Bedding & Bath", "Towels", .50, 700, .02, 1.0), ("Bedding & Bath", "Bath Accessories", .54, 450, .03, .7),
    ("Bedding & Bath", "Blankets", .47, 1800, .03, .6),
    ("Lighting", "Table Lamps", .44, 1300, .22, .8),             # planted: high return rate
    ("Lighting", "Ceiling Lights", .36, 3200, .09, .5), ("Lighting", "String Lights", .59, 400, .03, .9),
    ("Lighting", "Outdoor Lighting", .40, 1700, .07, .4),
    ("Cleaning", "Cleaning Tools", .50, 350, .02, 1.0), ("Cleaning", "Laundry", .46, 450, .02, .8),
    ("Outdoor", "Garden Tools", .43, 650, .03, .5), ("Outdoor", "Outdoor Furniture", .29, 6800, .10, .3),
    ("Outdoor", "Grills", .27, 5200, .08, .3),
]
REGIONS = {  # standard name: (country, weight, shipping-cost factor, cities, variants used for corruption)
    "Maharashtra": ("India", .17, 1.0, ["Mumbai", "Pune", "Nagpur"], ["MH", "maharashtra", "Maharastra"]),
    "Karnataka": ("India", .14, 1.0, ["Bengaluru", "Mysuru", "Hosur"], ["KA", "karnataka", "Karnataka "]),
    "Tamil Nadu": ("India", .12, 1.0, ["Chennai", "Coimbatore", "Hosur"], ["TN", "tamil nadu", "Tamilnadu"]),
    "Delhi": ("India", .11, 1.0, ["New Delhi", "Dwarka"], ["DL", "delhi", "New Delhi"]),
    "Telangana": ("India", .07, 1.0, ["Hyderabad", "Warangal"], ["TS", "telangana", "Telengana"]),
    "Gujarat": ("India", .06, 1.05, ["Ahmedabad", "Surat"], ["GJ", "gujarat"]),
    "West Bengal": ("India", .05, 1.15, ["Kolkata", "Siliguri"], ["WB", "west bengal"]),
    "Uttar Pradesh": ("India", .08, 1.1, ["Lucknow", "Noida", "Kanpur"], ["UP", "uttar pradesh"]),
    "Kerala": ("India", .04, 1.05, ["Kochi", "Thiruvananthapuram"], ["KL", "kerala"]),
    "Rajasthan": ("India", .025, 1.15, ["Jaipur", "Jodhpur"], ["RJ", "rajasthan"]),
    "Punjab": ("India", .02, 1.1, ["Ludhiana", "Amritsar"], ["PB", "punjab"]),
    "Assam": ("India", .015, 1.8, ["Guwahati"], ["AS", "assam"]),                       # planted: high shipping cost
    "Dubai": ("UAE", .03, 3.0, ["Dubai"], ["dubai", "DXB"]),
    "Singapore": ("Singapore", .02, 3.0, ["Singapore"], ["singapore", "SG"]),
}
COUNTRY_VARIANTS = {"India": ["IN", "india", "Bharat", "INDIA "], "UAE": ["United Arab Emirates", "ae", "U.A.E"],
                    "Singapore": ["SG", "singapore"]}
FIRST_NAMES = ["Anita", "Rahul", "Priya", "Arjun", "Meera", "Vikram", "Sneha", "Karthik", "Divya", "Rohan", "Kavya",
               "Aditya", "Neha", "Suresh", "Lakshmi", "Imran", "Pooja", "Nikhil", "Ayesha", "Manoj", "Deepa", "Sanjay"]
BRANDS = ["Kaveri Home", "Kaveri Home", "Kaveri Home", "UrbanNest", "CasaLuxe", "HearthCo", "BrightHome", "TerraLiving"]
ADJ = ["Classic", "Modern", "Premium", "Essential", "Artisan", "Compact", "Deluxe", "Signature", "Everyday", "Eco"]
PAY_METHODS = ["UPI", "Card", "COD", "Wallet"]


def pick(rng, items, p=None, size=None):
    return rng.choice(items, size=size, p=p)


# ----------------------------------------------------------------------------- clean "truth" tables
def build_reference(rng, n_products):
    channels = pd.DataFrame(CHANNELS, columns=["channel_id", "channel_name", "channel_type", "share", "conv", "quality",
                                                 "monthly_spend"])
    cats = pd.DataFrame(CATEGORIES, columns=["parent_category", "category_name", "margin", "mean_price", "return_p", "pop"])
    cats.insert(0, "category_id", np.arange(1, len(cats) + 1))
    w = cats["pop"].values / cats["pop"].sum()
    cat_ids = rng.choice(cats.category_id, size=n_products, p=w)
    prod = pd.DataFrame({"product_id": np.arange(1001, 1001 + n_products), "category_id": cat_ids})
    prod = prod.merge(cats[["category_id", "category_name", "margin", "mean_price"]], on="category_id")
    prod = prod.sort_values("product_id").reset_index(drop=True)
    price = rng.lognormal(mean=np.log(prod.mean_price) - 0.18, sigma=0.6)
    prod["list_price"] = np.maximum(99, (price // 10) * 10 + 9).round(2)
    prod["unit_cost"] = (prod.list_price * (1 - prod.margin + rng.normal(0, 0.03, len(prod)))).clip(lower=20).round(2)
    prod["brand"] = rng.choice(BRANDS, len(prod))
    prod["product_name"] = [f"{rng.choice(ADJ)} {c} {i}" for i, c in zip(prod.product_id, prod.category_name)]
    prod["launch_date"] = (pd.Timestamp("2022-01-01") + pd.to_timedelta(rng.integers(0, 365, len(prod)), unit="D")).date
    prod["popularity"] = rng.lognormal(0, 1.1, len(prod)) * prod.category_id.map(dict(zip(cats.category_id, cats["pop"])))
    return channels, cats, prod


def build_customers(rng, n, channels):
    months = pd.date_range(DATA_START, DATA_END, freq="MS")
    growth = np.linspace(0.7, 1.5, len(months))
    season = np.array([1.0, .9, .95, .95, 1.0, .95, .95, 1.05, 1.1, 1.3, 1.35, 1.2])[months.month - 1]
    mw = growth * season; mw /= mw.sum()
    signup_month = rng.choice(months, size=n, p=mw)
    signup = pd.to_datetime(signup_month) + pd.to_timedelta(rng.integers(0, 28, n), unit="D")
    reg_names = list(REGIONS)
    reg_w = np.array([REGIONS[r][1] for r in reg_names]); reg_w /= reg_w.sum()
    region = rng.choice(reg_names, n, p=reg_w)
    city = [rng.choice(REGIONS[r][3]) for r in region]
    ch = rng.choice(channels.channel_id, n, p=channels.share.values)
    cid = np.arange(10001, 10001 + n)
    names = rng.choice(FIRST_NAMES, n)
    cust = pd.DataFrame({
        "customer_id": cid, "first_name": names,
        "email": [f"{nm.lower()}.{i}@example.com" for nm, i in zip(names, cid)],
        "phone": rng.integers(7_000_000_000, 9_999_999_999, n).astype(str),
        "signup_date": signup.date, "country": [REGIONS[r][0] for r in region], "region": region, "city": city,
        "channel_id": ch, "gender": rng.choice(["F", "M", "O"], n, p=[.55, .43, .02]),
    })
    return cust


def simulate_orders(rng, cust, channels, cats, prod):
    """Customer behaviour -> orders, order_items, payments (clean truth)."""
    q = channels.set_index("channel_id").quality.to_dict()
    conv = channels.set_index("channel_id").conv.to_dict()
    n = len(cust)
    loyalty = rng.gamma(1.4, 1 / 1.4, n)
    cust = cust.assign(loyalty=loyalty)
    rows = []
    for cid, su, chn, loy in zip(cust.customer_id, pd.to_datetime(cust.signup_date), cust.channel_id, loyalty):
        if rng.random() > conv[chn]:
            continue
        d = su + pd.Timedelta(days=float(rng.exponential(5)))
        qual = q[chn] * loy ** 0.5
        p_stop = float(np.clip(0.33 / qual, 0.08, 0.85))
        mean_gap = 75 / max(0.4, loy ** 0.5 * q[chn])
        while d <= DATA_END + pd.Timedelta(hours=23):
            rows.append((cid, d + pd.Timedelta(minutes=int(rng.integers(0, 1440))), chn))
            if rng.random() < p_stop:
                break
            d = d + pd.Timedelta(days=max(3.0, float(rng.gamma(2, mean_gap / 2))))
    o = pd.DataFrame(rows, columns=["customer_id", "order_date", "channel_id"])
    o = o[o.order_date <= DATA_END + pd.Timedelta(hours=23, minutes=59)].reset_index(drop=True)
    o = o.sort_values("order_date").reset_index(drop=True)
    o["order_id"] = np.arange(700001, 700001 + len(o))
    o = o.merge(cust[["customer_id", "region"]], on="customer_id", how="left").rename(columns={"region": "delivery_region"})
    o["n_items"] = np.minimum(6, 1 + rng.poisson(1.3, len(o)))

    # ----- lines
    li = o.loc[o.index.repeat(o.n_items), ["order_id", "order_date", "channel_id"]].reset_index(drop=True)
    pw = prod.popularity.values / prod.popularity.sum()
    pidx = rng.choice(len(prod), len(li), p=pw)
    li["product_id"] = prod.product_id.values[pidx]
    li["list_price"] = prod.list_price.values[pidx]
    li["unit_cost"] = prod.unit_cost.values[pidx]
    li["category_id"] = prod.category_id.values[pidx]
    li["quantity"] = np.where(rng.random(len(li)) < 0.12, 2, 1) + (rng.random(len(li)) < 0.02) * 2
    month = li.order_date.dt.month.values
    festive = np.isin(month, [10, 11, 1])
    disc_p = np.where(festive, 0.55, 0.15) + np.where(li.channel_id.values == 3, 0.10, 0)   # social-ad buyers discounted more
    depth = np.where(festive, rng.uniform(.15, .35, len(li)), rng.uniform(.05, .15, len(li))) + np.where(li.channel_id.values == 3, .05, 0)
    disc = np.where(rng.random(len(li)) < disc_p, depth, 0.0)
    li["unit_price"] = (li.list_price * (1 - disc)).round(2)
    li["line_discount"] = 0.0
    ret_p = li.category_id.map(dict(zip(cats.category_id, cats.return_p))).values
    li["is_returned"] = rng.random(len(li)) < ret_p
    li["order_item_id"] = np.arange(1500001, 1500001 + len(li))

    # ----- order totals / status / shipping
    cancelled = rng.random(len(o)) < 0.04
    o["order_status"] = np.where(cancelled, "Cancelled", "Completed")
    li["is_returned"] = li.is_returned & ~li.order_id.isin(o.order_id[cancelled])
    sub = (li.quantity * li.unit_price).groupby(li.order_id).sum()
    o["subtotal"] = o.order_id.map(sub).round(2)
    all_ret = li.groupby("order_id").is_returned.all()
    o["all_returned"] = o.order_id.map(all_ret)
    status_ret = (o.all_returned) & (~cancelled)
    refunded = status_ret & (rng.random(len(o)) < 0.3)
    o.loc[status_ret, "order_status"] = "Returned"
    o.loc[refunded, "order_status"] = "Refunded"
    o["shipping_fee"] = np.where(o.subtotal >= 999, 0.0, 49.0)
    factor = o.delivery_region.map({k: v[2] for k, v in REGIONS.items()})
    o["shipping_cost"] = (rng.normal(75, 15, len(o)).clip(40, 140) * factor).round(2)
    o["order_discount"] = np.where(rng.random(len(o)) < 0.08, rng.integers(50, 301, len(o)), 0).astype(float)
    o["order_discount"] = np.minimum(o.order_discount, (o.subtotal * 0.2).round(0))

    # ----- payments
    amt = (o.subtotal - o.order_discount + o.shipping_fee).round(2)
    pay = pd.DataFrame({"order_id": o.order_id, "payment_method": rng.choice(PAY_METHODS, len(o), p=[.5, .3, .15, .05]),
                        "payment_status": np.where(cancelled, "Failed", "Success"),
                        "amount": np.where(cancelled, 0.0, amt), "payment_date": o.order_date + pd.Timedelta(minutes=2)})
    rf = o.order_status.isin(["Returned", "Refunded"]).values
    refund = pay[rf].copy()
    refund["payment_status"] = "Refunded"; refund["amount"] = -refund["amount"]
    refund["payment_date"] = refund.payment_date + pd.Timedelta(days=7)
    pay = pd.concat([pay, refund], ignore_index=True)
    pay.insert(0, "payment_id", np.arange(900001, 900001 + len(pay)))
    return o, li, pay


# ----------------------------------------------------------------------------- inject data-quality problems
def variant_region(rng, r):
    v = REGIONS.get(r, ("", 0, 0, [], []))[4]
    return rng.choice(v) if v else r


def inject_all(rng, ch, cats, prod, cust, o, li, pay):
    log = {}
    # ---- categories: dirty duplicates (inconsistent names)
    craw = cats[["category_id", "category_name", "parent_category"]].copy()
    dirty = [(1, "COOKWARE"), (2, "dinner ware "), (4, "Small  appliances"), (7, "wall art"), (22, "TABLE LAMPS"), (17, "bedsheets")]
    extra = pd.DataFrame([(31 + i, nm, craw.loc[craw.category_id == cid, "parent_category"].iloc[0])
                          for i, (cid, nm) in enumerate(dirty)], columns=craw.columns)
    craw = pd.concat([craw, extra], ignore_index=True)
    praw = prod[["product_id", "product_name", "category_id", "brand", "unit_cost", "list_price", "launch_date"]].copy()
    for i, (cid, _) in enumerate(dirty):
        m = (praw.category_id == cid) & (rng.random(len(praw)) < 0.10)
        praw.loc[m, "category_id"] = 31 + i
    # ---- products: missing category / cost
    m = rng.random(len(praw)) < 0.02; praw.loc[m, "category_id"] = np.nan; log["products_null_category"] = int(m.sum())
    m = rng.random(len(praw)) < 0.015; praw.loc[m, "unit_cost"] = np.nan; log["products_null_cost"] = int(m.sum())
    praw["category_id"] = praw.category_id.astype("Int64")   # keep ids as integers in the CSV (no "22.0")

    # ---- customers: duplicates, missing info, inconsistent country / region / date formats
    craw_c = cust[["customer_id", "first_name", "email", "phone", "signup_date", "country", "region", "city", "channel_id", "gender"]].copy()
    ndup = int(0.015 * len(craw_c))
    src = craw_c.sample(ndup, random_state=int(rng.integers(1e9))).copy()
    new_ids = np.arange(craw_c.customer_id.max() + 1, craw_c.customer_id.max() + 1 + ndup)
    mapping = dict(zip(src.customer_id, new_ids))
    src["customer_id"] = new_ids
    src["email"] = [e.upper() if rng.random() < .3 else e for e in src.email]
    src["first_name"] = [s.lower() if rng.random() < .4 else s for s in src.first_name]
    log["customers_duplicated"] = ndup
    # move ~40% of the original customers' orders onto the duplicate id
    mv = o.customer_id.isin(mapping.keys()) & (rng.random(len(o)) < .4)
    o.loc[mv, "customer_id"] = o.loc[mv, "customer_id"].map(mapping)
    craw_c = pd.concat([craw_c, src], ignore_index=True)
    for col, p in [("email", .06), ("phone", .04), ("region", .03)]:
        m = (rng.random(len(craw_c)) < p) & ~craw_c.customer_id.isin(new_ids) if col == "email" else rng.random(len(craw_c)) < p
        craw_c.loc[m, col] = np.nan
    m = rng.random(len(craw_c)) < .08
    craw_c.loc[m, "country"] = [rng.choice(COUNTRY_VARIANTS[c]) for c in craw_c.loc[m, "country"]]
    m = (rng.random(len(craw_c)) < .10) & craw_c.region.notna()
    craw_c.loc[m, "region"] = [variant_region(rng, r) for r in craw_c.loc[m, "region"]]
    sd = pd.to_datetime(craw_c.signup_date)
    craw_c["signup_date"] = sd.dt.strftime("%Y-%m-%d")
    m = rng.random(len(craw_c)) < .03
    craw_c.loc[m, "signup_date"] = sd[m].dt.strftime("%d-%m-%Y")

    # ---- orders: date formats, invalid dates, status case, region variants, exact duplicate rows
    oraw = o[["order_id", "customer_id", "order_date", "order_status", "shipping_fee", "shipping_cost", "order_discount", "delivery_region"]].copy()
    od = pd.to_datetime(oraw.order_date)
    oraw["order_date"] = od.dt.strftime("%Y-%m-%d %H:%M:%S")
    m = rng.random(len(oraw)) < .03; oraw.loc[m, "order_date"] = od[m].dt.strftime("%d-%m-%Y %H:%M:%S")
    m = rng.random(len(oraw)) < .002; oraw.loc[m, "order_date"] = "1900-01-01 00:00:00"; log["orders_1900_dates"] = int(m.sum())
    m = rng.random(len(oraw)) < .001; oraw.loc[m, "order_date"] = "2031-05-17 10:00:00"; log["orders_future_dates"] = int(m.sum())
    m = rng.random(len(oraw)) < .05
    oraw.loc[m, "order_status"] = [rng.choice([s.lower(), s.upper(), s + " "]) for s in oraw.loc[m, "order_status"]]
    m = rng.random(len(oraw)) < .08
    oraw.loc[m, "delivery_region"] = [variant_region(rng, r) for r in oraw.loc[m, "delivery_region"]]
    dup_o = oraw.sample(int(.005 * len(oraw)), random_state=int(rng.integers(1e9)))
    log["orders_exact_duplicates"] = len(dup_o)

    # ---- order items
    iraw = li[["order_item_id", "order_id", "product_id", "quantity", "unit_price", "line_discount", "is_returned"]].copy()
    iraw["quantity"] = iraw.quantity.astype(int).astype(str)
    iraw["unit_price"] = iraw.unit_price.map("{:.2f}".format)
    m = rng.random(len(iraw)) < .01
    iraw.loc[m, "unit_price"] = ["₹" + f"{float(x):,.2f}" for x in iraw.loc[m, "unit_price"]]; log["items_currency_text_price"] = int(m.sum())
    m = rng.random(len(iraw)) < .001; iraw.loc[m, "quantity"] = "-1"; log["items_negative_qty"] = int(m.sum())
    m = rng.random(len(iraw)) < .0005; iraw.loc[m, "unit_price"] = "0"; log["items_zero_price"] = int(m.sum())
    m = rng.random(len(iraw)) < .0005; iraw.loc[m, "quantity"] = "200"; log["items_bulk_outliers"] = int(m.sum())
    iraw["is_returned"] = [rng.choice(["true", "t", "1", "Y"]) if v else rng.choice(["false", "f", "0", "N"]) for v in iraw.is_returned]
    dup_i = iraw[iraw.order_id.isin(dup_o.order_id)]
    oraw = pd.concat([oraw, dup_o], ignore_index=True).sample(frac=1, random_state=1).reset_index(drop=True)
    iraw = pd.concat([iraw, dup_i], ignore_index=True)

    praw_pay = pay.copy()
    praw_pay["amount"] = praw_pay.amount.map("{:.2f}".format)
    praw_pay["payment_date"] = pd.to_datetime(praw_pay.payment_date).dt.strftime("%Y-%m-%d %H:%M:%S")
    chraw = ch[["channel_id", "channel_name", "channel_type", "monthly_spend"]].copy()
    return dict(marketing_channels=chraw, categories=craw, products=praw, customers=craw_c,
                orders=oraw, order_items=iraw, payments=praw_pay), log


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--customers", type=int, default=60000)
    ap.add_argument("--products", type=int, default=1500)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--outdir", default="data/raw")
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    ch, cats, prod = build_reference(rng, a.products)
    cust = build_customers(rng, a.customers, ch)
    o, li, pay = simulate_orders(rng, cust, ch, cats, prod)
    tables, log = inject_all(rng, ch, cats, prod, cust, o, li, pay)
    os.makedirs(a.outdir, exist_ok=True)
    for name, df in tables.items():
        df.to_csv(os.path.join(a.outdir, f"{name}.csv"), index=False)
        print(f"{name:20s} {len(df):>9,d} rows")
    print(f"{'TOTAL':20s} {sum(len(d) for d in tables.values()):>9,d} rows")
    gt = os.path.join(os.path.dirname(a.outdir.rstrip('/')) or ".", "_ground_truth")
    os.makedirs(gt, exist_ok=True)
    with open(os.path.join(gt, "planted_patterns.json"), "w") as f:
        json.dump({"note": "PRIVATE. Patterns planted in the synthetic data; never present as real findings.",
                   "planted": ["Social Ads: high volume, weakest retention, deeper discounts",
                               "Small Appliances: low margin (~14%)", "Table Lamps: ~22% return rate",
                               "Assam / Dubai / Singapore: high shipping cost", "Festive months (Oct, Nov, Jan): heavier discounts"],
                   "injected_issues": log}, f, indent=2)
    print("Injected issue counts:", log)


if __name__ == "__main__":
    main()
