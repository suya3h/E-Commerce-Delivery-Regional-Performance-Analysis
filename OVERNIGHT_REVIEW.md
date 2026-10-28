# OVERNIGHT REVIEW — Olist Delivery Analysis

## Completed

- **Database**: MySQL 8.0 running locally on **port 3307**, schema `olist`, four
  tables loaded from `data/Raw/*.csv` (`orders` 99,441 · `order_items` 112,650 ·
  `sellers` 3,095 · `order_reviews` 99,224). Loader: `data/load_mysql.py`
  (creates `VARCHAR(32)` join keys + indexes from the start; verified by
  dropping and rebuilding the DB — subsequent SQL output was byte-identical).
- **Grain validated** on the real data: `orders.order_id` unique (99,441 = 99,441);
  up to 21 items/order; 547 orders with 2–3 review rows; 509 delivered orders
  span 2–3 seller states.
- **Delivery delay** built and validated: 96,470 delivered orders with both dates;
  mean −11.18 d, min −146.02 d, max +188.98 d, 88,644 early / 0 exactly-on-time /
  7,826 late. Extreme early and late rows inspected against purchase timestamps —
  all internally consistent (`purchase ≤ estimate ≤ actual` where applicable);
  0 impossible deliveries. Nothing winsorized, capped, or removed.
- **Correct joins**: all sources pre-aggregated to **one row per order** before
  joining (no `DISTINCT` anywhere). Final analysis set: **95,322 orders**,
  `order_id` unique — asserted in the notebook.
- **State-level analysis**: 22 states with avg delay, late-order share, avg review
  score, 1–2★ share, order volume, and `RANK()` by avg delay (SQL window function,
  mirrored by pandas rank in the notebook).
- **Priority states identified** with actual numbers (SP, RJ, SC; reference RS).
- **Validation**: independent pandas re-computation matches the SQL/MySQL export
  **column-by-column with max difference = 0** (asserted in the notebook);
  re-running `sql/delivery_analysis.sql` after a DB rebuild produced byte-identical
  output; delay-band tables in SQL and notebook now use the same analysis set and match.
- **Deliverables written**: `sql/delivery_analysis.sql` (sections 1–9, runs
  end-to-end), `notebooks/olist_delivery_analysis.ipynb` (executed, no errors),
  `outputs/state_delivery_analysis.csv` (22 states),
  `outputs/state_delivery_review_scatter.png` (one simple chart), `README.md`.
- Delay-band association (order grain): early/on-time **4.20–4.33** avg review vs
  **2.32** (4–7 d late), **1.75** (8–14 d), **1.71** (15+ d); 1–2★ share rises from
  8.7–10.2% to 61.2% and ~78%.

## Manual Verification Required

1. **Re-run `sql/delivery_analysis.sql`** end-to-end and compare section outputs
   against `outputs/state_delivery_analysis.csv`.
2. **Delay calculation**: spot-check a few orders (extreme early/late rows are
   printed in SQL §3 and notebook §4) and confirm the fractional-day method
   (`TIMESTAMPDIFF(SECOND, …)/86400`) matches your intended definition.
3. **Grain decisions**: confirm you agree with excluding the 509 multi-state
   orders and averaging duplicate reviews per order (§ Analytical Decisions).
4. **Priority selection**: SP is unambiguous; the choice of **RJ and SC** as
   priorities 2–3 (with PR as a close fourth) involves judgment — see below.
   Reorder if your reading of "logistics review priority" differs.
5. **Wording**: check README/notebook language claims association only.
6. **Chart**: decide whether `outputs/state_delivery_review_scatter.png` earns
   its place (it is optional by spec).
7. **Leftover files from the earlier attempt** (not deleted, per instructions):
   `Untitled.ipynb`, `notebook/Data_Understanding.ipynb`, `data/Raw.ipynb`,
   `data/cleaned.ipynb`, `exports/`, `reports/`, `.ipynb_checkpoints/`.

## Analytical Decisions

- **Date parsing**: CSV dates are TEXT in `YYYY-MM-DD HH:MM:SS`. Format inspected
  before assuming; parsed with that exact format with an assert of zero failures.
  Delay = (actual − estimated) in seconds / 86400 → fractional days (keeps the
  time-of-day of the actual delivery timestamp). Zero, negative, and extreme
  values all kept.
