-- =====================================================================
-- Returning staffing gaps: working analysis
-- Assignment take-home (synthetic data) | Joe Waldrop
-- Tool: DuckDB (browser shell at shell.duckdb.org, or the DuckDB CLI)
--
-- The file follows the same order as the summary:
--   0. Load data
--   1. Data checks (does the data reconcile?)
--   2. Core metric (first eligible closure and return)
--   3. Story 1: most shifts that start short had already looked covered
--   4. Story 2: the target moves, not the people (+ explanations ruled out)
--   5. Story 3: which gaps come back (slack at closure x later increase)
--
-- Expected results are written under each query, so the file can be
-- followed without running it. RN and PCT are never combined.
-- =====================================================================


-- =====================================================================
-- 0. LOAD DATA
-- unit_id is forced to text: values like 45021_61221 can otherwise be
-- read as the number 4502161221. In the browser shell, add the CSVs with
-- .files add and use the exact names shown by .files list.
-- =====================================================================

CREATE OR REPLACE TABLE snapshots AS
SELECT * FROM read_csv('staffing_snapshots.csv', types = {'unit_id': 'VARCHAR'});

CREATE OR REPLACE TABLE shifts AS
SELECT * FROM read_csv('shift_details.csv', types = {'unit_id': 'VARCHAR'});


-- =====================================================================
-- 1. DATA CHECKS
-- =====================================================================

-- 1a. Row counts match the data dictionary
SELECT 'snapshots' AS tbl, COUNT(*) AS n FROM snapshots
UNION ALL
SELECT 'shifts', COUNT(*) FROM shifts;
-- Result: snapshots 1,848 | shifts 211  [pass]

-- 1b. Why 1,848 rows? 211 shifts x 2 roles x 7 snapshots would be 2,954.
--     Most shifts track only one role.
SELECT CASE WHEN n_roles = 2 THEN 'RN + PCT' ELSE only_role || ' only' END AS roles_tracked,
       COUNT(*) AS n_shifts
FROM (
    SELECT unit_id, shift_id,
           COUNT(DISTINCT staff_role) AS n_roles,
           MIN(staff_role)            AS only_role
    FROM snapshots
    GROUP BY unit_id, shift_id
) t
GROUP BY 1
ORDER BY 2 DESC;
-- Result: RN only 141 | RN + PCT 53 | PCT only 17
--         141 + 17 + (53 x 2) = 264 unit/shift/role groups x 7 = 1,848 rows  [reconciles]

-- 1c. No duplicate observation keys
SELECT unit_id, shift_id, staff_role, snapshot_timestamp, COUNT(*) AS n
FROM snapshots
GROUP BY unit_id, shift_id, staff_role, snapshot_timestamp
HAVING COUNT(*) > 1;
-- Result: 0 rows  [pass]

-- 1d. Every unit/shift/role group has all 7 snapshots
SELECT n_snapshots, COUNT(*) AS n_groups
FROM (
    SELECT unit_id, shift_id, staff_role, COUNT(*) AS n_snapshots
    FROM snapshots
    GROUP BY unit_id, shift_id, staff_role
) t
GROUP BY n_snapshots;
-- Result: 7 snapshots | 264 groups. No incomplete groups to drop.  [pass]

-- 1e. Joining on BOTH unit_id and shift_id keeps every snapshot (no orphans)
SELECT COUNT(*) AS total_rows,
       SUM(CASE WHEN sh.shift_id IS NULL THEN 1 ELSE 0 END) AS unmatched_rows
FROM snapshots s
LEFT JOIN shifts sh
  ON s.unit_id = sh.unit_id AND s.shift_id = sh.shift_id;
-- Result: 1,848 rows | 0 unmatched  [pass]

-- 1f. open_need_count = MAX(required - available, 0) on every row
SELECT COUNT(*) AS mismatches
FROM snapshots
WHERE open_need_count <> GREATEST(required_staff - available_staff, 0);
-- Result: 0  [pass]


-- =====================================================================
-- 2. CORE METRIC
-- =====================================================================

-- 2a. Working view: snapshots + shift details + hours before start,
--     with the previous snapshot's values for the same unit/shift/role.
--     Ordered by timestamp (oldest first) so LAG returns the EARLIER
--     snapshot. Ordering by hours_before_start ascending would reverse time.
CREATE OR REPLACE VIEW snap AS
SELECT s.*,
       sh.unit_name,
       sh.shift_time_of_day,
       date_diff('hour', s.snapshot_timestamp, sh.shift_start_timestamp) AS hours_before_start,
       LAG(s.open_need_count) OVER w AS prev_open_need,
       LAG(s.required_staff)  OVER w AS prev_required,
       LAG(s.available_staff) OVER w AS prev_available
