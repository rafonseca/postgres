# Partial Aggregate Pushdown into Recursive CTEs

## Context

When a recursive CTE is consumed by `SELECT ... GROUP BY ... SUM(col)`, the worktable
carries every individual row across iterations — even when many rows share the same
group key. By pushing partial aggregation into each iteration of the RecursiveUnion,
we reduce the number of rows stored in the worktable (one per group per iteration
instead of many), improving both memory and CPU performance.

**Target aggregate for v1:** `avg(int4)` — has finalfn (`int8_avg`), combinefn
(`int4_avg_combine`), transition type = `bigint[]` (stores {count, sum}). This
demonstrates the full machinery including a new AggSplit mode. Also works for
simpler cases like `sum(int4)` (no finalfn, combinefn = `int8pl`, transtype = `int8`).

### Catalog properties of target aggregates

```
avg(int4):  transfn=int4_avg_accum  finalfn=int8_avg  combinefn=int4_avg_combine  transtype=bigint[]
sum(int4):  transfn=int4_sum        finalfn=-          combinefn=int8pl            transtype=bigint
```

## Motivating Example

```sql
CREATE TABLE edges (src int, dst int, weight int);

WITH RECURSIVE reachable(node, w) AS (
    SELECT dst, weight FROM edges WHERE src = 1
  UNION ALL
    SELECT e.dst, r.w
    FROM reachable r JOIN edges e ON r.node = e.src
)
SELECT node, AVG(w) FROM reachable GROUP BY node;
```

**Without optimization** — iteration 1 produces `(4,10), (4,5)` → 2 rows in worktable.
**With optimization** — iteration 1 produces `(4, {2,15})` → 1 row (partial state: count=2, sum=15).
Outer AVG combines partial states and finalizes: `15/2 = 7.5`. Correct result.

### Current plan tree
```
HashAggregate (GROUP BY node, AVG(w))  [AGGSPLIT_SIMPLE]
  └─ CteScan on reachable
       └─ [initplan] RecursiveUnion
             ├─ SeqScan on edges (src = 1)
             └─ Hash Join
                   ├─ WorkTableScan
                   └─ SeqScan on edges
```

### Optimized plan tree
```
HashAggregate (GROUP BY node, AVG(w))  [AGGSPLIT_FINAL_DESERIAL]
  └─ CteScan on reachable
       └─ [initplan] RecursiveUnion
             ├─ HashAggregate [AGGSPLIT_INITIAL_SERIAL]       ← base term
             │     └─ SeqScan on edges (src = 1)
             └─ HashAggregate [AGGSPLIT_COMBINE_SKIPFINAL]    ← recursive term (NEW mode)
                   └─ Hash Join
                         ├─ WorkTableScan
                         └─ SeqScan on edges
```

## Key Design Decisions

### New AggSplit mode: AGGSPLIT_COMBINE_SKIPFINAL

Neither existing mode works for the recursive term:
- `INITIAL_SERIAL` uses transfn (expects int4 input, but worktable has bigint[])
- `FINAL_DESERIAL` uses combinefn but **also runs finalfn** (premature for avg!)

New mode needed:
```c
/* Combine partial states without finalizing (for recursive CTE iterations) */
AGGSPLIT_COMBINE_SKIPFINAL = AGGSPLITOP_COMBINE | AGGSPLITOP_SKIPFINAL,  /* 0x03 */
```

**No executor changes needed** — `nodeAgg.c` already checks individual flags via
`DO_AGGSPLIT_COMBINE()`, `DO_AGGSPLIT_SKIPFINAL()`, etc. Adding a new named
combination to the enum is sufficient.

### AggSplit modes for each position

| Position | AggSplit | Function used | Input type | Output type |
|---|---|---|---|---|
| Base term | `INITIAL_SERIAL` | transfn `int4_avg_accum` | int4 | bigint[] (transition) |
| Recursive term | `COMBINE_SKIPFINAL` (**new**) | combinefn `int4_avg_combine` | bigint[] (from WT) | bigint[] |
| Outer query | `FINAL_DESERIAL` | combinefn `int4_avg_combine` + finalfn `int8_avg` | bigint[] (from CteScan) | numeric |

