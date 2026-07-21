# Tap accuracy work

Reviewed July 20, 2026. This document keeps physical evidence separate from synthetic tests and records why an accuracy change is accepted or rejected.

## Recovered baseline

The saved July 17 passive evaluation contains 60 recorded events and 42 correct classifications (70%):

| Zone | Correct | Rejected | Total |
| --- | ---: | ---: | ---: |
| Left Rear | 6 | 4 | 15 |
| Left Front | 10 | 4 | 15 |
| Right Rear | 13 | 2 | 15 |
| Right Front | 13 | 1 | 15 |

Seven additional events were assigned to the wrong zone. Median recorded-event latency was 73.0 ms. Completely undetected physical taps were not recorded by that version, so 70% is an optimistic end-to-end baseline rather than a passing result.

The profile with the same ID was recalibrated on July 20 with 40 examples and 90% leave-one-out agreement. It has no held-out report. Reusing the profile ID caused the old July 17 report to appear current even though it represented a different model revision; reports are now bound to both profile ID and calibration timestamp.

Exploratory replay between the two available saved calibration sets was approximately chance-level: the newer model classified 25% of the older vectors correctly, and the reverse direction classified 22.5%. This is not acceptance evidence because the saved sets do not carry complete session/setup provenance, but it makes cross-session drift the main risk. Both profiles also expose only aggregate mono input, so their nominal spatial feature fields are constant. A fixed spectral-only model helped the older set but hurt the newer set; there is no defensible classifier swap from these two sessions alone.

## What failed before

The July 17 accuracy attempt was commit `cc95cf7`, pushed directly to `main` and rolled back about 33 minutes later. It was not a reviewed pull request and had no associated CI/check record. The change adjusted detector gates, classifier confidence and separation thresholds, novelty/negative rejection, and the learned model at the same time. Although its synthetic suite passed, no post-change physical evaluation isolated which change helped or hurt.

Do not reapply that commit as one patch. Change one layer at a time and require a new physical report before keeping it.

## Current controlled change

This iteration leaves classifier weights, novelty, zone-separation, confidence, and dispatch rules unchanged; the signal-quality floor changes only after its SNR definition is corrected.

1. A peak at `2 ×` the learned floor with a `0.0015` absolute minimum arms an aligned capture with exactly 12 ms of pre-roll. A 1 ms energy-rise OR sparse-peak check filters stationary noise without the former fixed RMS, crest, and strong-sample conjunction, which rejected plausible rounded desk rings and direct impacts whose mechanical path arrived several milliseconds later. The complete 90 ms event gate rejects sustained sounds before classification.
2. Every prompted tap has one explicit monotonic listening window. An eligible detector event resolves it once; otherwise a timeout automatically records a miss in the 60-attempt denominator.
3. Evaluation JSON retains extracted features for detected attempts, enabling classifier replay without raw audio.
4. Reports are attached to the exact calibration revision, so recalibration cannot inherit a stale score.
5. The preprocessing schema is versioned. Old profiles remain available with their actions intact, but they cannot classify or evaluate version 2 onset-relative observations until the user creates a fresh calibration. New saves use a profile envelope that a rolled-back build will skip, and sensing-comparison recommendations must match the current feature schema.

Three local comfort checks showed that small threshold changes were not enough. The first exposed callback dilution, the second exposed the arm/full-event contrast coupling, and the third showed that most natural taps still disappeared. The complete-path audit found two additional silent drops: quality SNR divided full-band RMS across the whole 90 ms capture by a differently filtered noise floor, diluting a brief impact by roughly 15 dB, and calibration ignored every emitted event for 400 ms after an accepted sample even though the detector already owns deduplication.

The current slice therefore makes the front end deliberately high recall while preserving downstream action safety. It uses the `2 × floor / 0.0015` arm, caps adaptive-floor growth relative to the current floor, and replaces the former conjunctive short-window shape rules with an OR: 1 ms energy must rise 1.3× over the preceding 8 ms, or a sparse peak must clear that local reference by 2.75×. This preserves rounded desk rings and direct impacts with delayed mechanical paths while stopping ordinary noise peaks from occupying a 90 ms capture. The full-event gate uses 1.1 onset contrast plus decay, duration, and short-plateau evidence for sustained sounds. Signal quality now compares the onset peak with the preceding 12 ms in the same full-band domain; calibration and live classification share a 5 dB boundary, which still requires 1.78× local contrast. The redundant 400 ms calibration dead time is gone. Classifier schema, absolute peak, clipping, novelty, zone-separation, confidence, and automatic-dispatch gates remain unchanged.

Regressions now include a raw `0.009`-class tap embedded in actual deterministic `0.003` RMS room noise, a rounded 650 Hz desk ring, and a direct impact with a mechanical path delayed by 4 ms across all 512 callback phases. The complete pipeline also covers comfortable noisy-room taps through detection, calibration quality, training, and held-out prediction for all four zones. Synthetic evidence still does not establish a physical accuracy gain, so the next local run must use comfortable taps only.

## Next physical experiment

Use the current MacBook position and do not tune thresholds during the run:

1. Preserve the July 20 profile as historical evidence. Create a new passive calibration in the unchanged MacBook position so all 40 examples use version 2 onset framing.
2. Press **Start Tap**, wait for **Tap now**, and tap exactly once. The attempt resolves from the eligible detector event or automatically times out as a miss.
3. Retain the JSON and CSV report. Record room conditions and any typing, speech, or movement.
4. Compare overall and per-zone accuracy, missed detections, classifier rejections, wrong-zone assignments, and latency against the July 17 baseline.
5. Keep the detector change only if the fresh physical evidence improves repeatability without creating a false-trigger regression.

If accuracy remains below 80%, collect another calibration and evaluation in a separate session before changing the classifier. The leading research-backed hypothesis is session drift: tap-localization work emphasizes onset-aligned early transient features and evaluation across sessions or days, rather than choosing looser thresholds from the same calibration set. Relevant primary sources include [Hearing Your Touch](https://arxiv.org/abs/1903.11137), [Categorizing Touch-Input Locations via On-Board Mechano-Acoustic Transducers](https://www.mdpi.com/2076-3417/11/11/4834), and [Acustico](https://www.cs.dartmouth.edu/~hci/papers/Acustico.pdf).

Candidate classifier or feature changes must be compared with grouped whole-session validation and then confirmed on an untouched physical evaluation. Leave-one-out accuracy within one calibration session is diagnostic only.