FROM snapshots s
JOIN shifts sh
  ON s.unit_id = sh.unit_id AND s.shift_id = sh.shift_id
WINDOW w AS (PARTITION BY s.unit_id, s.shift_id, s.staff_role
             ORDER BY s.snapshot_timestamp);

-- 2b. Snapshot timing check: 72/60/48/36/24/12/0 hours before start
SELECT hours_before_start, COUNT(*) AS n
FROM snap
GROUP BY hours_before_start
ORDER BY hours_before_start DESC;
-- Result: 7 values, 264 rows each  [pass]

-- 2c. First eligible closure: the earliest snapshot where the previous
--     need was positive and the current need is zero. The zero is the
--     observed closure time (the real change happened in the 12h before).
CREATE OR REPLACE VIEW first_closure AS
SELECT *
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY unit_id, shift_id, staff_role
                              ORDER BY snapshot_timestamp) AS closure_rank
    FROM snap
    WHERE prev_open_need > 0 AND open_need_count = 0
) t
WHERE closure_rank = 1;

-- 2d. One row per first closure, with everything the story needs:
--     return_hours   = first later snapshot with positive need (NULL if none)
--     slack          = available - required at the closure snapshot
--     closure_type   = staff added vs requirement dropped ("real" vs "paper")
--     req_rose_later = requirement rose above its closure level at any later snapshot
--     LEFT JOIN keeps closures that never returned, so they stay in every rate.
CREATE OR REPLACE VIEW closures AS
WITH later AS (
    SELECT fc.unit_id, fc.shift_id, fc.staff_role,
           MAX(CASE WHEN l.open_need_count > 0 THEN l.hours_before_start END) AS return_hours,
           MAX(CASE WHEN l.required_staff > fc.required_staff THEN 1 ELSE 0 END) AS req_rose_later
    FROM first_closure fc
    JOIN snap l
      ON  l.unit_id = fc.unit_id AND l.shift_id = fc.shift_id
      AND l.staff_role = fc.staff_role
      AND l.snapshot_timestamp > fc.snapshot_timestamp
    GROUP BY fc.unit_id, fc.shift_id, fc.staff_role
)
SELECT fc.unit_id, fc.shift_id, fc.staff_role, fc.unit_name, fc.shift_time_of_day,
       fc.hours_before_start                    AS closure_hours,
       fc.required_staff                        AS required_at_closure,
       fc.available_staff                       AS available_at_closure,
       fc.available_staff - fc.required_staff   AS slack,
       CASE WHEN fc.available_staff > fc.prev_available
             AND fc.required_staff  < fc.prev_required THEN 'both'
            WHEN fc.required_staff  < fc.prev_required THEN 'requirement dropped (paper)'
            ELSE 'staff added (real)' END        AS closure_type,
       la.return_hours,
       CASE WHEN la.return_hours IS NOT NULL THEN 1 ELSE 0 END AS returned,
       COALESCE(la.req_rose_later, 0)           AS req_rose_later
FROM first_closure fc
LEFT JOIN later la
  ON  la.unit_id = fc.unit_id AND la.shift_id = fc.shift_id
  AND la.staff_role = fc.staff_role;

-- 2e. Headline return rate (non-returns included in the denominator)
SELECT staff_role,
       COUNT(*)                           AS first_closures,
       SUM(returned)                      AS returns,
       ROUND(100.0 * AVG(returned), 1)    AS return_rate_pct
FROM closures
GROUP BY staff_role
ORDER BY staff_role DESC;
-- Result: RN 61 of 178 (34.3%) | PCT 20 of 62 (32.3%)


-- =====================================================================
-- 3. STORY 1: MOST SHIFTS THAT START SHORT HAD ALREADY LOOKED COVERED
-- The 0h snapshot is used as a proxy for staffing at shift start.
-- =====================================================================

-- 3a. Life of a gap, per role
WITH grp AS (
    SELECT unit_id, shift_id, staff_role,
           MAX(CASE WHEN open_need_count > 0 THEN 1 ELSE 0 END) AS had_gap,
           MAX(CASE WHEN hours_before_start = 0 AND open_need_count > 0 THEN 1 ELSE 0 END) AS short_at_start
    FROM snap
    GROUP BY unit_id, shift_id, staff_role
)
SELECT g.staff_role,
       COUNT(*)                                               AS n_groups,
       SUM(g.had_gap)                                         AS had_a_gap,
       COUNT(c.unit_id)                                       AS gap_closed,
       SUM(c.returned)                                        AS gap_came_back,
       SUM(CASE WHEN c.returned = 1 AND g.short_at_start = 1 THEN 1 ELSE 0 END) AS came_back_and_short_at_start,
       SUM(g.short_at_start)                                  AS all_short_at_start
