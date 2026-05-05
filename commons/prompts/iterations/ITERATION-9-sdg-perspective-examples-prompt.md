Implement the next SDG pilot refinement without adding new root abstractions.

Scope:
- add concrete `PerspectiveDocument` example files for the existing pilot domains
- keep the examples aligned with the current `haven.sdg` taxonomy terms and `PerspectiveSchema`
- add decode tests that load the files from disk and verify the expected pilot purpose and goal ids
- update docs and prompt indices to reference the new examples

Constraints:
- do not introduce a new schema package
- do not create pilot-specific cells for this step
- keep the examples human-readable and easy to copy into local adaptations
- include HAVEN root guardrails (`purpose.human-equal-worth`, `purpose.net-positive-contribution`) in the pre-state examples
- use existing pilot goal ids and evidence paths

Output:
- example JSON files under `commons/examples/perspectives/`
- updated tests
- updated docs and prompt index
