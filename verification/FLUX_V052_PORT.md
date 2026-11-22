# Flux v0.5.2 UI and utility checkpoint

Source: [Flux v0.5.2](https://github.com/kohltastrophe/flux/tree/1a2ae9a332cef3f82ad311e743bc08614d5ae21b). This is a partial port onto Interfacer commit `8c3a79e558d2b1ab17664119298ef134ef9cec91`; it does not replace the original upstream pin for the rest of the package.

| Area | Disposition |
| --- | --- |
| Ordinary mappings | Adapted the upstream mapper for stable keys, reactive index/item inputs, empty fallbacks and row cleanup. Virtual mapping is independent. |
| Bindings | Adapted FromSignal and Listen on the current graph. Native property-rebinding optimizations, typed multi-source On and broader upstream binding changes remain pending. |
| Construction | Adapted the live, right-biased Merge property view. Mount, Prop/Own, defaults and the native construction/portal deltas remain pending. |
| Async | Adapted pre-flush deduplication. Fetcher isolation remains pending. |
| Layout and motion | Adapted Layout.Scale, Flex ratios/configuration and tween Snap. Native layout verification and the remaining motion changes are pending. |
| Store, clock, input and responsive | No port in this checkpoint. |
| Graph | Unchanged. The existing evaluator passed a primed 5,000-node chain probe; that is not an unbounded-depth claim. Upstream evaluator integration, computed callback typing, Safe reset and the comparative performance gate are pending. |
| Overlays, exits, virtualization and examples | Unchanged; native and example validation pending. Sync is out of scope. |

The pinned upstream standalone smoke passes. The 253 portable assertions, nine operation-count rows, and four focused port replays run through `verify_distribution.py`. The 78 native skips are not passes. This checkpoint does not claim Studio, performance, or release acceptance.
