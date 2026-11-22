# Flux v0.5.2 UI and utility checkpoint

Source: [Flux v0.5.2](https://github.com/kohltastrophe/flux/tree/1a2ae9a332cef3f82ad311e743bc08614d5ae21b). This is a partial port onto Interfacer commit `8c3a79e558d2b1ab17664119298ef134ef9cec91`; it does not replace the original upstream pin for the rest of the package.

| Area | Disposition |
| --- | --- |
| Ordinary mappings | Adapted the upstream mapper for stable keys, reactive index/item inputs, empty fallbacks and row cleanup. Virtual mapping is independent. |
| Bindings | Adapted FromSignal and Listen on the current graph. The follow-up releases the shared effect after its final property or child binding disconnects; Typed On handles scalar, getter, and array sources; further binding changes remain pending. |
| Construction | Adapted the live, right-biased Merge property view. The follow-up adapts scoped Mount to the existing native child-binding path, including static and reactive targets. Prop and Own now supply scoped component prop defaults through Split. Other construction/portal deltas remain pending. |
| Async | Adapted pre-flush deduplication. Fetcher isolation remains pending. |
| Layout and motion | Adapted Layout.Scale, Flex ratios/configuration and tween Snap. Native layout verification and the remaining motion changes are pending. |
| Store, clock, input and responsive | No port in this checkpoint. |
| Graph | Unchanged. The existing evaluator passed a primed 5,000-node chain probe; that is not an unbounded-depth claim. Upstream evaluator integration, computed callback typing, Safe reset and the comparative performance gate are pending. |
| Overlays, exits, virtualization and examples | Unchanged; native and example validation pending. Sync is out of scope. |

The pinned upstream standalone smoke passes. The 253 portable assertions, nine operation-count rows, and four focused port replays run through `verify_distribution.py`. The 78 native skips are not passes. This checkpoint does not claim Studio, performance, or release acceptance.

The Mount/binding follow-up adds three native regressions and one portable Mount replay. Both Immediate and Deferred passed 350 client tests with verified event delivery and matching source readbacks. The evaluator and extras are unchanged.

## Typed UI follow-up

On unwraps a scalar node/getter, or each element of a dense array, without tracking reads made inside the callback. Array ordering is preserved; heterogeneous Luau arrays type their entries as a union, not a tuple. The previous input and previous callback result remain separate. Plain non-array tables pass as single values.

Use Prop() to claim a key or Prop(Value) for a default; Own combines schema tables with the rightmost declaration taking precedence. Split fills only nil or missing values. Plain mutable default table graphs are cloned per split, preserving cycles and sharing inside each default. Frozen tables and values with metatables keep their identity. If multiple Split groups claim a key, the first group wins.
