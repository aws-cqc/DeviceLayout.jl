Functions and methods that mutate any of their arguments must have names ending in `!`.

Commit messages must use a succinct one-line summary followed by a brief but complete description of the changes in the body.

Private helpers used only within their defining source file must have names beginning with `_`; functions and methods used across source files or exposed as API must not.

Variable and field names must reflect the actual type of the value they hold, not a related concept. For example, a `LocatorMeta` is `lm` or `locator_meta`, never `locator` (which denotes the `Locator` geometry entity); a `LocatorRecord` is `lr` or `locator_record`; a physical-group name string is `pg_name`, not `pg`. In a small scope where the type is obvious from context or a type annotation (a comprehension, a short loop body, a short function with annotated arguments), use very brief names (`lm`, `lr`, `pg`, `t`). In a large scope, or where no annotation lets a reader infer the type, use longer descriptive names (`locator_meta`, `locator_record`, `entity_tag`).