FROM grp g
LEFT JOIN closures c
  ON c.unit_id = g.unit_id AND c.shift_id = g.shift_id AND c.staff_role = g.staff_role
GROUP BY g.staff_role
ORDER BY g.staff_role DESC;
-- Result:
--   RN : 194 groups -> 185 had a gap -> 178 closed -> 61 came back -> 61 still short at start
--   PCT:  70 groups ->  67 had a gap ->  62 closed -> 20 came back -> 20 still short at start
-- Every gap that came back was still open at shift start (never re-filled).
-- Of all shifts short at start: RN 61 of 68 (90%) and PCT 20 of 25 (80%)
-- had a gap that was closed earlier. The rest had a gap that never closed.

-- 3a-2. How every shift ended up. The pieces add up to the totals above,
--       and "short at start" = came back + never closed.
WITH grp AS (
    SELECT unit_id, shift_id, staff_role,
           MAX(CASE WHEN open_need_count > 0 THEN 1 ELSE 0 END) AS had_gap,
           MAX(CASE WHEN hours_before_start = 0 AND open_need_count > 0 THEN 1 ELSE 0 END) AS short_at_start
    FROM snap
    GROUP BY unit_id, shift_id, staff_role
)
SELECT g.staff_role,
       CASE WHEN g.had_gap = 0      THEN '1 never had a gap'
            WHEN c.unit_id IS NULL  THEN '2 gap never closed'
            WHEN c.returned = 0     THEN '3 gap closed and stayed closed'
            ELSE                         '4 gap closed, then came back' END AS outcome,
       COUNT(*)              AS n_shifts,
       SUM(g.short_at_start) AS short_at_start
FROM grp g
LEFT JOIN closures c
  ON c.unit_id = g.unit_id AND c.shift_id = g.shift_id AND c.staff_role = g.staff_role
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
-- Result (shifts | short at start):
--   RN : never had a gap 9 | 0     PCT: never had a gap 3 | 0
--        gap never closed 7 | 7         gap never closed 5 | 5
--        closed, stayed closed 117 | 0  closed, stayed closed 42 | 0
--        closed, came back 61 | 61      closed, came back 20 | 20
--   RN total 194, short at start 68 = 61 + 7. PCT total 70, short at start 25 = 20 + 5.

-- 3b. When did returning gaps first reappear?
SELECT staff_role, return_hours, COUNT(*) AS returns
FROM closures
WHERE returned = 1
GROUP BY staff_role, return_hours
ORDER BY staff_role DESC, return_hours DESC;
-- Result:
--   RN : 48h 5 | 36h 3 | 24h 9 | 12h 17 | 0h 27   (44 of 61 = 72% in the final 24h)
--   PCT: 48h 1 | 24h 2 | 12h 5 | 0h 12           (17 of 20 = 85% in the final 24h)

-- 3c. Worked example used in the summary
SELECT hours_before_start, required_staff, available_staff, open_need_count
FROM snap
WHERE unit_id = '45021_61221' AND shift_id = 'SHF00051' AND staff_role = 'RN'
ORDER BY snapshot_timestamp;
-- Result (Willow Medical, Day, RN): required 5,5,5,5,5,5,6 | available 4,5,5,5,5,5,5
--   Closed at 60h with exactly enough staff, looked covered for 48 hours,
--   then the requirement rose at shift start. Started one RN short. Nobody left.


-- =====================================================================
-- 4. STORY 2: THE TARGET MOVES, NOT THE PEOPLE
-- open need = required - available, so a gap can only reopen if required
-- rises, available falls, or both. Compare the return snapshot with the
-- closure snapshot.
-- =====================================================================

-- 4a. What changed between closure and return?
SELECT c.staff_role,
       CASE WHEN r.required_staff > c.required_at_closure
             AND r.available_staff < c.available_at_closure THEN 'both'
            WHEN r.required_staff > c.required_at_closure THEN 'requirement rose'
            WHEN r.available_staff < c.available_at_closure THEN 'staff dropped off'
            ELSE 'other' END AS what_changed,
       COUNT(*) AS returns