The recursive term uses `COMBINE_SKIPFINAL` because:
1. Input is transition states from the worktable → needs `combinefn`, not `transfn`
2. Output goes back to the worktable → must NOT run `finalfn`

This works uniformly for all aggregates — with or without finalfn.

### CTE output type change

The CTE's aggregated column changes type from the original type to the **transition
type** (e.g., int4 → bigint[] for avg(int4), int4 → int8 for sum(int4)).
This requires updating:
1. CTE internal targetlists (both union branches + RecursiveUnion output)
2. `cte->ctecoltypes` in the `CommonTableExpr`
3. `rte->coltypes` for the CTE's RangeTblEntry in the outer query
4. Var nodes in the outer query that reference the aggregated CTE column
5. The outer query's Aggref to use `FINAL_DESERIAL` with the updated input

### Validity conditions (v1 restrictions)

1. `UNION ALL` only (not `UNION` — dedup interaction is complex)
2. All aggregates must have `combinefn` (finalfn is allowed — handled by the split)
3. Transition type must not be `INTERNAL` (no serialfn/deserialfn needed)
4. In the recursive term, the aggregated column must be a **simple Var reference**
   to the worktable (just passed through, no computation on it)
5. The outer query's `GROUP BY` columns map directly to CTE output column positions
6. Single reference to the CTE (`cte->cterefcount == 1`)
7. No `HAVING` clause in the outer query
8. The outer query's FROM is just the CTE (no additional joins)

## Implementation Steps

### Step 0: Add AGGSPLIT_COMBINE_SKIPFINAL to AggSplit enum

**File:** `src/include/nodes/nodes.h` (line 380-388)

```c
typedef enum AggSplit
{
    AGGSPLIT_SIMPLE = 0,
    AGGSPLIT_INITIAL_SERIAL = AGGSPLITOP_SKIPFINAL | AGGSPLITOP_SERIALIZE,
    AGGSPLIT_FINAL_DESERIAL = AGGSPLITOP_COMBINE | AGGSPLITOP_DESERIALIZE,
    /* Combine partial states without finalizing (recursive CTE iterations): */
    AGGSPLIT_COMBINE_SKIPFINAL = AGGSPLITOP_COMBINE | AGGSPLITOP_SKIPFINAL, /* 0x03 */
} AggSplit;
```

No executor changes needed — `nodeAgg.c` already dispatches on the individual flag
bits (`DO_AGGSPLIT_COMBINE`, `DO_AGGSPLIT_SKIPFINAL`, etc.).

Also need `get_agg_clause_costs()` to handle the new mode. It should charge combinefn
cost (like FINAL_DESERIAL) but NOT charge finalfn cost (like INITIAL_SERIAL).

Also need `mark_partial_aggref()` to handle the new mode — `DO_AGGSPLIT_SKIPFINAL`
is true, so it sets `aggtype = aggtranstype`. This is correct: the recursive term
outputs transition states.

### Step 1: Detect the optimization opportunity

**File:** `src/backend/optimizer/plan/subselect.c` (in `SS_process_ctes()`)

Before calling `subquery_planner()` for a recursive CTE (line 968), inspect the
outer query (`root->parse`):

```
New function: can_pushdown_partial_agg_to_recursive_cte(root, cte)
  - Verify cte->cterecursive
  - Verify cte->cterefcount == 1
  - Verify outer query: parse->hasAggs && parse->groupClause && !parse->havingQual
  - Verify outer query FROM is a single RTE_CTE referencing this CTE
  - For each Aggref in parse->targetList:
    - Look up pg_aggregate for the aggfnoid
    - Verify aggcombinefn != InvalidOid
    - Verify aggfinalfn == InvalidOid
    - Verify aggtranstype != INTERNALOID
    - Verify the aggregate's input arg is a simple Var referencing the CTE
  - For each GROUP BY column: verify it references a CTE output column
  - Verify the CTE subquery is UNION ALL (check the SetOperationStmt->all == true)
  - Return a descriptor: { group col positions, agg info (fnoid, col position,
    transtype, combinefn) }
```