- **Analytical grain**: **one row per order.** Reviews pre-aggregated to order
  grain as **mean review_score** (handles the 547 orders with 2–3 reviews without
  picking an arbitrary record; the alternative "latest review" was rejected as it
  silently discards a record). Items+sellers pre-aggregated to one seller_state
  per order via `COUNT(DISTINCT seller_state) = 1`.
- **Duplicate handling**: no `DISTINCT` used as a fix; pre-aggregation CTEs instead.
  Demonstrated the problem explicitly: naive orders→items→reviews join = 110,005
  rows vs 96,470 orders (×1.14), which would distort every average.
- **Filtering**: delivered only; both dates non-null (drops 8 orders); orders with
  no review drop out via inner join (768 delivered orders overall); 509
  multi-state delivered orders excluded from state attribution (they have no
  single home state) — 0.53% of delivered orders, documented rather than hidden.
- **Secondary metrics**: `pct_late_orders` (share delivered after estimate) added
  because all state average delays are negative (conservative estimates) and
  average delay alone is dominated by *earliness*; `pct_low_review` (1–2★ share)
  added as the review-side counterpart. Both remain inside the locked question.
- **State filtering / threshold**: ≥1,000 orders, chosen after inspecting the
  volume distribution (67,741 … 1,910, then 799, 543, …, 3). Leaves 6 states =
  96.6% of analyzed orders. All 22 states stay in the CSV; small states are
  flagged, not deleted (e.g., AM: 3 orders, avg review 2.33 — rank 1 by delay but
  meaningless as a finding).
- **Ranking**: `RANK() OVER (ORDER BY avg_delivery_delay DESC)`, worst = 1.
  No composite score used. Priority selection is documented explicitly instead:
  among ≥1,000-order states, delivery-side worst 3 = SP, RJ, MG; review-side
  worst 3 = SP, SC, PR; SP is on both → priority 1; RJ taken from the delivery
  side, SC from the review side; PR (4.213 vs SC 4.209) is a near-tie fourth.

## Final Results

Analysis set: **95,322 delivered orders** (single seller state, with review),
22 states. Overall: 8.0% of these orders arrived late; mean review 4.163.

**Full state table** (identical in SQL, notebook, and
`outputs/state_delivery_analysis.csv`):

| rank | state | volume | avg delay (d) | late % | avg review | 1–2★ % |
|---|---|---|---|---|---|---|
| 1 | AM | 3 | +9.35 | 66.7 | 2.333 | 66.7 |
| 2 | **SP** | 67,741 | −10.44 | 8.7 | **4.133** | 13.2 |
| 3 | PA | 8 | −10.57 | 12.5 | 4.500 | 0.0 |
| 4 | MA | 384 | −10.69 | 22.7 | 4.018 | 15.9 |
| 5 | **RJ** | 4,106 | −11.69 | 8.3 | 4.253 | 11.4 |
| 6 | BA | 543 | −11.92 | 5.7 | 4.206 | 10.7 |
| 7 | RN | 49 | −12.36 | 10.2 | 4.347 | 10.2 |
| 8 | DF | 799 | −12.53 | 6.0 | 4.106 | 14.0 |
| 9 | CE | 84 | −12.60 | 9.5 | 4.310 | 11.9 |
| 10 | ES | 303 | −12.63 | 6.9 | 4.178 | 11.2 |
| 11 | MG | 7,517 | −12.65 | 5.5 | 4.256 | 10.1 |
| 12 | GO | 447 | −13.29 | 4.0 | 4.387 | 7.8 |
| 13 | **SC** | 3,495 | −13.31 | 6.0 | **4.209** | 11.8 |
| 14 | PR | 7,296 | −13.35 | 6.5 | 4.213 | 11.7 |
| 15 | PI | 10 | −13.64 | 0.0 | 4.300 | 10.0 |
| 16 | MT | 133 | −14.95 | 4.5 | 4.218 | 7.5 |
| 17 | PE | 398 | −15.01 | 4.3 | 4.279 | 10.3 |
| 18 | RS | 1,910 | −15.52 | 4.3 | 4.346 | 8.2 |
| 19 | SE | 7 | −17.20 | 0.0 | 4.000 | 14.3 |
| 20 | MS | 45 | −17.33 | 6.7 | 4.533 | 6.7 |
| 21 | PB | 31 | −18.62 | 6.5 | 4.194 | 16.1 |
| 22 | RO | 13 | −21.54 | 0.0 | 3.769 | 30.8 |

