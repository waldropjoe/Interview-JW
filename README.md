# The shift that looked covered

Take-home analysis for the Timpani Digital Product Analyst role: what synthetic staffing snapshots say about gaps that close and then come back, and which explanation to test next.

**Live page:** `https://waldropjoe.github.io/Interview-JW/`

## Deliverables

| Deliverable | File |
|---|---|
| Short summary (3 slides) | [`summary.pdf`](summary.pdf), also the three sections at the top of [`index.html`](index.html) |
| Working analysis | [`analysis.sql`](analysis.sql): DuckDB, runs top to bottom, expected result written under every query |
| Tools note | Below, and in the "Tools used" section of the page |

## The story in four lines

1. **Finding:** most shifts that started short had a gap that was closed earlier, then reopened and was never filled again. RN 61 of 68 (90%), PCT 20 of 25 (80%). Every returning gap was still open at shift start.
2. **Explanation:** the target moves, not the people. The requirement rose in 47 of 61 RN returns and 16 of 20 PCT returns, mostly in the final 24 hours.
3. **Ruled out:** "paper" closures returning more (RN 7/21 vs 51/140), early closures being fragile (an exposure effect), and ±1 threshold noise (48% of RN returns were 2 staff short).
4. **Next test:** what drives late requirement increases. Late increases mainly reopen gaps that were closed with no slack (RN 38/59 = 64% vs 9/35 = 26% with one spare person).

## Reproducing the numbers

1. Open [shell.duckdb.org](https://shell.duckdb.org) (or the DuckDB CLI).
2. Add `staffing_snapshots.csv` and `shift_details.csv` with `.files add`. If the browser renames them, adjust the two `read_csv` lines to match `.files list`.
3. Run `analysis.sql` section by section and compare each result with the comment under the query.

The CSVs are not included in this repository (see the note below).

## Tools used

- **DuckDB (browser shell):** all analysis: loading, data checks, first-closure and return logic with window functions, and every breakdown.
- **Claude (AI assistant):** my technical partner under time pressure. It wrote most of the SQL, helped debug it, cross-checked the counts independently in Python and built the page. I also used it as a sounding board: it suggested candidate explanations and checks, and we tested them against the data.
- **My role:** I set the direction, ran the queries, checked results against expected values and individual shifts, pushed back where numbers or denominators didn't reconcile, and decided which findings to lead with and what to recommend. I'm accountable for every number and choice here.


## Publishing on GitHub Pages

1. Create a new repository on GitHub and upload `index.html`, `analysis.sql`, `summary.pdf` and `README.md` to the root (drag and drop works under **Add file → Upload files**).
2. Go to **Settings → Pages**. Under **Build and deployment**, choose **Deploy from a branch**, branch `main`, folder `/ (root)`, and save.
3. After a minute or two the page is live at the address shown on that settings page. Replace the placeholder link at the top of this README with it.

The page is a single self-contained HTML file with no external libraries, fonts or build step.

**Before making it public:** GitHub Pages on a free account needs a public repository, so anyone with the link can see it. The page shows only aggregated results, and the raw CSVs are deliberately left out. If you would rather the assignment material not be public, share `summary.pdf` and `analysis.sql` directly instead.

---
*All data is synthetic. Timpani is a real product; the scenario and data in this exercise are fictional and do not reflect its actual functionality.*
