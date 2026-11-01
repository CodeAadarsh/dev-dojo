# Solution: Incremental Upsert

## The complete implementation

```python
# upsert.py
import pandas as pd


def apply_cdc_feed(base_df: pd.DataFrame, feed_df: pd.DataFrame) -> pd.DataFrame:
    # 1. Collapse the feed to the last op per id (de-duplicate within one batch)
    latest_feed = feed_df.drop_duplicates(subset="id", keep="last").copy()

    deletes = set(latest_feed.loc[latest_feed["op"] == "DELETE", "id"])
    upserts = latest_feed[latest_feed["op"].isin(["INSERT", "UPDATE"])].copy()
    upsert_ids = set(upserts["id"])

    # 2. Remove deleted ids and ids that will be replaced by upserts
    base_keep = base_df[
        ~base_df["id"].isin(deletes) & ~base_df["id"].isin(upsert_ids)
    ].copy()

    # 3. Build the upsert rows in the base schema (drop the op column)
    upsert_rows = upserts[["id", "name", "amount", "updated_at"]].copy()

    # 4. Concatenate and sort
    result = pd.concat([base_keep, upsert_rows], ignore_index=True)
    result = result.sort_values("id").reset_index(drop=True)
    return result
```

## Why each piece is correct

**`drop_duplicates(subset="id", keep="last")`** — if the feed contains multiple operations for the same `id`, keep only the last one. This handles the case where a batch has `INSERT id=5` followed by `DELETE id=5` — the net effect is a delete. `keep="last"` means we respect the temporal ordering of the feed.

**`base_keep = base_df[~base_df["id"].isin(deletes) & ~base_df["id"].isin(upsert_ids)]`** — this is the idempotency key. We remove any row that either (a) should be deleted, or (b) is about to be replaced by an upsert. This means re-running the feed is safe: if `id=5` is already updated to `550.00`, the base row is still replaced by the upsert row `550.00` — the result is identical. If `id=3` is already deleted (absent from base), `isin(deletes)` is False for all remaining rows and the filter is a no-op.

**Not appending to an existing base row** — the naive `base.update(upsert)` mutates rows in-place and leaves the old row if `id` is absent. The concat pattern is cleaner and avoids index alignment bugs.

**`pd.concat([base_keep, upsert_rows], ignore_index=True)`** — `ignore_index=True` prevents index collisions when the base and upsert slices have overlapping integer indices.

## Idempotency proof

Let `S = apply_cdc_feed(base, feed)`. Call `apply_cdc_feed(S, feed)`:

- **Deletes:** the deleted `id`s are absent in `S`. `~S["id"].isin(deletes)` is True for all rows of `S` → no rows removed by the delete set.
- **Upserts:** the upserted `id`s *are* present in `S` (either they came from the feed or they were in base and not deleted). `~S["id"].isin(upsert_ids)` removes them from `base_keep` exactly as before, then re-appends the same upsert values.
- **Net result:** `base_keep` is `S` minus the upsert rows, then upsert rows are re-appended → same set of rows → idempotent.

## Common mistakes

- Using `df.append()` (removed in pandas 2.0) or `df.loc[len(df)] = row` (O(N) per row).
- Forgetting `drop_duplicates` on the feed: if `id=5` appears as both `INSERT` and `UPDATE`, you'd get two rows for `id=5` in the output.
- Checking for duplicates in the base after the merge instead of preventing them: correct, but `pd.testing.assert_frame_equal` on the idempotency test will catch this regardless.
