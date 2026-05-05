# Prompt: SDG Pilot Domains and Helper Cells

You are Codex. Deepen the SDG work in HAVEN Commons by adding a small set of operational pilot domains and by binding helper-cell bundles to them at runtime.

Goals:
- add a first pilot layer beneath `haven.sdg`
- keep taxonomy semantic and compact
- keep helper-cell configuration in runtime purpose templates
- reuse existing cells where possible

Required pilots:
- climate mobility
- local child participation
- institutional accountability

Rules:
1. Each pilot must add at least one taxonomy `purpose` and one taxonomy `goal`.
2. Each pilot must expose a measurable metric hint.
3. Add a runtime catalog that can materialize a `Purpose` with:
   - one concrete goal configuration
   - one baseline helper
   - one evidence helper
   - one fairness guardrail helper
4. Reuse existing cells such as `VaultCell`, `CommonsResolverCell`, `CommonsTaxonomyCell` and `EntityAtlas` before introducing anything new.
5. Keep the new documentation in English.
6. Add tests for the runtime catalog and helper bundles.

Output:
- taxonomy updates
- runtime catalog code
- tests
- English documentation for the pilot layer