FROM closures c
JOIN snap r
  ON  r.unit_id = c.unit_id AND r.shift_id = c.shift_id
  AND r.staff_role = c.staff_role AND r.hours_before_start = c.return_hours
WHERE c.returned = 1
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
-- Result:
--   RN : requirement rose 40 | staff dropped off 14 | both 7   (requirement involved in 47 of 61 = 77%)
--   PCT: requirement rose 13 | staff dropped off  4 | both 3   (requirement involved in 16 of 20 = 80%)

-- 4b. When does the requirement move? (all 264 groups, including never-closed)
SELECT staff_role, hours_before_start,
       COUNT(*) AS updates,
       ROUND(100.0 * AVG(CASE WHEN required_staff > prev_required THEN 1 ELSE 0 END), 1) AS pct_rose,
       ROUND(100.0 * AVG(CASE WHEN required_staff < prev_required THEN 1 ELSE 0 END), 1) AS pct_fell
FROM snap
WHERE prev_required IS NOT NULL
GROUP BY staff_role, hours_before_start
ORDER BY staff_role DESC, hours_before_start DESC;
-- Result (% of 12h updates where required rose / fell):
--   RN : 60h 0.0/2.1 | 48h 4.1/3.1 | 36h 1.0/1.5 | 24h 4.1/6.2 | 12h 15.5/7.2 | 0h 23.7/1.5
--   PCT: 60h 0.0/1.4 | 48h 0.0/2.9 | 36h 0.0/2.9 | 24h 2.9/0.0 | 12h 14.3/4.3 | 0h 25.7/1.4
-- Increases cluster in the final 24 hours, and the drift is upward, not downward.

-- ---------------------------------------------------------------------
-- Explanations tested and ruled out
-- ---------------------------------------------------------------------

-- 4c. "Paper" closures return more? (gap closed because the requirement
--     dropped, rather than because staff were added)
SELECT staff_role, closure_type,
       COUNT(*) AS first_closures,
       SUM(returned) AS returns,
       ROUND(100.0 * AVG(returned), 1) AS return_rate_pct
FROM closures
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
-- Result:
--   RN : staff added 51/140 (36.4%) | requirement dropped 7/21 (33.3%) | both 3/17 (17.6%)
--   PCT: staff added 17/54 (31.5%) | requirement dropped 3/6 (50.0%, too small) | both 0/2
-- Not supported: paper closures do not return more often.

-- 4d. Early closures are more fragile? The raw rate is misleading: a gap
--     closed at 60h has 5 later snapshots to reopen in, one closed at 12h
--     has 1. The fair version gives every closure the same 12h window.
SELECT c.staff_role, c.closure_hours,
       COUNT(*) AS first_closures,
       ROUND(100.0 * AVG(c.returned), 1) AS pct_returned_any_time,
       ROUND(100.0 * AVG(CASE WHEN n.open_need_count > 0 THEN 1 ELSE 0 END), 1) AS pct_returned_next_12h
FROM closures c
JOIN snap n
  ON  n.unit_id = c.unit_id AND n.shift_id = c.shift_id
  AND n.staff_role = c.staff_role AND n.hours_before_start = c.closure_hours - 12
GROUP BY 1, 2
ORDER BY 1 DESC, 2 DESC;
-- Result (any time / next 12h):
--   RN : 60h 64.5/16.1 | 48h 50.0/7.1 | 36h 33.3/4.8 | 24h 26.4/9.4 | 12h 13.3/13.3
--   PCT: 60h 40.0/20.0 | 48h 60.0/0.0 | 36h 38.5/0.0 | 24h 11.8/5.9 | 12h 29.4/29.4  (5-17 per row)
-- With an equal window the downward slope disappears. Not supported.

-- 4e. Threshold noise? If returns were mostly +/-1 wobbles, the metric
--     rather than staffing could be driving them.
SELECT c.staff_role, r.open_need_count AS gap_size_at_return, COUNT(*) AS returns
FROM closures c
JOIN snap r
  ON  r.unit_id = c.unit_id AND r.shift_id = c.shift_id
  AND r.staff_role = c.staff_role AND r.hours_before_start = c.return_hours
WHERE c.returned = 1
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
-- Result: RN size 1: 32, size 2: 29 | PCT size 1: 14, size 2: 6
-- Nearly half of RN returns are 2 staff short. Counts are whole staff, so
-- even a gap of 1 is a real missing person. Not supported.

