# Repeated operation semantics

Before rendering, every layer holds one physical group named after it, so an operation's
destination must be **new** or **one of its own inputs**. That single rule fixes what
repeating an operation means:

- An **independent syntactic duplicate** (same constructor values, first call did not change
  the second call's inputs) is rejected for every operation with a destination, because the
  destination already exists: `Cut(:trimmed, :metal, :mask)` twice, `Fuse(:ab, (:a, :b))`
  twice, `Intersect`, `GetInterface`, `GetBoundary`,
  `Translate(:shifted, :metal, …)`, `Revolve(:swept, …)`, `Extrude(:solid, :metal)`.
- **Explicit composition** names an earlier destination as a later source under a new name and
  composes freely: `Cut(:first, :metal, :a); Cut(:second, :first, :b)`,
  `Fuse(:ab, (:a, :b)); Fuse(:abc, (:ab, :c))`, `GetBoundary(:faces, :volume);
  GetBoundary(:edges, :faces)`, `GetInterface(:ab, :a, :b); GetInterface(:abc, :ab, :c)`.
- **In-place reapplication** (destination equal to an input) reads the state left by the
  first call:

| Operation | In-place reapplication |
|---|---|
| `Extrude`, `Hollow` | Rejected: the second call sees a layer of the wrong dimension. |
| `Cut`, `Intersect` | Executes twice; geometrically idempotent for the same mask. A `Cut` whose destination aliases a tool uses the first result as that tool. |
| `Fuse` | Executes twice; heals the already-healed result. |
| `GetInterface` | Not applicable: the destination must be new, and inputs must keep their PG identity through deferred execution. |
| `GetBoundary`, `Revolve` | Cumulative: each call lowers or raises the dimension (3D → 2D → 1D; 1D → 2D → 3D, then rejected). |
| `Translate` | Cumulative: the one-layer form moves, so two calls translate by twice the offset. |
| `Remove` | The second call is a no-op because the layer is absent. |
| `RestrictTo`, `SetPeriodic` | No destination; each call acts on the global model and is idempotent at the model level. |
