# RFC draft: NPU-assisted frame presentation

Status: local proposal for discussion. Not a community decision, published RFC,
trained model, app integration or FPS result. 2026-11-06.

## Goal and scope

Preserve image quality and input responsiveness while improving stable motion on
Vision Pro. Investigate an inexpensive motion/confidence guide on the NPU, with
actual rendered colours and depth used by GPU reprojection. Keep the accepted
hand-tracking checkpoint available. Pistol support spacing and detached sights
remain separate work items.

Target: investigate presentation near 70 Hz when real game frames arrive around
17 Hz. Measure game simulation/rendering, presentation deadlines and input-to-
response latency separately. This proposal does not promise 70 real game FPS or
accurate knowledge of future player actions or newly appearing objects.

## What is already observed

- The inspected old run1/run4 decoders produced no active final features on four
  supplied probes. This is a liveness failure on those inputs, not a measurement
  of all inputs, a repair or an image-quality result.
- `app/Sources/npu_model.m` currently requires six input and six output channels.
  Its layers include fill RGB, motion XY and confidence. The current warp consumes
  that format. A proposed 16-input/3-output guide is not a drop-in replacement.
- The existing native path has asynchronous submission, bounded in-flight work
  and frame-number matching. These should be retained in any later adapter.
- Foreground separation is incomplete. Hands, weapon, reticle and HUD must not be
  treated as successfully separated merely because a mask input is proposed.

## Candidate for review

Start with a small convolutional guide at 256x144 FP16. Inputs describe current
and reprojected historical RGB/depth/motion, history validity/age, a reference
prediction horizon and foreground exclusion. Outputs are bounded motion
residuals and confidence, with no new colour generation.

`tools/interp_guide.py` is an untrained, standalone candidate. It validates shape,
feature/gradient liveness, bounded outputs, and hard exclusion where supplied
history/foreground masks say not to correct. Optional Core ML export checks only
conversion. It neither changes the app configuration nor reads old weights.

An initial rigid-mesh teacher pilot and experimental training have since run.
The combined moving-object metric improved, but the actual mesh-only metric
did not beat analytical acceleration. The Mac CPU+Neural Engine API timing also
did not beat CPU-only. This candidate fails adoption gates. See
[pilot results](NPU_PILOT_RESULT.md); no runtime integration or device FPS claim.

Open design questions, to resolve before runtime integration:

1. Agree on depth/motion units, history reprojection and validity semantics.
   Match the packer and consumer through an explicitly versioned new ABI.
2. Reconcile one inference per real frame with arbitrary display-time horizons.
   A single reference-horizon motion field scaled on the GPU is a candidate,
   not yet a verified model of acceleration or abrupt changes.
3. Define which objects can be predicted and when depth/occlusion/confidence
   require using the existing reprojection instead.
4. Agree on defaults, a user-visible opt-in, fallback behavior and adoption gates.
   Do not replace the accepted default rendering path during this experiment.

## Data and evaluation gates

1. Build a small, reproducible offline teacher-data pilot from the owner's game
   assets. Static assets alone are insufficient: render temporally consistent
   RGB, depth, motion, IDs, visibility and timestamps. The full material/scene/
   animation renderer is still missing.
2. Split by asset, scene and trajectory. Do not count neighboring frames or the
   already-used November 1 capture as an independent final evaluation.
3. Compare a trained candidate against simple reprojection, including unseen
   scenes, thin geometry, occlusion changes, reflections and sudden input.
4. On Vision Pro measure actual compute placement and pack-to-use p95/p99, not
   only Core ML prediction duration or a nominal compute plan. Include GPU
   contention, memory, missed deadlines, temporal flicker and input latency.
5. Use alternating enabled/disabled trials. Agree on acceptable regressions and
   rollback conditions before making a public default or release decision.

Original game data, generated samples, models and recordings remain local and
ignored. No trained model is currently approved or activated by this proposal.

## Proposed collaboration process

Discuss this proposal with contributors and affected maintainers. Summarize the
options, objections and agreed decision; then create scoped implementation
issues and link them from draft PRs. Preserve the decision and rationale in a
versioned record. An owner/AI's local design is still a proposal until that
process reaches agreement.

References: [existing detailed plan](NPU_FRAME_PLAN.md),
[GitHub discussion workflow](https://docs.github.com/en/discussions/guides/best-practices-for-community-conversations-on-github),
[Core ML performance measurement](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode).