-- 4f. Concentrated in a unit or shift type?
SELECT staff_role, shift_time_of_day,
       COUNT(*) AS first_closures, SUM(returned) AS returns,
       ROUND(100.0 * AVG(returned), 1) AS return_rate_pct
FROM closures
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
-- Result: RN Day 26/89 (29.2%) vs Night 35/89 (39.3%) | PCT Day 9/31 (29.0%) vs Night 11/31 (35.5%)

SELECT staff_role, unit_name,
       COUNT(*) AS first_closures, SUM(returned) AS returns,
       ROUND(100.0 * AVG(returned), 1) AS return_rate_pct
FROM closures
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
-- Result: RN units range 29.2% to 37.0% (24-49 closures each). PCT units have
-- only 6-15 closures each, too small to compare. Night is slightly higher
-- for both roles but the gap is modest. Secondary at most.


-- =====================================================================
-- 5. STORY 3: WHICH GAPS COME BACK
-- Late requirement increases are common. Whether one reopens the gap
-- depends on whether the gap was closed with any slack.
-- =====================================================================

-- 5a. Return rate by "did the requirement rise later?" x slack at closure
SELECT staff_role,
       CASE WHEN req_rose_later = 0 THEN 'requirement never rose'
            WHEN slack = 0 THEN 'requirement rose, closed with exactly enough'
            ELSE 'requirement rose, closed with 1+ extra' END AS situation,
       COUNT(*) AS first_closures,
       SUM(returned) AS returns,
       ROUND(100.0 * AVG(returned), 1) AS return_rate_pct
FROM closures
GROUP BY 1, 2
ORDER BY 1 DESC, 5 DESC;
-- Result:
--   RN : rose + exactly enough 38/59 (64.4%) | rose + 1 extra 9/35 (25.7%) | never rose 14/84 (16.7%)
--   PCT: rose + exactly enough 15/27 (55.6%) | rose + 1 extra 1/3 (too small) | never rose 4/32 (12.5%)
-- The requirement rose after closure in 94 of 178 RN closures (53%) and
-- 30 of 62 PCT closures (48%). Closing with exactly enough staff makes a
-- later increase far more likely to reopen the gap.

-- 5b. Slack at closure on its own
SELECT staff_role, slack,
       COUNT(*) AS first_closures, SUM(returned) AS returns,
       ROUND(100.0 * AVG(returned), 1) AS return_rate_pct
FROM closures
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
-- Result: RN slack 0: 49/132 (37.1%), slack 1: 12/46 (26.1%)
--         PCT slack 0: 18/49 (36.7%), slack 1: 2/13 (15.4%)

-- 5c. When did the requirement first rise above its closure level?
--     (closures where it rose at some later snapshot)
WITH inc AS (
    SELECT c.unit_id, c.shift_id, c.staff_role,
           MAX(l.hours_before_start) AS first_increase_hours
    FROM closures c
    JOIN snap l
      ON  l.unit_id = c.unit_id AND l.shift_id = c.shift_id
      AND l.staff_role = c.staff_role
      AND l.hours_before_start < c.closure_hours
      AND l.required_staff > c.required_at_closure
    GROUP BY c.unit_id, c.shift_id, c.staff_role
)
SELECT staff_role, first_increase_hours, COUNT(*) AS closures
FROM inc
GROUP BY 1, 2
ORDER BY 1 DESC, 2 DESC;
-- Result:
--   RN : 48h 8 | 36h 2 | 24h 8 | 12h 30 | 0h 46   (76 of 94 at 12h or 0h, 46 at 0h)
--   PCT: 24h 2 | 12h 10 | 0h 18                   (28 of 30 at 12h or 0h)

-- 5d. Full split: did the requirement rise later? x slack at closure
--     Shows the increase is what reopens gaps; slack decides whether it gets through.
SELECT staff_role, req_rose_later, slack,
       COUNT(*) AS first_closures, SUM(returned) AS returns,
       ROUND(100.0 * AVG(returned), 1) AS return_rate_pct
FROM closures
GROUP BY 1, 2, 3
ORDER BY 1 DESC, 2 DESC, 3;
-- Result:
--   RN : rose + no spare 38/59 | rose + 1 spare 9/35 | never rose + no spare 11/73 | never rose + 1 spare 3/11
--   PCT: rose + no spare 15/27 | rose + 1 spare 1/3  | never rose + no spare 3/22  | never rose + 1 spare 1/10
-- With no increase, a spare person makes little difference (RN 11/73 vs 3/11,
-- too few to tell apart). Every gap that came back was still open at shift
-- start (see 3a: 61 of 61 RN, 20 of 20 PCT).
