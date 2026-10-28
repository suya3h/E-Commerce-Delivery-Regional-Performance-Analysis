# E-Commerce Delivery & Regional Performance Analysis

An analysis of the Olist Brazilian E-Commerce dataset answering one business
question: how delivery performance relates to customer review scores, and which
seller regions should be prioritized for logistics review.

## Business Question

> Does delivery delay predict lower customer review scores, and does this
> effect vary meaningfully by seller state/region — which regions should be
> prioritized for logistics review?

Analysis chain: **delivery delay → customer review score → seller state.**
The analysis establishes association, not causation.

## Objective

Determine whether delivery performance is associated with customer
satisfaction, and identify seller states that should be prioritized for
logistics review.

## Data / Dataset

**Source:** [Olist Brazilian E-Commerce Dataset (Kaggle)](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce).
The raw dataset is **not committed to this repository** (it belongs to the
original publisher and is larger than the analysis code needs). To reproduce:

1. Download the dataset from Kaggle.
2. Place the CSVs in `data/Raw/` locally (the folder is git-ignored).
3. Load them into MySQL: `python data/load_mysql.py`
   (connection via `MYSQL_HOST` / `MYSQL_PORT` / `MYSQL_USER` /
   `MYSQL_PASSWORD` environment variables; defaults: `127.0.0.1:3307`,
   user `root`, empty password — no credentials are stored in the repo).

Only four tables are used:

| Table | Rows | Role |
|---|---|---|
| `olist_orders_dataset.csv` | 99,441 | delivery dates, order status |
| `olist_order_items_dataset.csv` | 112,650 | order → seller link (item grain) |
| `olist_sellers_dataset.csv` | 3,095 | seller state |
| `olist_order_reviews_dataset.csv` | 99,224 | review score (1–5) |

No geolocation, product, payment, or customer tables are used.

## Methodology

### Delivery-delay definition

```
delivery_delay = order_delivered_customer_date − order_estimated_delivery_date
```

- positive = delivered late · zero = on estimated date · negative = delivered early
- Only `order_status = 'delivered'` orders with both dates non-null (96,470 of 96,478).
- CSV date columns are TEXT; inspected first (format `YYYY-MM-DD HH:MM:SS`),
  parsed with that exact format, zero parse failures, then computed in days.
- No zero, negative, or extreme values were removed. Extreme early/late cases
  were inspected against purchase timestamps and kept (all internally consistent).

### Join / grain handling

Grain validated before any aggregation:

- `orders`: one row per order (`order_id` unique).
- `order_items`: up to **21 items per order** — a naive join duplicates orders.
- `order_reviews`: **547 orders have 2–3 review rows**.
- **509 delivered orders span 2–3 seller states** — they have no single home state.

Each source is therefore **pre-aggregated to order grain before joining**
(CTEs in SQL / `groupby` in the notebook):

1. items ⋈ sellers → one `seller_state` per order (only `COUNT(DISTINCT state) = 1` kept).
2. reviews → mean `review_score` per order.
3. Inner join with delayed orders → final analytical grain: **one row per order**
   (95,322 orders). `DISTINCT` is never used to hide duplication.

Resulting metrics (`order_volume`, `avg_delivery_delay`, `avg_review_score`)
represent orders, not item rows.

### State-level analysis and ranking

- Per state: average delivery delay, share of late orders, average review score,
  share of 1–2★ reviews, order volume.
- Ranking: MySQL `RANK() OVER (ORDER BY avg_delivery_delay DESC)` (worst = 1).
- Minimum-volume threshold for comparing states: **≥ 1,000 orders**, chosen after
  inspecting the volume distribution (SP 67,741 vs AM 3). Six states meet it —
  92,065 of 95,322 analyzed orders (96.6%). All 22 states remain in the output CSV;
  small states are flagged as small-sample, not deleted.

### SQL approach

`sql/delivery_analysis.sql` (MySQL 8) is the reproducible analysis, in order:
data-quality checks → delay calculation + extreme-value inspection → grain/duplicate
checks → CTE join construction → state aggregation → `RANK()` window function →
priority-state output (≥1,000 orders) → validation queries (volume distribution,
delay-band association, sample records).

Setup: `data/load_mysql.py` loads the four CSVs into MySQL (`olist` schema) with
join-key columns typed `VARCHAR(32)` and indexed — the first load used unindexed
TEXT columns and caused join timeouts. Connection settings come from environment
variables (`MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`); nothing
credential-like is committed.

The notebook does **not** require the database: it computes the analysis
independently in pandas from `data/Raw/` and asserts it matches the SQL/MySQL
export column-by-column (max difference = 0).

## Key Findings

**Delivery delay is strongly associated with review scores (order level):**

| Delay band | Orders | Avg review | 1–2★ share |
|---|---|---|---|
| Early ≤ −7d | 70,456 | 4.33 | 8.7% |
| Early/on-time −7d..0d | 17,209 | 4.20 | 10.2% |
| Late 1–3d | 2,634 | 3.77 | 19.0% |
| Late 4–7d | 1,771 | 2.32 | 61.2% |
| Late 8–14d | 1,748 | 1.75 | 78.0% |
| Late 15d+ | 1,504 | 1.71 | 78.7% |

**State level (≥1,000 orders):** higher average delay goes with lower average
review score (Pearson r = −0.82 across the six eligible states; r = −0.75 across
all 22 — directional evidence, small n).

Priority states (full table in `outputs/state_delivery_analysis.csv`):

| State | Avg delay (d) | Late orders | Avg review | 1–2★ | Volume | Delay rank |
|---|---|---|---|---|---|---|
| **SP** (priority 1) | −10.44 | 8.7% | 4.133 | 13.2% | 67,741 | 2 / 22 |
| **RJ** (priority 2) | −11.69 | 8.3% | 4.253 | 11.4% | 4,106 | 5 / 22 |
| **SC** (priority 3) | −13.31 | 6.0% | 4.209 | 11.8% | 3,495 | 13 / 22 |
| RS (reference, best eligible) | −15.52 | 4.3% | 4.346 | 8.2% | 1,910 | 18 / 22 |

All state averages are negative because Olist's estimated delivery dates are
conservative — most orders arrive early; `pct_late_orders` is the sharper
delivery-failure measure.

## Recommendation

Prioritize **SP** for logistics review first: it is worst among high-volume
states on delivery delay (−10.44 days average, delay rank 2/22, 8.7% of 67,741
orders late) and has the lowest review score (4.133 vs the 4.346 best-state
reference, 13.2% vs 8.2% 1–2★ reviews) — a meaningful association between
delivery performance and customer satisfaction. Then **RJ** (delay rank 5,
8.3% late) and **SC** (review 4.209), with PR (7,296 orders, 4.213 review) a
close fourth. This is an association, not a demonstrated causal effect.

## Project Structure

```
├── data/
│   ├── Raw/                       # original Olist CSVs (local only; git-ignored)
│   └── load_mysql.py              # loads the 4 tables into MySQL with correct schema/indexes
├── notebooks/
│   └── olist_delivery_analysis.ipynb   # full analysis (pandas, cross-checked vs SQL output)
├── sql/
│   └── delivery_analysis.sql      # reproducible MySQL analysis (sections 1–9)
├── outputs/
│   ├── state_delivery_analysis.csv     # final state-level result (22 states)
│   └── state_delivery_review_scatter.png
├── README.md
└── OVERNIGHT_REVIEW.md
```

## Tools

- MySQL 8.0 (local instance, schema `olist`)
- Python 3.14 — pandas, matplotlib; nbformat/nbclient for the executed notebook
- Jupyter, Git/GitHub
