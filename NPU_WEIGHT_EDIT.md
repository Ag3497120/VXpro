# Existing interpolation weights: gradient-free editing

`tools/interp_weight_edit.py` uses the existing, locally trained VX model. It
does not download weights, run an optimizer, or perform backpropagation. Source
checkpoints remain read-only. Every explicit trial is saved separately with its
source SHA-256 and edit name. A trial can be rejected; exporting a checkpoint is
not evidence that it improves the game.

The current bounded experiment edits only the last convolution: average the four
pixel-shuffle phases, reduce/remove the fill residual, or neutralize confidence.
It selects on calibration bursts, freezes the choice, then reports the original
and candidate on the pre-existing held-out burst split. A zero-weight final head
has an exact shortcut for offline scoring; a test compares it bit-for-bit with
the full network on multiple inputs. Nonzero heads use the original network.

2026-11-06 local findings:

- Later run3/run4 checkpoints have exactly zero feature weights in the final
  convolution. Their residual outputs therefore depend only on 24 bias values;
  they cannot use their hidden image features to adapt motion or confidence.
- In the bundled run1 checkpoint, those weights are nonzero, but the final
  decoder ReLU was entirely inactive on the inspected real capture frame.
  This observation alone does not establish inactivity on every possible input.
- Four edits to run4 (96 calibration / 192 held-out pairs) and five to run1
  (64 calibration / 192 held-out pairs) did not select an edit over the original
  on the calibration PSNR criterion. No edited model is enabled in the app.

Private reports and trial checkpoints live under
`build/hand-session-v2/weight-edit-existing/` and `weight-edit-deployed/`.
Their PSNR is a soft-composite screening result on an old recording, not an
independent recording, a temporal-quality acceptance test, or measured headset
FPS. The actual Metal warp, device memory/latency and visual artifacts are still
acceptance gates for any future candidate. A targeted weight edit can be useful
for model repair; these trials do not establish a method for creating missing
motion features in a collapsed model.
