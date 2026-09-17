# Repeated operation semantics

The four terms overlap:

- A **syntactic duplicate** means the constructor values are identical.
- That duplicate can be:
  - **Independent**: the first call did not change the second call’s inputs.
  - **In-place/stateful**: the second call reads state changed by the first.
- **Explicit composition** names an earlier destination as a later source, usually under a different layer name.

The first two behavior columns below are therefore both kinds of syntactic duplication.

| Operation | Independent syntactic duplicate | In-place/stateful syntactic reapplication | Explicit composition |
|---|---|---|---|
| `Extrude` | `Extrude(:solid, :metal)` twice is rejected because both calls request the same internal output PG. | `Extrude(:metal); Extrude(:metal)` is rejected because the second call sees a 3D layer. | `Extrude(:metal); GetBoundary(:faces, :metal)` or `GetBoundary(:metal, :metal); Extrude(:metal)` (walls) compose freely; `Extrude(:solid, :metal)` keeps the 2D source for further use. |
| `Hollow` | Not applicable: it always replaces its layer. | `Hollow(:metal)` twice is rejected because the second call sees a 2D layer. | `Extrude(:metal); Hollow(:metal)` voids the interior after fragmentation; the shell can feed `GetInterface` or locators like any 2D layer. |
| `Cut` | `Cut(:trimmed, :metal, :mask); Cut(:trimmed, :metal, :mask)` is rejected because both calls request the same internal output PG. Removal flags do not affect that internal name. | `Cut(:metal, :metal, :mask)` twice executes twice. The second computes `(metal − mask) − mask`, which is geometrically idempotent for the same mask. If the destination aliases a tool instead, the second call uses the first result as that tool. | `Cut(:first, :metal, :mask_a); Cut(:second, :first, :mask_b)` computes `(metal − mask_a) − mask_b`. |
| `Fuse` | `Fuse(:combined, (:a, :b))` twice is rejected because both calls request the same internal output PG. A different fused source set may append one new PG to the existing destination. | `Fuse(:metal); Fuse(:metal)` executes twice. The second fuses the first generated PG and creates another hashed internal PG name. | `Fuse(:ab, (:a, :b)); Fuse(:abc, (:ab, :c))` works and creates another internal result PG. |
| `Heal` | `Heal(:clean, :metal); Heal(:clean, :metal)` fails on the second call because the internal output PG already exists in `:clean`. | `Heal(:metal); Heal(:metal)` executes twice using the same internal PG name. The second heals the already-healed result and should be geometrically idempotent. | `Heal(:clean, :metal); Heal(:cleaner, :clean)` names each result from its immediate source. |
| `Intersect` | `Intersect(:overlap, :a, :b)` twice is rejected because the internal output PG name collides. | `Intersect(:a, :a, :mask)` twice executes on evolved state and consumes each replaced OCC object. The second computes `(a ∩ mask) ∩ mask`, geometrically idempotent for the same mask but with new internal PG names. Using one layer as both object and tool is rejected. | `Intersect(:ab, :a, :b); Intersect(:abc, :ab, :c)` computes `(a ∩ b) ∩ c`. |
| `GetInterface` | `GetInterface(:ab, :a, :b)` twice is rejected because both calls request the same deferred output PG. | In-place use is rejected because deferred interface inputs must retain their registered PG names and dimensions through execution. | `GetInterface(:ab, :a, :b); GetInterface(:abc, :ab, :c)` creates a deferred interface chain while preserving the original inputs. |
| `RestrictTo` | There is no destination. `RestrictTo(:volume)` twice emits two native calls; the second should usually be geometrically idempotent. | The first call changes the global model rather than a named destination, so the second sees an already-restricted model. | `RestrictTo(:outer); RestrictTo(:inner)` sequentially restricts the global model, effectively approaching restriction to the common retained region. This is global-state composition, not named-layer composition. |
| `GetBoundary` | `GetBoundary(:faces, :volume)` twice is rejected because both calls request the same internal output PG. | `GetBoundary(:shape, :shape)` twice composes dimensions, for example 3D → 2D → 1D. | `GetBoundary(:faces, :volume); GetBoundary(:edges, :faces)` explicitly computes boundaries of boundaries. |
| `Translate` | `Translate(:shifted, :metal, dx, dy, dz)` twice is rejected because both calls request the same internal output PG. Out-of-place `copy=false` is invalid. | `Translate(:metal, dx, 0, 0)` twice accumulates to translation by `2dx` because in-place calls move by default. Repeating the same in-place `copy=true` operation is rejected because it would recreate the first copied internal PG. | `Translate(:x, :metal, dx, 0, 0); Translate(:xy, :x, 0, dy, 0)` composes copied translations to `(dx, dy, 0)`. |
| `Remove` | Not independent: the first call changes source availability. | `Remove(:metal); Remove(:metal)` emits removal only once; the second is a no-op because the layer is absent. | Common lifecycle composition is `Heal(:clean, :metal); Remove(:metal)`, where removal may be absorbed into the preceding operation. |
| `Revolve` | `Revolve(:swept, :surface, origin, axis, angle)` twice is rejected because both calls request the same internal output PG. | `Revolve(:shape, origin, axis, angle)` repeatedly increments dimension. A 1D source can become 2D and then 3D; the next call is rejected. A typical 2D source permits only one in-place revolution. | `Revolve(:surface, :curve, ...); Revolve(:volume, :surface, ...)` explicitly composes two sweeps. |
| `SetPeriodic` | There is no destination. `SetPeriodic(:first, :second)` twice emits two native calls and leaves registry state unchanged. | The second call sees the periodic relationship already installed, so it should be idempotent at the model level. | There is no named result to feed forward. Different calls can establish additional periodic relationships, but that is not dataflow composition. |

## Main patterns now visible

### Generated independent duplicates are rejected

- `Cut`
- `GetInterface`
- `GetBoundary`
- `Intersect`
- `Translate`
- `Revolve`
- Assign-mode `Heal`
- `Fuse`

### In-place reapplication has four broad meanings

- **Rejected**
  - `GetInterface`
  - `Translate(copy=true)` when destination equals source

- **Geometrically idempotent or nearly so**
  - `Cut` with the same mask
  - `Intersect` with the same mask
  - `Heal`
  - `Fuse`

- **Intentionally cumulative**
  - `Translate(copy=false)`
  - `GetBoundary`
  - `Revolve`

- **Unsupported or unclear**
  - `Extrude`

This suggests that independent internal output-name collisions and in-place reapplication should probably be governed by separate policies rather than one universal duplicate rule.