Also verify the recursive term condition: the aggregated CTE column in the recursive
term's target list must be a simple Var referencing the self-reference RTE (worktable).
This requires inspecting the recursive term's Query (the right child of the SetOp).

### Step 2: New data structure to carry pushdown info

**File:** `src/include/nodes/pathnodes.h`

Add a new field to **`PlannerGlobal`** (the shared singleton, `root->glob`):
```c
/* Info about partial agg pushdown into a recursive CTE, or NIL */
List *partial_agg_pushdown;  /* list of PartialAggPushdownDesc */
```

`PlannerGlobal` is already passed as the first arg to `subquery_planner()` and
accessible everywhere via `root->glob` — no function signature changes needed.

New struct (can be in a new header or in pathnodes.h):
```c
typedef struct PartialAggPushdownDesc {
    NodeTag     type;
    List       *groupColPositions;  /* int list: CTE output col positions for GROUP BY */
    List       *aggFnOids;          /* OID list: aggregate function OIDs */
    List       *aggColPositions;    /* int list: CTE output col positions being aggregated */
    List       *aggTransTypes;      /* OID list: transition types */
    List       *aggCombineFns;      /* OID list: combine function OIDs */
} PartialAggPushdownDesc;
```

### Step 3: Pass pushdown info via PlannerGlobal (no signature changes)

**File:** `src/backend/optimizer/plan/subselect.c`

In `SS_process_ctes()`, if the detection succeeds:
1. Set `root->glob->partial_agg_pushdown = list_make1(desc)` **before** calling
   `subquery_planner()` for the CTE (line 968)
2. Inside the CTE's planning, `generate_recursion_path()` reads
   `root->glob->partial_agg_pushdown`
3. After `subquery_planner()` returns, clear or keep the field as needed for the
   outer query type fixup (Step 5)

### Step 4: Modify generate_recursion_path() to insert Agg paths

**File:** `src/backend/optimizer/prep/prepunion.c` (line 357-465)

After computing `lpath` and `rpath` (line 406), and before creating the
RecursiveUnionPath (line 453):

```c
if (root->glob->partial_agg_pushdown != NIL) {
    /* Build PathTarget for partial aggregation output */
    partial_target = build_recursive_partial_agg_target(root, lpath_tlist, desc);

    /* Wrap base term with INITIAL_SERIAL Agg */
    lpath = (Path *) create_agg_path(root, lrel, lpath, partial_target,
                                      AGG_HASHED, AGGSPLIT_INITIAL_SERIAL,
                                      groupClause, NIL, &agg_partial_costs,
                                      dNumGroups);

    /* Wrap recursive term with COMBINE_SKIPFINAL Agg (combines but does NOT finalize) */
    rpath = (Path *) create_agg_path(root, rrel, rpath, partial_target,
                                      AGG_HASHED, AGGSPLIT_COMBINE_SKIPFINAL,
                                      groupClause, NIL, &agg_combine_costs,
                                      dNumGroups);

    /* Update the tlist to reflect new output types */
    tlist = build_partial_agg_tlist(desc, ...);
}
```

The `partial_target` PathTarget has:
- GROUP BY columns: same Vars, same types
- Aggregated columns: Aggref nodes marked with appropriate AggSplit,
  output type = transition type (int8 for sum(int4))

For building the Aggrefs inside the CTE:
- Reuse `make_partial_grouping_target()` pattern from `planner.c:5639`
- Create Aggref nodes with `mark_partial_aggref()` for the base term
- For the recursive term, create Aggrefs with FINAL_DESERIAL

Need to also create proper `groupClause` (List of SortGroupClause) referencing the
GROUP BY columns in the CTE's internal targetlist.

Also update `setOp->colTypes` for the aggregated column positions to use the
transition type (int8). This affects `generate_append_tlist()` output.

### Step 5: Update outer query types after CTE planning

**File:** `src/backend/optimizer/plan/subselect.c` (or a helper called from there)

After the CTE is planned with partial aggs (after `create_plan` at line 986):

```
New function: adjust_outer_query_for_partial_agg_cte(root, cte, desc)
```

