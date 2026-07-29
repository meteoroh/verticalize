# Research: replacing Vision's FeaturePrint with a person-ReID model

**Status:** research complete, implementation *not* recommended yet — see [Recommendation](#recommendation).
**Date:** 2026-07-29

## The question

`PersonScanner` describes each detection with Vision's
`GenerateImageFeaturePrintRequest`, a general-purpose image embedding. It is not
trained to answer "are these two crops the same person", which is the only
question this app asks of it. A purpose-built person re-identification (ReID)
model is the obvious upgrade. Is it worth doing, and with what?

## Decision criteria for *this* project

Ordered by how likely each is to kill a candidate outright:

1. **License permits commercial redistribution.** The repo is MIT and public.
2. **Converts to Core ML** and runs on the Neural Engine.
3. **Costs no more than ~5 ms per crop.** Vision's FeaturePrint was measured at
   **4.3 ms** on a 160×320 crop, and descriptors are computed for every
   detection in a contested frame — on the sample clip, 1331 of 7620 detections.
4. **Small enough to bundle.** The app currently ships zero models and zero
   dependencies; that is a property worth spending carefully.
5. **Beats FeaturePrint on real footage**, not on a benchmark that looks nothing
   like it.

## Candidate landscape

**OSNet** (from `KaiyangZhou/deep-person-reid`, "torchreid") is the clear
technical fit. Purpose-built for ReID, and startlingly small:

| Variant | Params | GFLOPs | Market-1501 R1 (mAP) | MSMT17 R1 (mAP) |
|---|---|---|---|---|
| `osnet_x1_0` | 2.2M | 0.98 | 94.2 (82.6) | 74.9 (43.8) |
| `osnet_x0_75` | 1.3M | 0.57 | 93.7 (81.2) | 72.8 (41.4) |
| `osnet_x0_5` | 0.6M | 0.27 | 92.5 (79.8) | 69.7 (37.5) |
| `osnet_x0_25` | 0.2M | 0.08 | 91.2 (75.0) | 61.4 (29.5) |

For scale: SAM 3, analysed earlier and rejected, is **848M** parameters. OSNet
x1_0 is ~385× smaller. At fp16 the weights are roughly 4–5 MB — genuinely
shippable, and 0.98 GFLOPs should sit comfortably inside the 5 ms budget.

The variants that matter most here are the **multi-source domain-generalization**
ones (`osnet_ain_x1_0`), trained across several datasets specifically to
generalise to unseen camera domains. That is exactly our situation: arbitrary
user footage, not a benchmark camera network. Same-domain benchmark numbers
(94.2% R1) will *not* transfer; the cross-domain figures are the honest guide.

The torchreid **code** is MIT (Copyright © 2018 Kaiyang Zhou) with no commercial
restriction.

## The blocker: training-data licensing

The code is MIT. **The weights are not obviously redistributable.**

Every published OSNet checkpoint is trained on some combination of Market-1501,
DukeMTMC-reID, MSMT17 and CUHK03. Market-1501 states it "should be used for
research only and you should not distribute or use it for commercial purpose."
DukeMTMC-reID is "released only for academic research" — and the parent
DukeMTMC dataset was withdrawn by Duke in 2019 over consent and ethics concerns.

Whether model weights are a derivative work of their training data is genuinely
unsettled law, not a question this document can resolve. But the risk is real
enough that bundling those weights into a public, MIT-licensed, potentially
distributed app is not something to do casually.

### Mitigations, best first

1. **Don't bundle the weights.** Ship the app clean, and have it fetch the model
   on first use with the licence surfaced to the user. Common practice in
   open-source ML apps, keeps the repo's licensing unambiguous, and makes the
   provenance the user's informed choice rather than a hidden liability.
2. **Train on synthetic data.** RandPerson (8,000 identities, 1.8M images) and
   FineGPR (1,150 identities, 2.0M images) are synthetic and sidestep the
   consent problem entirely. No off-the-shelf pretrained checkpoints were found,
   and their own licences were not confirmed — this is a research project in
   itself, not a shortcut.
3. **Accept it for personal use.** If the app is never distributed, none of this
   binds. Worth stating plainly rather than pretending otherwise.

## What integration would actually cost

The good news: `IdentityTracker` is already agnostic. It takes
`appearanceDistance: (Int, Int) -> Double?` and knows nothing about Vision. Only
`PersonScanner` changes. That abstraction was built for testability and pays off
here.

The less good news — three things that make this **not** a drop-in:

**The crop shape is wrong.** We currently feed the *top 50%* of the detection
box to FeaturePrint, on the theory that head and torso carry identity and legs
are background. ReID models are trained on **full-body** crops at a fixed
128×256 (w×h) aspect with ImageNet normalisation. Feeding them our half-crops
would waste most of what makes them better. This has to change alongside the
model.

**Every threshold needs recalibrating.** `reidDistance` (0.62),
`appearanceCeiling` (1.05), `mergeDistance` (0.80) and the ambiguous/clean
weights are all tuned to the scale Vision's FeaturePrint distance happens to
produce. ReID models typically use **cosine** distance on L2-normalised
embeddings, a completely different scale. Swapping the embedding invalidates
every one of those constants at once. They must be re-derived from measurement,
not guessed — see below.

**`DescriptorTable` changes shape**, holding float vectors rather than
`FeaturePrintObservation`, with cosine distance replacing
`FeaturePrintObservation.distance(to:)`. Straightforward, but it is where the
retain/prune logic lives.

## Evaluation protocol

Benchmark mAP on Market-1501 says nothing about whether this helps *your* clips.
The scan diagnostics already give us the machinery to answer it properly:

1. Run a scan on a clip with known ground truth (`sample2.mp4`, 4 people).
2. Dump every detection crop tagged with the track that claimed it.
3. For **both** embeddings, compute the distribution of distances for
   same-track pairs and different-track pairs.
4. The metric that matters is **separation**, not accuracy: how much do those
   two distributions overlap? Vision's current failure mode — producing swaps
   and splits simultaneously — is precisely the signature of two distributions
   that overlap. If the ReID model separates them cleanly, thresholds become
   easy and both failures go away at once.
5. Read the new thresholds straight off the ReID distribution rather than
   guessing.

Steps 3–5 are the whole point. They also produce the recalibrated constants the
integration needs.

## Recommendation

**Do not integrate yet.** The evidence does not currently justify it.

In the most recent scan of `sample2.mp4`, the `MERGES DECLINED` table contained
**zero** `tooFarApart` rows — every declined merge was rejected on frame
co-occurrence, not on appearance. Appearance was never the binding constraint
for the cast list. The four real people merged correctly; the one spurious entry
(0.8 s, ten frames) is a detection artefact, not an identity failure.

Swapping the embedding right now would be solving a problem the data does not
show us having, at the cost of a dependency, a bundled model, a licensing
question, and the recalibration of every threshold in the tracker.

### The trigger that would change this

Appearance quality still plausibly limits **within-track** identity — the crop
following the wrong person mid-clip — which no report measures, because a track
that swaps subjects still reports one continuous span. That is what the
"Show all tracks" overlay is for.

Revisit this document if either becomes true:

- The overlay shows labels jumping between people at crossings, **or**
- A future scan report shows `tooFarApart` declines clustered just above the
  merge threshold.

Either would be appearance being the binding constraint, and then OSNet x1_0 via
option 1 (fetch, don't bundle) is the plan.

## Sources

- [KaiyangZhou/deep-person-reid (torchreid)](https://github.com/KaiyangZhou/deep-person-reid) — MIT licence, OSNet model zoo
- [torchreid MODEL_ZOO.md](https://raw.githubusercontent.com/KaiyangZhou/deep-person-reid/master/docs/MODEL_ZOO.md) — parameter counts, GFLOPs, benchmark accuracy
- [Market-1501 benchmark](https://ieeexplore.ieee.org/document/7410490/) — research-only terms
- [DukeMTMC-reID evaluation repo](https://github.com/sxzrt/DukeMTMC-reID_evaluation) — academic-research-only licence
- [Core ML Tools conversion guide](https://apple.github.io/coremltools/docs-guides/source/convert-to-ml-program.html) — PyTorch/ONNX → `.mlpackage`
- Synthetic alternatives: RandPerson and FineGPR, surveyed in
  [Person Re-identification: A Retrospective](https://arxiv.org/pdf/2202.13121)
