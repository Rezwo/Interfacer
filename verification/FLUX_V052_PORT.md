# Flux v0.5.2 UI and utility checkpoint

Source: [Flux v0.5.2](https://github.com/kohltastrophe/flux/tree/1a2ae9a332cef3f82ad311e743bc08614d5ae21b). This is a partial port onto Interfacer commit `8c3a79e558d2b1ab17664119298ef134ef9cec91`; it does not replace the original upstream pin for the rest of the package.

| Area | Disposition |
| --- | --- |
| Ordinary mappings | Adapted the upstream mapper for stable keys, reactive index/item inputs, empty fallbacks and row cleanup. Virtual mapping is independent. |
| Bindings | Adapted FromSignal and Listen on the current graph. The follow-up releases the shared effect after its final property or child binding disconnects; Typed On handles scalar, getter, and array sources; further binding changes remain pending. |
| Construction | Adapted the live, right-biased Merge property view. The follow-up adapts scoped Mount to the existing native child-binding path, including static and reactive targets. Prop and Own now supply scoped component prop defaults through Split. Other construction/portal deltas remain pending. |
| Async | Adapted pre-flush deduplication and isolated fetch launch from caller ownership and dependency tracking. |
| Layout and motion | Adapted Layout.Scale, Flex ratios/configuration and tween Snap. The clock/motion follow-up restores delay for resting tweens and exact settlement at rounded completion boundaries. Mid-flight retarget still skips the delay. Other motion and layout changes remain pending. |
| Store | Adapted multi-parent proxy ownership, cyclic reconcile, safe orphan teardown, NaN keyed matching, and frozen table handling. Registered cleanup already took precedence over a Destroy data key. |
| Clock | Manual rescheduling replaces stale queue entries for the same thread. Newly scheduled timers wait until the next frame without blocking older eligible deadlines. Other upstream clock hardening remains pending. |
| Input and responsive | Adapted release on interrupted input, and fallback to the live viewport when container measurements are unavailable. Other platform and occlusion changes are not part of this port. |
| Graph | Adapted bounded-stack traversal for known dormant dependency chains, typed the existing computed previous value, and added the optional Safe reset callback. The live follow-up adapts bounded-stack observer attachment, demand settlement and detachment. The rest of the upstream evaluator is not replaced by this checkpoint. |
| Overlays, exits, virtualization and examples | Unchanged; native and example validation pending. Sync is out of scope. |

The pinned upstream standalone smoke passes. The 253 portable assertions, nine operation-count rows, and four focused port replays run through `verify_distribution.py`. The 78 native skips are not passes. This checkpoint does not claim Studio, performance, or release acceptance.

The Mount/binding follow-up adds three native regressions and one portable Mount replay. Both Immediate and Deferred passed 350 client tests with verified event delivery and matching source readbacks. The evaluator and extras are unchanged.

## Typed UI follow-up

On unwraps a scalar node/getter, or each element of a dense array, without tracking reads made inside the callback. Array ordering is preserved; heterogeneous Luau arrays type their entries as a union, not a tuple. The previous input and previous callback result remain separate. Plain non-array tables pass as single values.

Use Prop() to claim a key or Prop(Value) for a default; Own combines schema tables with the rightmost declaration taking precedence. Split fills only nil or missing values. Plain mutable default table graphs are cloned per split, preserving cycles and sharing inside each default. Frozen tables and values with metatables keep their identity. If multiple Split groups claim a key, the first group wins.

## Store and async follow-up

Shared store proxies linked by reads or writes remain reactive when another linked parent drops them. Losing the last reachable parent releases proxy cycles, and reconcile guards against revisiting cyclic backing tables. Async launch uses the existing owner and tracking controls without replacing the evaluator. The focused replays are included in distribution verification.

## Clock and motion follow-up

The manual-clock replay reproduced four failures: stale reschedules, blocked eligible timers, skipped tween delay from rest, and a stalled tween at its rounded completion boundary. Cancellation/FIFO and spring momentum on retarget already worked and remain covered. The inherited reactive tween delay test now checks public behavior without manually resetting the internal tween.

## Responsive, input, and layout follow-up

ScaleOf and BreakpointOf accept unavailable container measurements and follow the global viewport until the container publishes a value. Layout.Corner resolves reactive overrides before selecting the first available corner, side, radius, or default. Press releases on cancellation and window focus loss and ignores a begin event for an already finished input. These changes do not alter the evaluator, overlay focus policy, or virtualization.

## Graph follow-up

A primed dormant chain of 24,000 computed nodes overflowed the old recursive refresh after a source update. The fallback switches from recursive to explicit-stack traversal after 128 known dormant dependencies. It does not make cold callback recursion or all live paths unbounded. Computed callbacks may declare an optional previous value. A function-style Safe fallback may save a second reset argument for retrying after the attempt returns; the retry coalesces before evaluation and is revoked on disposal. The graph operation fixtures and exact counts remain required.

### Deep live follow-up

Observer activation, demand settlement and last-observer release use iterative traversal once the recursive depth reaches 128. Attachment resolves each in-progress parent's height before propagating it to its own parent, avoiding repeated height propagation along the attaching chain. The 24,000-node replay covers hook order, two observers sharing the same chain, demand before Flush, exact recalculation counts, and full detachment. Cold user callback recursion and arbitrary height raises on already-live dynamic dependencies are not addressed here.