This function:
1. Updates `cte->ctecoltypes` — change the type OIDs for aggregated columns
   (e.g., INT4OID → INT8OID for sum(int4))

2. Finds the RTE in `root->parse->rtable` where `rte->rtekind == RTE_CTE` and
   `rte->ctename` matches — updates `rte->coltypes` for the affected columns

3. Walks `root->parse` (targetList, jointree, groupClause refs) and updates
   Var nodes that reference the affected CTE columns:
   ```
   For each Var where varno matches the CTE's rtindex
     and varattno matches an aggregated column position:
       var->vartype = new transition type (INT8OID)
   ```

4. For each Aggref in `root->parse->targetList` that references this CTE:
   - Set `aggref->aggsplit = AGGSPLIT_FINAL_DESERIAL`
   - The aggref's arg Var was already updated in step 3
   - The aggtype stays the same (int8 for sum(int4) — already equals transition type)

**Timing:** This must happen before `preprocess_aggrefs()` runs (line ~833 in
planner.c). Since `SS_process_ctes()` runs at line 717, and preprocess_aggrefs
runs later, the timing is correct.

**Caveat:** `mark_partial_aggref()` asserts `aggsplit == AGGSPLIT_SIMPLE`. Since we're
setting aggsplit directly (bypassing mark_partial_aggref), we need to do the type
adjustment manually. For sum(int4) with `FINAL_DESERIAL`, `DO_AGGSPLIT_SKIPFINAL` is
false, so aggtype stays unchanged. This is correct — sum(int4)'s aggtype is already
int8.

### Step 6: Handle preprocess_aggrefs interaction

**File:** `src/backend/optimizer/plan/planner.c`

`preprocess_aggrefs()` (called after SS_process_ctes) processes all Aggrefs and sets
`aggtranstype`. It needs to handle Aggrefs that already have `aggsplit != SIMPLE`.

