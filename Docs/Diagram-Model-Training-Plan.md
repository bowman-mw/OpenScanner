# Diagram model: training plan

*Draft for review, 2026-10-11. Companion to [Tier3-Model-Research.md](Tier3-Model-Research.md). Figures marked "(est.)" are planning estimates, not measurements. Phase 0 replaces the speed estimates with measured ones.*

**Goal.** Train a small on-device Core ML model that reads a photo of a hand-drawn diagram (whiteboard or paper) and returns its shapes, connectors with head and tail points, and text regions. Rescriva's existing graph code then turns those into a `Diagram` with nodes and directed edges. The model replaces steps 3–4 of the classical `DiagramDetector` (shape and connector finding) and keeps everything else: OCR labels, attachment, assembly and review flags.

**Approach in one line.** On the training PC (RTX 3070 Ti, 64 GB RAM), fine-tune RF-DETR's keypoint model (Apache-2.0) in two stages: first on synthetic sketches plus DIDI, then on about 4,000 real diagram images that already carry arrow head and tail labels, plus a few hundred of Rescriva's own photos. Then export it to Core ML on the Mac and plug it in behind the classical detector, which stays as the fallback and cross-check.

## 1. Starting points: what already exists

A second sweep of GitHub and Hugging Face on 2026-10-11 confirmed that no open model can be dropped into the app. Three existing projects are still useful as tools:

