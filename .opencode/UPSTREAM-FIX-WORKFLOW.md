# Upstream-first bug fix workflow

`boucle` is the upstream project (GitHub repository). Consumer projects
integrate boucle as a dependency and may accumulate data produced by
older, defective versions.

## Mandatory rule

For any bug reported on a consumer project,
**never patch the consumer project to work around a defect in boucle**.
Always follow this order:

1. **Fix upstream in boucle (GitHub)**
   - Reproduce and diagnose the bug in boucle.
   - Fix the root cause in boucle.
   - Verify the fix (tests, build) in boucle.
   - Commit/push/PR on the boucle GitHub repository.

2. **Update boucle in the consumer project**
   - Bump the boucle version in the consumer project to the version
     containing the fix.
   - Verify the update applies without regression.

3. **Manual remediation of existing data**
   - Identify data already produced by the older defective version that
     remains in an erroneous state.
   - Apply a targeted manual correction to this data to align it with the
     expected state.
   - The upstream fix guarantees that **future occurrences** will be
     correct; remediation only addresses the existing stock.

## Why this order

- Patching the consumer hides the defect and leaves boucle broken for
  all other consumers.
- Updating the consumer before fixing boucle propagates the bug.
- Data remediation without an upstream fix condemns you to repeat the
  operation on every new occurrence.

## Forbidden anti-patterns

- A corrective patch in a consumer project that works around a boucle
  bug.
- Updating boucle on the consumer side before the fix is merged
  upstream.
- Data remediation without an upstream fix (the bug keeps producing
  erroneous data).