Verify: does `preprocess_aggrefs` modify aggsplit? If not, our pre-set value
is safe. (Likely it doesn't — it focuses on aggtranstype and shared state detection.)

When the outer query's Aggrefs are already in FINAL_DESERIAL mode,
skip parallel partial aggregation (set `GROUPING_CAN_PARTIAL_AGG` flag accordingly).

### Step 7: Ensure outer Agg uses FINAL_DESERIAL

**File:** `src/backend/optimizer/plan/planner.c` (in `add_paths_to_grouping_rel`)

Currently, `add_paths_to_grouping_rel` creates Agg paths with `AGGSPLIT_SIMPLE`
(line 7259). When the CTE has been partially aggregated:

**Preferred approach:** Use the `partially_grouped_rel` mechanism — inject the CteScan
path as a partially-grouped path, and the existing FINAL_DESERIAL code (lines 7179-7285)
handles it automatically.

- In `create_partial_grouping_paths`, if the input comes from a partially-aggregated CTE,
  add the CteScan path to `partially_grouped_rel`
- The existing code creates FINAL_DESERIAL Agg paths on top

This requires:
- `make_partial_grouping_target()` to work correctly with the pre-modified Aggrefs
- The `partially_grouped_rel->reltarget` to have the correct partial aggregate types
- Cost estimation to account for the reduced row count from the CTE

### Step 8: Cost estimation adjustments

**File:** `src/backend/optimizer/path/costsize.c`

- `cost_recursive_union()` (line 1809): should reflect reduced rows per iteration
  when partial aggregation is active
- The Agg cost is added by `create_agg_path()` automatically
- The outer query's cost estimation benefits from fewer CteScan rows

## Key Code Locations Reference

| Component | File | Lines |
|-----------|------|-------|
| CTE processing | `src/backend/optimizer/plan/subselect.c` | 880-1048 |
| subquery_planner init | `src/backend/optimizer/plan/planner.c` | 694-717 |
| generate_recursion_path | `src/backend/optimizer/prep/prepunion.c` | 357-465 |
| make_partial_grouping_target | `src/backend/optimizer/plan/planner.c` | 5639-5733 |
| mark_partial_aggref | `src/backend/optimizer/plan/planner.c` | 5741-5764 |
| create_agg_path | `src/backend/optimizer/util/pathnode.c` | 2981-3059 |
| AggSplit enum | `src/include/nodes/nodes.h` | 370-394 |
| convert_combining_aggrefs | `src/backend/optimizer/plan/setrefs.c` | 2630-2676 |
| add_paths_to_grouping_rel | `src/backend/optimizer/plan/planner.c` | 7078-7285 |
| create_partial_grouping_paths | `src/backend/optimizer/plan/planner.c` | 7314-7599 |
| set_cte_pathlist | `src/backend/optimizer/path/allpaths.c` | 2900-2970 |
| RecursiveUnion executor | `src/backend/executor/nodeRecursiveunion.c` | 79-172 |
| PlannerInfo struct | `src/include/nodes/pathnodes.h` | ~575 |
| CommonTableExpr | `src/include/nodes/parsenodes.h` | ~1720 |
| RTE coltypes | `src/include/nodes/parsenodes.h` | ~1250 |

## Files Modified (summary)

| File | Change |
|------|--------|
| `src/include/nodes/nodes.h` | Add `AGGSPLIT_COMBINE_SKIPFINAL` to AggSplit enum |
| `src/include/nodes/pathnodes.h` | Add `partial_agg_pushdown` field to PlannerGlobal, new struct |
| `src/backend/optimizer/plan/subselect.c` | Detection logic in SS_process_ctes, outer query type fixup |
| `src/backend/optimizer/plan/planner.c` | Accept/propagate pushdown info, handle outer Agg |
| `src/backend/optimizer/prep/prepunion.c` | Insert Agg paths in generate_recursion_path |
| `src/backend/optimizer/path/costsize.c` | Cost adjustments for reduced worktable rows |
| `src/backend/optimizer/path/allpaths.c` | CteScan type awareness (if needed) |

## Verification

### Test queries
```sql
CREATE TABLE edges (src int, dst int, weight int);
INSERT INTO edges VALUES
  (1,2,10),(1,3,5),(2,4,7),(3,4,3),(4,5,1),(2,3,2);

-- Test AVG (has finalfn — exercises full AGGSPLIT machinery)
WITH RECURSIVE reachable(node, w) AS (
    SELECT dst, weight FROM edges WHERE src = 1
  UNION ALL
    SELECT e.dst, r.w
    FROM reachable r JOIN edges e ON r.node = e.src
)
SELECT node, AVG(w) FROM reachable GROUP BY node ORDER BY node;

-- Test SUM (no finalfn — simpler case)
WITH RECURSIVE reachable(node, w) AS (
    SELECT dst, weight FROM edges WHERE src = 1
  UNION ALL
    SELECT e.dst, r.w
    FROM reachable r JOIN edges e ON r.node = e.src
)
SELECT node, SUM(w) FROM reachable GROUP BY node ORDER BY node;

-- Check EXPLAIN for Agg nodes inside RecursiveUnion
EXPLAIN (COSTS OFF)
WITH RECURSIVE reachable(node, w) AS (
    SELECT dst, weight FROM edges WHERE src = 1
  UNION ALL
    SELECT e.dst, r.w
    FROM reachable r JOIN edges e ON r.node = e.src
)
SELECT node, AVG(w) FROM reachable GROUP BY node;
```

### Expected EXPLAIN output shows
- `Finalize HashAggregate` at top (FINAL_DESERIAL)
- Inside RecursiveUnion:
  - Base term: `Partial HashAggregate` (INITIAL_SERIAL)
  - Recursive term: `Intermediate HashAggregate` or similar (COMBINE_SKIPFINAL)

### Regression tests
- Add test in `src/test/regress/sql/` (possibly `with.sql` or new file)
- Test AVG correctness (exercises finalfn + combinefn split)
- Test SUM correctness (simpler, no finalfn)
- Test with and without optimization (GUC to disable)
- Test edge cases: empty base, single iteration, no matching groups, NULL values
- Test that optimization is NOT applied for disqualifying cases (HAVING, UNION,
  computed aggregated column in recursive term, aggregates without combinefn,
  INTERNAL transition type)