| Project | What it gives us | Why it isn't the shipped model |
|---|---|---|
| [Flowmind2digital](https://github.com/cai-jianfeng/flowmind2digital) ([weights](https://huggingface.co/caijanfeng/flowmind2digital), OpenRAIL) | Pretrained hand-drawn flowchart detector with arrow head/tail keypoints, 12 classes, trained on hdFlowmind | Detectron2 Keypoint R-CNN (ResNet-50-FPN): a two-stage server model with no Core ML path. **Optionally use it offline as a pre-labeller.** |
| [Two-pass diagram parser](https://github.com/HrishikeshVichore/Learning_Aligned_Two_Pass_Diagram_Parsing) (Apache-2.0 code, Oct 2026) | Notebook 03 is a complete **Arrow R-CNN re-implementation** (torchvision Faster R-CNN, ResNet-101-FPN, with head/tail keypoints) with training code for FA, FC_A and FC_B. Its reported directed-link F1 is 97.6% under its protocol | No checkpoints are published, and the model is too heavy for a phone. **Use it as a teacher model and accuracy ceiling.** |
| [RF-DETR](https://github.com/roboflow/rf-detr) keypoint (Preview) | Apache-2.0 code and weights, per-class keypoint counts, native `.mlpackage` export | This is the **student**: the model we ship. |

Everything else found is printed-only, licence-encumbered (AGPL YOLO fine-tunes), a single "flowchart region" detector, or a 3–32B vision-language model.

## 2. The model's contract

**Input.** The cleaned, perspective-corrected page that `DiagramDetector.detect(in:lines:)` already receives, resized to the model's fixed square input. That is 576×576 for RF-DETR keypoint; Phase 0 confirms or changes it. Preprocessing must match training exactly: the resize mode (stretch or letterbox) and the normalisation. Bake the normalisation into the Core ML graph rather than doing it in Swift.

**Output.** Up to 300 detections. Each has a class, a box, a score and, for connector classes, two keypoints `[tail, head]` with their own confidences. Swift does the top-k, the per-class thresholds and the duplicate suppression.

**Classes.** The model learns the shapes the data actually contains. Mapping them onto the IR is a policy in Swift, so the IR can grow later without retraining.

**IR change (decided 2026-10-11):**
- `Diagram.Shape` gains `.parallelogram`.
- `Diagram.Edge` gains a direction: `forward` (from → to), `none` (a plain line) or `both` (a double-headed arrow). Documents saved before the change decode as `forward`.
- Hexagon, octagon and cylinder stay as `otherShape` for now.

| Model class | Keypoints | IR (`Diagram.Shape` / `Edge.direction`) | Main sources |
|---|---|---|---|
| `rectangle` | — | `.rectangle` | FC process, DIDI box, synthetic |
| `roundedRectangle` | — | `.roundedRectangle` | FC terminator, BPMN task, synthetic |
| `ellipse` | — | `.ellipse` | FA state, BPMN event, DIDI oval, FC connection |
| `diamond` | — | `.diamond` | FC decision, BPMN gateway, DIDI diamond |
| `parallelogram` | — | `.parallelogram` | FC data, DIDI, hdFlowmind |
| `otherShape` (hexagon, octagon, triangle, trapezoid, cylinder, document) | — | `.rectangle` plus a review flag | DIDI, hdFlowmind, BPMN data objects |
| `container` (pool, lane, frame round a group) | — | Not a node; becomes `ShapeSearch.others` | hdBPMN, synthetic |
| `arrow` | tail, head | `forward`: `from` = tail side, `to` = head side | All |
| `doubleArrow` | end A, end B | `both` | hdFlowmind, synthetic |
| `line` | end A, end B | `none` | FC, hdFlowmind, synthetic |
| `text` | — | Not a node; masks out handwriting so it isn't read as strokes | All |

For `line` and `doubleArrow` the two ends have no natural order. Sort them canonically (left to right, then top to bottom) in every label so the keypoint loss doesn't fight itself.

**Swift hand-off.** A new `DiagramModel` converts detections into the detector's own types, in working-raster pixels:
- shape classes become `DiagramDetector.Shape` (kind, box, with the box as the outline);
- `container` becomes an entry in `ShapeSearch.others`;
- `arrow` becomes a `Segment` with `start` = tail and `end` = head, `endHead = true` and `startHead = false`. The outward vectors come from the tail→head axis, or from the ink near each tip when the arrow is curved;
- `line` and `doubleArrow` become `Segment`s with no head, or with a head at both ends. The existing `link` code turns these into `Link(directed: false)` and `Link(bothHeads: true)`, and `assemble` writes them as `.none` and `.both` edges.

`link`, `glyphLinks`, `labelNodes`, `labelEdges` and `assemble` then run unchanged. The `DetectedDiagram` and `Diagram` types don't change, as the detector's header already anticipates.

## 3. Data

### 3.1 Sources

| Source | Get it | Images | Labels ready? | Licence as stated | Role |
|---|---|---|---|---|---|
| FA | [Schäfer COCO repack](https://github.com/bernhardschaefer/handwritten-diagram-datasets) | 300 (132/84/84) | Boxes, arrow tail/head keypoints, source/target shape ids | None stated, © CMP | Train / val / test |
| FC_A | repack | 419 (248/—/171) | Same | CC BY-NC-SA 3.0 ([TC-11](https://tc11.cvc.uab.es/datasets/OHFCD_1)) | Train / test |
| FC_B | repack | 672 (280/196/196) | Same | None stated, © CMP | Train / val / test |
| FC_Bscan | repack | 672 (same drawings as FC_B, scanned) | Same | None stated, © CMP | Train / val / test, **same split as FC_B** |
| hdBPMN | repack (502, ICDAR 2021 version) + [dwslab/hdBPMN](https://github.com/dwslab/hdBPMN) v1.0.0 (704) | 704 | Repack: ready. The extra 202: convert with dwslab's MIT `pybpmn-parser` | CC BY 4.0 | Train / val / test (use `writer_split.csv`) |
| hdFlowmind | [HF dataset](https://huggingface.co/datasets/caijanfeng/hdflowmind) | 1,776 | VOC boxes plus connector head/tail | OpenRAIL | Train / val |
| DIDI | [google-research/didi_dataset](https://github.com/google-research/google-research/tree/master/didi_dataset) | 58,655 inks (43,995 train) | **No**: derive them (3.4) | CC BY 4.0 | Stage A pretraining |
| Quick, Draw! / HDS | [quickdraw](https://github.com/googlecreativelab/quickdraw-dataset), [HDS](https://github.com/frobertpixto/hand-drawn-shapes-dataset) | Single shapes | Class only | CC BY 4.0 | Real-ink parts for the generator |
| FC-Detection | [galirage/FC-Detection](https://huggingface.co/datasets/galirage/FC-Detection) | 99 printed flowcharts | Boxes plus arrow start/end boxes | Apache-2.0 | Optional; printed diagrams |
| Synthetic | Built in 3.3 | 100k (v1) | Exact, free | Ours | Stage A, and replay in stage B |
| Mermaid renders | Built in 3.3 | About 20k clean renders, plus Mermaid layouts for synthetic sketches | Exact, parsed from Mermaid's SVG | Ours (Mermaid is MIT) | Printed and on-screen diagrams; layouts and prompt sheets |
| Your photos | Collected in 3.5 | About 250: 100 test, 150 train (target) | Labelled by us | Ours | Fine-tune; **half of the frozen test set** |
| Web photos | Collected in 3.5 | About 300: 100–150 test, the rest train (target) | Labelled by us | Each image's own terms, logged per image | Other people's handwriting; **the other half of the frozen test set** |

About 4,300 real images (about 3,600 unique drawings) arrive already labelled with arrow head and tail. That is the main thing your licence decision unlocks: no hand labelling is needed for the bulk of the real data.

### 3.2 Splits and leakage rules
- Split everything **by writer**, never by image.
- FC_B and FC_Bscan are the same drawings. An image in one set's train split must not have its twin in the other set's test split.
- DIDI ships with writer-disjoint splits; keep them.
- Rescriva's test set is frozen as soon as it's collected. It holds about 100 of your photos, 100–150 web photos, and 200 *non-diagram* pages (text, tables, notes). Nothing trains on it and no thresholds are tuned on it; use a separate validation set for tuning.
- Hold out your photos **by drawing session**, not by image, so near-identical drawings can't sit on both sides.
- Report your photos and the web photos separately as well as combined. Your photos show Rescriva's real capture path; the web photos show other people's handwriting. A large gap between them means the model has learned your handwriting rather than diagrams.

### 3.3 Synthetic generator (Python, runs on the PC)
1. **Graph sampler.** Generate flowcharts, state machines, trees, mind maps, cycles and swimlane layouts, with 2–20 nodes and the class mix above. Labels are short words or phrases from a public-domain word list.
2. **Layout.** Use Mermaid's layouts (below) and Graphviz `dot` for layered layouts (a build-time tool; its EPL licence doesn't reach its output), plus our own grid, radial and "messy" layouts with jitter.
3. **Sketchy rendering.** Re-implement rough.js's stroke algorithm (MIT) in Python with skia-python: double strokes, bowing, overshoot at corners, uneven pressure and gaps.
   - Vary arrowheads: open V, filled triangle, half-head, double-headed or none.
   - Vary connectors: straight, curved and elbow.
   - Vary pens: marker, ballpoint, pencil, in several colours.
   - In a share of images, draw nodes with real ink: Quick, Draw! and HDS shapes stretched to the node box, and DIDI edge and text strokes once 3.4 is done.
4. **Text.** Use DIDI's handwritten label ink where available. Otherwise use OFL-licensed handwriting fonts from Google Fonts (check each font's licence file).
5. **Backgrounds and camera.** Use whiteboards with ghosting from erased marker, plain, lined and grid paper, notebooks and sticky notes. Shoot about 200 blank surfaces ourselves rather than using stock photos. Then apply perspective, blur, uneven light, glare, shadow, noise, JPEG artefacts and low resolution.
6. **Negatives and distractors.** Add tables (so cells aren't read as nodes), paragraphs beside the diagram, crossed-out words, doodles and stray marks. Include 10–15% pages with no diagram at all.
7. **Labels.** Write every box, both connector ends and every edge's source and target exactly, in the unified format (3.6).

Render once to disk: 100k images is about 15–20 GB (est.) and takes a few hours across the PC's CPU cores (est.). Training then reads files rather than rendering on the fly, which keeps the GPU fed.

**Mermaid.** Random Mermaid flowchart code, rendered with `mermaid-cli` (MIT), serves three jobs.
- **Clean renders** teach the model printed and on-screen diagrams. Vary the theme, font, direction (top-down or left-right) and size. Show them as printouts, slides and photos of screens, with the same camera effects as above.
- **Layouts for sketches.** Node and edge positions come from Mermaid's SVG, then the sketchy renderer redraws them by hand-like strokes.
- **Prompt sheets** for your drawing sessions (3.5). Each drawing then has a known graph, which makes labelling much faster.

Labels come straight from the syntax and the SVG:

| Mermaid syntax | Class |
|---|---|
| `[ ]` | `rectangle` |
| `( )` and stadium `([ ])` | `roundedRectangle` |
| `(( ))` | `ellipse` |
| `{ }` | `diamond` |
| `[/ /]` | `parallelogram` |
| `{{ }}` and `[( )]` | `otherShape` |
| `-->` | `arrow` |
| `---` | `line` |
| `<-->` | `doubleArrow` |

Dotted (`-.->`) and thick (`==>`) edges keep their class. Each edge's endpoints and arrowhead marker give its tail and head.

### 3.4 Labelling DIDI
Each DIDI drawing was traced over a Graphviz prompt whose `.xdot` file gives each node's polygon or ellipse and each edge's spline and arrowhead.
1. Scale the prompt coordinates onto the ink using the stored writing-guide size.
2. Assign each stroke to the nearest prompt element.
3. Take tight boxes around the assigned ink.
4. Snap each edge's tail and head to the nearest ink point of its strokes.
5. Reject drawings where less than about 80% of the ink falls within tolerance of an element (threshold to tune).
6. Spot-check 100 overlays by eye.

Fallback: label DIDI with the teacher (our Arrow R-CNN once trained, or Flowmind2digital) and keep only high-confidence diagrams.

### 3.5 Your photos and web photos

**Your photos** (target about 250 over 4–6 sessions):
- **Mostly from prompts.** Draw from printed Mermaid prompt sheets (3.3), so each drawing's nodes, edges and directions are known, and labelling only means fitting boxes and arrow ends. Add some free drawing too.
- **Vary everything one person can:**
  - surfaces: whiteboard, paper, notebook, sticky notes;
  - pens: markers and pens in several colours;
  - style: neat and rushed, small and page-filling;
  - camera: light, angle and distance, and two iPhones if possible.
- **Photograph through Rescriva's capture flow**, so the images get the same cleanup as users' scans. Record the session, surface, pen and phone in `metadata.csv`.

**Web photos** (target about 300):
- **Start with sources that state a licence:**
  - [Openverse](https://openverse.org), which searches Creative Commons images across many sites;
  - Wikimedia Commons;
  - Flickr with its licence filter.

  Then use general image search ("whiteboard flowchart", "hand-drawn diagram", "state diagram notes", in several languages).
- **Log every image** in `web_sources.csv`: URL, page, author and licence if shown, date saved, and a file hash. The log feeds the acknowledgements and lets any image be removed on request.
- **Skip** images showing faces, names or what looks like confidential work content, plus AI-generated images and near-duplicates (catch these with a perceptual hash).
- **Test more than train.** They are the only real photos with many different hands, so most go to the test set.

**Labelling.** Use CVAT (MIT) or Label Studio (Apache-2.0) on the PC; both support keypoints. Pre-label with the teacher model and correct by hand.
- Prompt-based drawings take about 1–2 minutes each.
- Web photos take about 2–4 minutes each.
- That is roughly 15–25 hours of labelling in all (est.), spread over Phases 1–3.

### 3.6 One label format for everything
Use one JSON record per image:
- the source dataset and licence id;
- the split and writer id;
- objects: class, box, optional polygon, and `[tail, head]` for connectors;
- edges: connector id → source object id and target object id;
- text boxes with transcripts where known.

Converters read each source into this format. Exporters write COCO-keypoints for RF-DETR and the teacher, and boxes plus head/tail boxes for the box-only fallback. Every exported file carries a manifest of the sources it includes, so a dataset can be dropped and the model retrained without hand edits.

## 4. Training machine and workflow

### 4.1 Who does what

| Machine | Jobs |
|---|---|
| **Training PC**: RTX 3070 Ti (8 GB), 64 GB RAM, large disk | Downloads and conversion; synthetic rendering; DIDI labelling; teacher and student training; pre-labelling; labelling tool; detection metrics and proxy graph scores (6.1) |
| **Mac** (M5, 16 GB) | Core ML export and parity check; the Swift harness that runs the real `DiagramDetector` graph code (6.2); Xcode integration; iPhone profiling |
| **Cloud GPU** (backup only) | Stage A, only if one run on the 3070 Ti would take more than about 3 days, or the Small model won't fit in 8 GB. A day on a single A100 costs very roughly $15–40 (est.) |

### 4.2 Setting up the PC (about half a day, est.)

**If it runs Windows**, train inside WSL2:
1. Install the current NVIDIA Windows driver. It provides CUDA inside WSL. **Don't** install a Linux NVIDIA driver inside WSL.
2. Run `wsl --install -d Ubuntu-24.04`.
3. WSL gets half the PC's RAM by default. Give it most of the 64 GB in `%UserProfile%\.wslconfig`, then run `wsl --shutdown`:
   ```ini
   [wsl2]
   memory=52GB
   swap=16GB
   ```
4. Keep code and data **inside the Linux filesystem** (`~/rescriva-ml`, `~/rescriva-data`), not under `/mnt/c`. Reading Windows drives through WSL is far slower and would leave the GPU waiting. If the big disk isn't C:, move the distro there with `wsl --export` and `wsl --import`.
5. While plugged in, set the PC never to sleep. Set Windows Update's active hours, or pause updates, around long runs: sleep or an update restart stops a multi-day run.

**If it runs Linux**, install the NVIDIA driver and skip the WSL steps.

**Inside Ubuntu:**
- Install `uv` and Python 3.11, then create a `rescriva-ml` environment with PyTorch (CUDA 12 build) and a pinned `rfdetr`.
  - Check that `torch.cuda.is_available()` and `torch.cuda.is_bf16_supported()` both return true. The 3070 Ti is Ampere, so it supports bf16.
  - The Arrow R-CNN teacher needs only torch and torchvision, so it shares this environment.
- An optional second environment, `detectron2`, runs Flowmind2digital for pre-labelling. Detectron2 must be built from source with a CUDA toolkit that matches PyTorch. Skip it unless DIDI labelling from the xdot files falls short.
- Install Node.js and `@mermaid-js/mermaid-cli` (MIT) for the Mermaid renders; it brings its own headless Chromium.
- Install `tmux` (runs survive a closed terminal), `nvtop` (GPU monitor) and TensorBoard. Serve TensorBoard on the home network so progress can be watched from the Mac.

### 4.3 Code, data and hand-off
- **Code** goes in its own git repo, `rescriva-ml`, separate from the app:
  ```text
  rescriva-ml/
    pyproject.toml, uv.lock     pinned versions
    data_tools/                 one converter per source → unified format; DIDI labeller
    generator/                  graph, layout, sketch renderer, compositor
    train/                      student.py, teacher.py, configs/*.yaml
    eval/                       detection metrics, proxy graph scorer
    export/                     Core ML export and parity check (run on the Mac)
    DATA_SOURCES.md
  ```
- **Data** lives only on the PC under `~/rescriva-data/` (`raw/`, `unified/`, `synthetic/`, `runs/`) and never goes in git. Raw downloads stay untouched; everything else can be rebuilt from them by script.
- **Each run** writes `runs/<date>-<name>/` with its config, its data manifest (sources plus file hashes), metrics and checkpoints, so any shipped model traces back to exactly the data it saw.
- **Hand-off:** copy the chosen checkpoint to the Mac (`rsync` over SSH, or any shared folder). Export it there; the `.mlpackage` then goes into the app.

### 4.4 Fitting in 8 GB of video memory
Work down this list until a run fits:
1. Mixed precision in bf16.
2. `batch_size="auto"`, which probes the GPU, plus gradient accumulation to an effective batch of 16. Expect 2–4 images per step at 576 px (est.).
3. RF-DETR's gradient checkpointing.
4. Nano instead of Small.
5. The cloud GPU for that one run.

Use the 64 GB of RAM to keep the GPU busy: run 8–12 data-loader workers with pinned memory, and cache the roughly 4,000 real images in RAM.

### 4.5 Time budget on the 3070 Ti (est.)
This assumes RF-DETR Small trains at roughly 10–25 images per second at 576 px, and the teacher at 3–5. Phase 0 measures the real rates and this table gets updated.

| Job | Size | Time (est.) |
|---|---|---|
| Phase 0 spike on FC_B | 280 images × 20 epochs | under 1 hour |
| Synthetic rendering (CPU) | 100k images | a few hours |
| Teacher (Arrow R-CNN) | about 3k real images × 25 epochs | 4–7 hours |
| Teacher pre-labelling of DIDI and the photos | about 60k images, inference only | 1–3 hours |
| **Stage A** pretrain | about 104k images (60k synthetic + 44k DIDI) × 12 epochs | 14–35 hours |
| **Stage B** fine-tune | about 9k images per epoch × 40 epochs | 4–10 hours |
| **Stage C** round | from the stage B checkpoint, about 20 epochs | 2–5 hours each |
| Retrain after dropping a source | Stage B only (stage A too if the source was DIDI) | overnight (about 2 days with stage A) |

In total that is about 1–2 weeks of unattended compute spread across the 8 weeks. Start long runs in the evening, and save a checkpoint every epoch so an interrupted run resumes rather than restarts. Check the resume argument in the pinned `rfdetr` version.

## 5. Training

### 5.1 Phase 0 spike: prove the path before building data (3–5 days including PC setup, est.)
1. Set up the PC (4.2) and pin the `rfdetr` version.
2. Fine-tune the RF-DETR keypoint model, Small, for 20 epochs on FC_B from the repack, with all FC_B classes. Record images per second and peak video memory. Fill in the real rates in 4.5.
3. Check that classes with zero keypoints and classes with two can share one model. The API takes `num_keypoints_per_class`, but nobody has reported trying this.
4. On the Mac, export to `.mlpackage` with fp16. Check parity against PyTorch, then run it on an iPhone and read the Xcode Core ML performance report. Note which ops land on the CPU (top-k and gather are expected to) and the latency.
5. Measure arrowhead size in pixels at 576 px across FC_Bscan and hdBPMN. Decide between a single pass and a two-pass crop (5.4).

**Gate G0.** If the keypoint model won't train mixed classes or won't export, switch to the fallback: RF-DETR *detection*, or YOLOX (Apache-2.0), with `arrowHead` and `arrowTail` as extra small box classes paired in Swift. Every other part of the plan stays the same. If Small won't fit in 8 GB even with section 4.4's steps, use Nano.

### 5.2 Models
- **Student (shipped): RF-DETR keypoint, Small** (Nano if 8 GB or iPhone latency forces it). These are about 30–41M parameters, roughly 40 MB after 8-bit palettisation (est.).
- **Teacher (offline only): Arrow R-CNN** from the Apache-2.0 notebook, trained on all real train splits at 1–2 images per step. It does three jobs:
  1. it pre-labels DIDI (if needed), your photos and the web photos;
  2. it sets the accuracy ceiling;
  3. it checks whether the student's errors come from data or capacity.

### 5.3 Stages
| Stage | Data | Aim |
|---|---|---|
| A. Pretrain | 60k synthetic sketches (including Mermaid layouts) + 10k clean Mermaid renders + DIDI train (derived labels), rendered with photo augmentation, 12 epochs. Grow it only if stage B results keep improving with more stage A | Learn shapes, arrowheads, printed diagrams, and text versus strokes |
| B. Fine-tune | All real train splits (FA, FC_A, FC_B, FC_Bscan, hdBPMN, hdFlowmind, your photos, web photos), with 30–50% synthetic and Mermaid replay, 40 epochs | Close the gap to real ink and photos |
| C. Hard examples | Run on the validation sets and newly collected photos; add generator variants for each failure type; retrain from B | Fix systematic misses, e.g. faint marker, tiny heads, curved arrows |

**Augmentation rules:**
- Flips are fine, but **never swap head and tail**. Many keypoint pipelines carry a left/right "flip index" for human poses; set it to identity.
- Rotate ±15°, plus 90° steps at a low rate.
- Jitter scale and colour, add blur and JPEG artefacts.
- Render the clean online-ink sets (FA, FC_A, FC_B, DIDI) with random pens, backgrounds and camera effects, so they look like photos rather than tablet ink.

**Model selection:** pick checkpoints by **validation proxy edge F1** (6.1), not by box mAP alone.

### 5.4 Small diagrams on large pages
A diagram drawn in one corner of a notebook page can shrink arrowheads below what 576 px can resolve. If Phase 0 shows this, run two passes:
1. Run the whole page to find the diagram's extent (the union of node and connector boxes).
2. Crop that extent plus a margin, and run again at full input resolution.

Train with both whole-page and cropped views so the model handles both scales.

## 6. Evaluation

### 6.1 On the PC, every run
Detection metrics come from the model's raw output:
- per-class AP50;
- keypoint error as a fraction of arrow length;
- **direction accuracy** on matched arrows.

A **proxy graph score** uses a small Python assembler: attach each tail and head to the nearest node box, then score node F1, **directed edge F1** and diagram recognition rate. This drives model selection and iteration without leaving the PC.

### 6.2 On the Mac, at each gate
A macOS command-line tool runs the real `DiagramDetector` (classical, and the Core ML model through `DiagramModel`) on a folder of images and writes graph JSON. The same Python scorer then compares it with the labels. This is the authoritative end-to-end score, and it also measures the false-diagram rate on non-diagram pages. The classical detector is pure Foundation, CoreGraphics and Vision, so it runs on the Mac as-is.

**Test sets:**
1. **Rescriva frozen test set** (primary): your held-out photos and the held-out web photos, reported separately and combined;
2. FC_B, FA, FC_A and hdBPMN test splits, so results compare with published Arrow R-CNN numbers (diagram recognition 78.6% on FC_B, 83.3% on FA, 68.4% on FC_A);
3. the 200 non-diagram pages.

**Ship gate G2** (agreed 2026-10-11; targets, not yet measured):
- on the combined Rescriva test set, directed edge F1 is at least 85% and at least 10 points above the classical detector;
- direction accuracy is at least 95% on matched arrows;
- the false-diagram rate is no worse than the classical detector's;
- the model runs in at most 300 ms per page on the oldest iPhone that runs iOS 26 (iPhone 11 or SE 2nd generation, A13 chip), and at most 100 ms on a current Pro (est. budgets);
- it is at most 45 MB in the app.

## 7. Core ML export and app integration (on the Mac)

1. **Export.** Use `rfdetr`'s Core ML exporter (the same pinned version as training) with a fixed input size and fp16. Palettise the weights to 8 bits with `coremltools.optimize`. Re-run the harness on the Core ML model: graph metrics must stay within 1 point of PyTorch.
2. **Add to Xcode.** Register the `.mlpackage` in the old-format `openscanner.xcodeproj` with the same scripted file registration used for other new files.
3. **`scanner/Rebuild/DiagramModel.swift`:**
   - load the model lazily once, with compute units `.all`;
   - preprocess exactly as in training;
   - decode with sigmoid, top-k, per-class thresholds and suppression;
   - map the detections into `Shape`, `ShapeSearch.others` and `Segment`, as in section 2.
4. **Hook in `DiagramDetector.detect`.** When the model is available, it replaces `findShapes(in:)` and `findSegments(in:nodes:others:)`. The ink mask and `StrokeLayer` stay, because the outward vectors and colour sampling need the ink.
5. **Cross-check and flags:**
   - The app already has three review sheets: `directionFlag` ("Which way does this arrow go?"), `plainLineFlag` ("Is this an arrow?") and `bothWaysFlag`. The model's edges use them the same way the classical detector's do.
   - An `arrow` keeps `.forward` with no flag only when all three hold: the head keypoint is confident; head and tail are well apart; and the classical arrowhead test at that tip agrees. Otherwise it gets `directionFlag`.
   - A `line` becomes `.none`. The classical detector always flags `.none`, because a faint arrowhead is easy to miss. The model may skip the flag only when the `line` score is high **and** the classical test finds no head at either end; otherwise it gets `plainLineFlag`.
   - A `doubleArrow` becomes `.both` with `bothWaysFlag`, unless both head confidences are high.
   - Tune these thresholds on the validation set so that, on the test set, unflagged edges are right at least 98% of the time (est. target).
   - If the model finds no diagram where the classical pass finds one, or the reverse, take the higher-confidence result. Record which detector produced each diagram as `Provenance(engine: "diagramModel-v1", confidence:)`.
6. **Fallback.** If the model is missing, fails to load or takes too long, the classical detector runs on its own. Older devices and the macOS harness keep working.
7. **Tests.** Add XCTest fixtures (images plus expected graphs) for both paths, and a performance test on device.

## 8. Provenance and acknowledgements

Following your decision, every source is credited:
- **`DATA_SOURCES.md`** (in `rescriva-ml`, copied into the app's `Docs/`). For each dataset and pretrained weight (RF-DETR and its DINOv2 backbone): the name, link, authors, the paper to cite, the licence exactly as stated, and how it was used.
- **The in-app Acknowledgements screen** lists the same sources and citations. It also gives:
  - the licence name and link for CC BY and CC BY-NC-SA (FC_A) sources;
  - CMP Prague's copyright line for FA, FC_B and FC_Bscan;
  - the OpenRAIL use restrictions from hdFlowmind (and Flowmind2digital, if used), carried into Rescriva's terms.
- **Web photos** are credited from `web_sources.csv`: a general credit on the Acknowledgements screen, with the full per-image list in `DATA_SOURCES.md`. Any image can be removed on request.
- **Every source can be switched off** in the export manifest. Retraining without one takes a night, or about 2 days if it was DIDI (4.5).
- **Optional courtesy emails** to CMP (Bresler, Průša), the University of Nantes (Mouchère) and Xidian (the Flowmind2digital authors) saying how their data is used. A friendly yes on record is cheap.
- **Before release:** the SAP patents noted in the research report (US 10,956,727 B1 and US 11,663,761 B2) still need a freedom-to-operate check. That applies to any ML diagram recogniser, whatever data it is trained on.

## 9. Phases

| Phase | Weeks (est.) | Work | PC compute | Exit |
|---|---|---|---|---|
| 0. Spike | 1 | PC setup; FC_B fine-tune; export and iPhone run on the Mac; arrowhead-size check | Under 1 hour of training | **G0**: keypoint path works and real speed is measured, or switch to the fallback |
| 1. Data and harness | 2–3 | Converters for all real sets; class mapping; splits; DIDI labeller; Mermaid renderer and prompt sheets; your first drawing sessions; web photo collection starts; PC scorer and Mac harness; classical baseline numbers | Teacher run (overnight) | All sources load into one format; test set frozen; baseline scored |
| 2. Model v1 | 3–5 | Generator v1 and rendering; stage A; stage B; first Core ML export and device timing | About 2–3 nights | **G1**: v1 beats the classical detector on Rescriva validation |
| 3. Iterate | 6–7 | Pre-labelling; hard examples; generator v2; remaining photos labelled; stage C rounds | 3–5 nights | v2 meets the accuracy part of G2 |
| 4. Integrate | 8 | `DiagramModel.swift` behind a feature flag; cross-check flags; fallback; tests; size and latency on the oldest supported iPhone | Final retrain if needed | **G2**: ship gate met |

About 8 weeks for one person (est.). The PC's compute fits inside that; the schedule depends mostly on how fast your photos and the web photos are collected and labelled.

## 10. Risks

| Risk | Mitigation |
|---|---|
| RF-DETR keypoint is a Preview and its Core ML export is experimental | Pin versions; Phase 0 gate; box-class fallback ready |
| 8 GB of video memory too small for Small at 576 px | Section 4.4's steps: bf16, accumulation, checkpointing, Nano, then the cloud for that run |
| A long run dies (sleep, Windows Update, crash) | Never-sleep and update settings; tmux; checkpoint every epoch and resume |
| Slow data loading leaves the GPU idle | Data in the WSL Linux filesystem; synthetic images rendered once; real sets cached in RAM; 8–12 workers |
| Tablet-ink sets (FA, FC_A, FC_B, DIDI) don't look like whiteboard photos | Heavy photo-style rendering; real photos from hdBPMN, hdFlowmind, FC_Bscan, your photos and web photos in stage B |
| Arrowheads too small at 576 px on full pages | Two-pass crop (5.4) |
| Synthetic data doesn't transfer | Real ink inside synthetic layouts; measure every stage on the frozen Rescriva test set |
| Tables, text or doodles read as diagrams | Negatives in synthetic data; 200 non-diagram test pages; false-diagram rate in the gate |
| Too slow on older iPhones | Nano variant, 8-bit palettisation, classical fallback by device class |
| A dataset author objects later | Per-source switches; overnight retrain |
| Your photos all share one handwriting | Many writers in training (DIDI's 364, plus hdFlowmind, the FC sets and the web photos); most web photos in the test set; report your photos and the web photos separately |
| Web photos have mixed or unknown terms | Licence-stating sources first; per-image log; removal on request; skip personal and confidential content |

## 11. Decisions (made 2026-10-11)
1. **IR additions: done** on branch `folio` at `2372ba3` (2026-10-11, not yet pushed).
   - `Diagram.Shape.parallelogram`.
   - `Diagram.Edge.direction` (`forward`, `none`, `both`); old documents decode as `forward`.
   - Review actions for a plain line and both ways.
   - Parallelogram classification and the new flags in the classical detector.
   - DOCX, PPTX, Mermaid and plain-text output.
   - Tests.

   Training labels therefore target 5 shapes and 3 edge directions.
2. **Photos:** you draw the handwritten photos yourself, Mermaid supplies printed diagrams and prompt sheets, and web photos supply other people's handwriting (3.5).
3. **Ship gate:** the numbers in section 6.
4. **Compute:** the 3070 Ti PC trains; the Mac exports and tests; a cloud GPU is a backup only (section 4).