**Priority states (≥1,000 orders):**

| state | avg delay | late % | avg review | 1–2★ % | volume | delay rank |
|---|---|---|---|---|---|---|
| **SP** — priority 1 | −10.44 d | 8.7% | 4.133 | 13.2% | 67,741 | 2/22 |
| **RJ** — priority 2 | −11.69 d | 8.3% | 4.253 | 11.4% | 4,106 | 5/22 |
| **SC** — priority 3 | −13.31 d | 6.0% | 4.209 | 11.8% | 3,495 | 13/22 |
| RS — reference (best eligible) | −15.52 d | 4.3% | 4.346 | 8.2% | 1,910 | 18/22 |

- Order-level association: avg review drops from **4.20–4.33** (early/on time) to
  **3.77** (1–3 d late), **2.32** (4–7 d), **1.75** (8–14 d), **1.71** (15+ d);
  1–2★ share 8.7–10.2% → 61.2% → ~78%.
- State-level association: Pearson r(avg delay, avg review) = **−0.75** across all
  22 states, **−0.82** across the six ≥1,000-order states (n=6 — directional only).
- SP vs RS: 5.08 days less early on average, 8.7% vs 4.3% late orders,
  4.133 vs 4.346 review, 13.2% vs 8.2% 1–2★ (≈60% higher poor-review share).
- **Finding (association, not causation):** orders delivered later are associated
  with markedly lower review scores; SP combines the worst relative delivery
  performance among high-volume states with the lowest review score —
  **prioritize SP for logistics review first**, then RJ and SC.

## Remaining Work

- Nothing required for the core analysis to be considered complete.
- Presentation-level only: your judgment on the chart, wording polish in
  README/notebook, and removing the leftover files listed above.

## Potential Issues

- **MySQL instance is a manual background process.** The Windows service could
  not start (no admin rights; service datadir ACL denied), so mysqld runs from a
  temp datadir. Restart command if it dies (e.g., after reboot):
  `"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqld.exe" --basedir="C:\Program Files\MySQL\MySQL Server 8.0" --datadir="C:\Users\suyash\AppData\Local\Temp\opencode\mysql-data" --port=3307 --console --standalone`
  (then `mysql.exe -P 3307 -u root`). **The notebook and CSV do not require the
  DB** — only re-running `sql/delivery_analysis.sql` does; `data/load_mysql.py`
  rebuilds it if the temp datadir is gone.
- **Priority 2–3 selection is judgment, not a rule.** SP is first on both the
  delivery and review dimensions among eligible states; RJ (delivery-side) and
  SC (review-side) were chosen from different dimensions. PR is effectively tied
  with SC (7,296 orders, 4.213 vs 4.209 review, 6.5% vs 6.0% late). If you prefer
  a single-dimension rule, the picks change — worth a look.
- **State-level correlation is fragile**: r = −0.82 comes from only 6 points, and
  state averages are dominated by *earliness* rather than lateness (Olist's
  estimates are conservative). The strong, reliable effect is at the **order**
  level (delay bands). The ecological state-level pattern is directionally
  consistent but modest — do not oversell it.
- **Below-threshold states with concerning numbers** (flagged, not ranked): MA
  (384 orders, 22.7% late, review 4.018) and DF (799 orders, review 4.106, the
  lowest of any state with near-eligible volume). If the threshold were 500,
  DF would enter the eligible set.
- **Multi-state order exclusion** (509 orders, 0.53%) is a simplification; a
  sensitivity check (e.g., attributing them by item count) was not run.
- **Duplicate reviews**: 202 of the 547 multi-review orders have differing scores;
  averaging them is defensible but is a choice.
- **Table names**: the prompts referenced `items`/`reviews`; actual tables are
  `order_items`/`order_reviews` (as in the raw CSVs).
- Old `notebook/`, `exports/`, `reports/`, and stray `.ipynb` files are from the
  previous attempt; they were not deleted or trusted, and none of them feed the
  new analysis.
