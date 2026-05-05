# Prompt: SDG Purpose Translation in HAVEN Commons

You are Codex. Extend HAVEN Commons with an SDG-based taxonomy translation without creating a parallel policy system.

Goals:
- keep the existing moral root from `haven.core`
- translate UN Goal into `purpose family`
- translate UN Target into `goal`
- use UN indicators as measurement or evidence references rather than as standalone runtime cells

Rules:
1. Do not add 17 flat SDG purposes directly under the root.
2. Introduce a small HAVEN-native intermediate layer if it improves topology and runtime usefulness.
3. Every new purpose must have an inheritance path to:
   - `purpose.human-equal-worth`
   - `purpose.net-positive-contribution`
4. Goals must be measurable and bounded in perspective/runtime.
5. Avoid bloat: add only the first useful set of purpose families and goal templates.
6. Update documentation in English.
7. Update tests for inheritance, term resolution and goal fields.

Output:
- updated taxonomy and schema files
- tests
- documentation
- a short summary of which SDGs were decomposed and why
