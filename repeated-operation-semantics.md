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
| `Extrude` | Not applicable: it always writes back to its source layer. | `Extrude(:metal); Extrude(:metal)` is accepted, but the lowering assumes source-stack extrusion semantics and is not designed for repeated extrusion. Behavior can be surprising. | There is no separate destination argument. Its result can feed another operation, e.g. `Extrude(:metal); GetBoundary(:faces, :metal)`. |
| `Cut` | `Cut(:trimmed, :metal, :mask); Cut(:trimmed, :metal, :mask)` is rejected because both calls request the same generated destination identity. Removal flags do not affect that identity. | `Cut(:metal, :metal, :mask)` twice executes twice. The second computes `(metal − mask) − mask`, which is geometrically idempotent for the same mask. If the destination aliases a tool instead, the second call uses the first result as that tool. | `Cut(:first, :metal, :mask_a); Cut(:second, :first, :mask_b)` computes `(metal − mask_a) − mask_b`. |
| `Fuse` | `Fuse(:combined, (:a, :b))` twice fails on the second call because `:combined` now exists but was not listed as a source. | `Fuse(:metal); Fuse(:metal)` executes twice. The second fuses the first generated PG and creates another hashed identity. | `Fuse(:ab, (:a, :b)); Fuse(:abc, (:ab, :c))` works and creates a second collapsed result. |
| `Heal` | `Heal(:clean, :metal); Heal(:clean, :metal)` fails on the second call because the renamed PG identity already exists in `:clean`. | `Heal(:metal); Heal(:metal)` executes twice under the same identity. The second heals the already-healed result and should be geometrically idempotent. | `Heal(:clean, :metal); Heal(:cleaner, :clean)` preserves the identity suffix while changing the layer prefix twice. |
| `Intersect` | `Intersect(:overlap, :a, :b)` twice is rejected because the generated destination identity collides. | `Intersect(:a, :a, :mask)` twice executes on evolved state. The second computes `(a ∩ mask) ∩ mask`, geometrically idempotent for the same mask but with new generated PG identities. | `Intersect(:ab, :a, :b); Intersect(:abc, :ab, :c)` computes `(a ∩ b) ∩ c`. |
| `GetInterface` | `GetInterface(:ab, :a, :b)` twice silently deduplicates the second deferred output. | `GetInterface(:a, :a, :b)` twice makes the second deferred operation consume the first interface result. It is not the same interface calculation. | `GetInterface(:ab, :a, :b); GetInterface(:abc, :ab, :c)` creates a deferred interface chain. |
| `RestrictTo` | There is no destination. `RestrictTo(:volume)` twice emits two native calls; the second should usually be geometrically idempotent. | The first call changes the global model rather than a named destination, so the second sees an already-restricted model. | `RestrictTo(:outer); RestrictTo(:inner)` sequentially restricts the global model, effectively approaching restriction to the common retained region. This is global-state composition, not named-layer composition. |
| `GetBoundary` | `GetBoundary(:faces, :volume)` twice executes twice and creates `faces__hash` and `faces__hash__2`. | `GetBoundary(:shape, :shape)` twice composes dimensions, for example 3D → 2D → 1D. | `GetBoundary(:faces, :volume); GetBoundary(:edges, :faces)` explicitly computes boundaries of boundaries. |
| `Translate` | `Translate(:shifted, :metal, dx, dy, dz)` twice creates two copied results with suffixes, even though they represent the same transformation. | `Translate(:metal, :metal, dx, 0, 0; copy=false)` twice accumulates to translation by `2dx`. With `copy=true`, repeated in-place calls append copies to the source layer and later calls can copy earlier copies, causing PG growth. | `Translate(:x, :metal, dx, 0, 0); Translate(:xy, :x, 0, dy, 0)` composes to translation by `(dx, dy, 0)`. |
| `Remove` | Not independent: the first call changes source availability. | `Remove(:metal); Remove(:metal)` emits removal only once; the second is a no-op because the layer is absent. | Common lifecycle composition is `Heal(:clean, :metal); Remove(:metal)`, where removal may be absorbed into the preceding operation. |
| `Revolve` | `Revolve(:swept, :surface, origin, axis, angle)` twice executes twice and creates suffixed copies from the unchanged source. | `Revolve(:shape, :shape, ...)` repeatedly increments dimension. A 1D source can become 2D and then 3D; the next call is rejected. A typical 2D source permits only one in-place revolution. | `Revolve(:surface, :curve, ...); Revolve(:volume, :surface, ...)` explicitly composes two sweeps. |
| `SetPeriodic` | There is no destination. `SetPeriodic(:first, :second)` twice emits two native calls and leaves registry state unchanged. | The second call sees the periodic relationship already installed, so it should be idempotent at the model level. | There is no named result to feed forward. Different calls can establish additional periodic relationships, but that is not dataflow composition. |

## Main patterns now visible

### Independent duplicates currently have three outcomes

- **Silently deduplicated**
  - `GetInterface`

- **Rejected**
  - `Cut`
  - `Intersect`
  - Assign-mode `Heal`
  - `Fuse`, indirectly through its destination rule

- **Executed with generated suffixes**
  - `GetBoundary`
  - `Translate`
  - `Revolve`

### In-place reapplication also has three broad meanings

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
  - `Translate(copy=true)` when destination equals source

This suggests that independent generated-identity collisions and in-place reapplication should probably be governed by separate policies rather than one universal duplicate rule.
