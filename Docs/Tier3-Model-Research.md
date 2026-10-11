# Clean data, not models, limits Folio's tier 3

*Research synthesis, 2026-10-10. Star counts and last-push dates are from the GitHub API on that date. "(est.)" marks a figure the research derived or extrapolated rather than read from a source or measured.*

Nothing in the open ecosystem can be bundled as-is for Folio's two core tier-3 jobs. Every hand-drawn-diagram recogniser either has no released code, carries an OpenRAIL or missing licence, or was trained on non-commercial data. Every handwritten-math checkpoint was trained on research-only CROHME or HME100K. The architectures are not the problem: Apache and MIT detectors and encoder-decoders exist and convert to Core ML. **The binding constraint is permissively licensed training data.** For diagrams, the best route is to fine-tune **RF-DETR's keypoint model** (Apache-2.0 code and weights, custom head/tail keypoints per class, a native `.mlpackage` exporter) on a synthetic sketch generator plus **hdBPMN** and **DIDI** (both CC BY 4.0). **YOLOX** (Apache-2.0) is the lower-risk conversion fallback and **Create ML** is a licence-free baseline. For printed math, **Pix2Text MFR 1.5** (MIT code and weights, about 30M parameters est.) is the only small recogniser with a clean code and weights licence, but its training data is undisclosed. For handwritten math, Folio must train on synthetic handwriting it generates itself, because no human-written dataset passes the licence gate. For figures, **PP-DocLayoutV3** (Apache-2.0, 33M) plus Docling's MIT figure classifier finds chart, picture and display-formula regions. No bold/italic/underline model exists. **No recommended model has a published iPhone latency.** SAP holds two active US patents on ML diagram recognition, which need a freedom-to-operate check before a commercial release.

## Diagrams: RF-DETR's keypoint head is the one licence-clean fit

Every serious offline system follows the same recipe: an object detector, arrow head/tail keypoints (or line tracing), then graph assembly. The published examples are Arrow R-CNN, DiagramNet, Sketch2Process and Flowmind2digital. Keypoints matter: in DiagramNet's ablation, adding arrow-keypoint supervision raised **edge F1 from 71.6 to 82.5** ([Schäfer thesis, Table 7.2](https://madoc.bib.uni-mannheim.de/64778/2/doctoral_thesis.pdf)). No diagram-specific system is usable, so Folio should rebuild the recipe on a permissive detector. Even mature systems trail on whole diagrams: Arrow R-CNN reaches 98–99% symbol precision on the classic sets but only **68–85% whole-diagram recognition**, and arrows are the main error source ([thesis, Tables 5.2–5.8](https://madoc.bib.uni-mannheim.de/64778/2/doctoral_thesis.pdf)).

| Candidate | What it does | Code · weights · training data | Size | Core ML feasibility | Activity | Verdict |
|---|---|---|---|---|---|---|
| [RF-DETR keypoint (Preview)](https://github.com/roboflow/rf-detr) | DETR detector on an Apache-2.0 DINOv2 backbone. Boxes plus per-class custom keypoint counts ([training docs](https://github.com/roboflow/rf-detr/blob/develop/docs/learn/train/index.md)) | Apache-2.0 · Apache-2.0 · COCO pretraining (terms not reviewed) + Folio's fine-tune data | 40.7M, 576×576 input; detection N–L 30.5–33.9M | Native `format="coreml"` export: experimental, fixed shapes, outputs `dets, labels, keypoints` ([docs](https://github.com/roboflow/rf-detr/blob/develop/docs/exports/coreml.md)). The ANE has no top-k or gather, so query selection runs on the CPU. An ANE rewrite cut Nano from 8.74 to 6.15 ms on an M4 Max ([PR #1586](https://github.com/roboflow/rf-detr/pull/1586)) | 9,759★, 2026-10-10 | **Use** (primary) |
| [YOLOX](https://github.com/Megvii-BaseDetection/YOLOX) | One-stage CNN detector (boxes) | Apache-2.0 · Apache-2.0 · COCO | Nano 0.91M, Tiny 5.06M, S 8.97M | Manual coremltools trace, with NMS in Swift. [#1780](https://github.com/Megvii-BaseDetection/YOLOX/issues/1780) reports odd objectness after conversion. A Core AI port of S runs about 22 ms on an iPhone 17 Pro GPU, but that is the iOS 27 `.aimodel` format, not Core ML ([HF](https://huggingface.co/mlboydaisuke/YOLOX-CoreAI)) | 10,658★, 2025-06-08 | **Maybe** (fallback; lowest conversion risk) |
| [D-FINE](https://github.com/Peterande/D-FINE) / DEIM v1 | DETR detectors (boxes) | Apache-2.0 · Apache-2.0 · COCO | — | Community conversion works with two tweaks ([#147](https://github.com/Peterande/D-FINE/issues/147)). Deformable sampling uses `grid_sample` → Core ML `resample`, which developers report falls back to the CPU ([forum](https://developer.apple.com/forums/thread/740621)) | 3,353★, 2026-10-05 | Maybe (box-only) |
| RT-DETR/v2; [MultimediaTechLab YOLO](https://github.com/MultimediaTechLab/YOLO) | Boxes | Apache-2.0 / MIT | — | RT-DETR: unresolved Core ML issues. MultimediaTechLab YOLO: no exporter | 5,585★ / 1,747★ | Maybe (weak) |
| [Create ML object detector](https://developer.apple.com/documentation/createml/mlobjectdetector/modelparameters-swift.struct/modelalgorithmtype) | Full YOLOv2 network, or a head trained on the OS feature extractor. Boxes only, no keypoints | Apple tool · Folio-owned · Folio data | About 7 MB (transfer learning, iOS 14+); 65 MB, or 33 MB fp16 (full network) ([tech talk](https://nonstrict.eu/wwdcindex/tech-talks/10155/)) | Native; returns Vision `VNRecognizedObjectObservation` | Xcode | **Maybe** (licence-free baseline) |
| torchvision / Detectron2 Keypoint R-CNN | Two-stage boxes plus keypoints | BSD-3 / Apache-2.0 · weights "may have their own" terms | 59.1M | No exporter; uses RoIAlign and dynamic proposals | 17,951★ / 34,879★ | Server-side reference only |
| Arrow R-CNN, DiagramNet, Sketch2Process ([thesis](https://madoc.bib.uni-mannheim.de/64778/2/doctoral_thesis.pdf)) | Faster R-CNN plus head/tail keypoints; edge networks | No code or weights released | ResNet-50/101-FPN | — | — | **No** (design reference; SAP patents) |
| [Flowmind2digital](https://github.com/cai-jianfeng/flowmind2digital) | Keypoint R-CNN: 8 shapes, text, and 3 connector classes with head/tail points | No LICENSE file · [OpenRAIL](https://huggingface.co/caijanfeng/flowmind2digital) · hdFlowmind (OpenRAIL) | ResNet-50-FPN | Detectron2; no export path | 14★, 2025-11-17 | **No** (closest class template) |
| [Visual-to-Graph](https://github.com/HrishikeshVichore/visual_to_graph_paper_reproduction) (2026) | SAM ViT-L, CRAFT and a ResNet-34 shape classifier | MIT · MIT · evaluated on FC_A/FC_B/FA (FC_A is NC) | SAM ViT-L | Too heavy | 0★, 2026-08-04 | **No** (its graph-repair post-processor is worth reading) |
| DrawnNet, dbetm flowchart CNN, GitHub long tail | — | No code; weights gated; unlicensed or GPL | — | — | — | **No** |
| Ultralytics YOLOv5/8/11/26, YOLOv10/12/13 | — | AGPL-3.0, extended by Ultralytics to trained models ([licence](https://www.ultralytics.com/license)) | — | Built-in exporter | 62,368★ | **No** |
| YOLOv6/v7/v9 (originals), mmyolo; YOLO-NAS; [DEIMv2](https://github.com/Intellindust-AI-Lab/DEIMv2/blob/main/LICENSE); RF-DETR Atto–Pico, XL/2XL | — | GPL-3.0; no-commercial weights; non-commercial since 2026-08-24; PML 1.0 | — | — | — | **No** |
| Diagram VLMs: ImgTikZ, DeTikZify-v2, DiagramAgent, Qwen3-VL Mermaid fine-tunes | Sketch to TikZ or Mermaid | Several have no weights licence | 3–9B | Not bundleable | — | **No** |
| Florence-2 (MIT), SmolVLM-256M (Apache-2.0) | Small VLMs, not trained on diagrams | Permissive | 0.23–0.78B / 256M | Community Florence-2-base Core ML: 229 MB, CPU-only, about 1.2 GB peak RAM ([HF](https://huggingface.co/mlboydaisuke/Florence-2-base-CoreML)) | — | Maybe (later) |

**Ranked shortlist for diagrams**

1. **RF-DETR keypoint, fine-tuned.** Use the classes `rectangle`, `roundedRectangle`, `ellipse`, `diamond` (exactly the four `Diagram.Shape` cases), plus `arrow` (two keypoints: head, tail), `line` (two endpoints) and `text`.
   - Size: about 81 MB fp16, or about 41 MB with 8-bit palettisation (est., parameters × bits).
   - Risks:
     - The Preview API and checkpoints "may change", and the exporter is experimental.
     - Nobody has tested whether classes with zero keypoints can mix with two-keypoint classes.
     - A search summary reports about a 3 AP drop for fp16 on the ANE with an iOS 16 target ([PR #1604](https://github.com/roboflow/rf-detr/pull/1604)).
   - Pin the `rfdetr` version.
2. **YOLOX-S or -Tiny with endpoint boxes.** Train `arrowhead` and `arrow-tail` as small box classes, as Arrow-Guided VLM did with endpoint boxes ([arXiv 2505.07864](https://arxiv.org/abs/2505.07864)). Alternatively, add a four-value head/tail regression to the arrow class.
   - Size: about 18 MB fp16 or 9 MB 8-bit for S (est.).
   - Trade-off: easier to convert, but weaker than true keypoints on curved arrows.
3. **Create ML transfer learning** with an `arrowhead` class. Use it as a benchmark against the classical baseline, not as the product model.

## Diagram data: synthetic sketches plus 704 real hdBPMN photos

The best-annotated academic sets cannot feed shipped weights:
- **FC_A** is CC BY-NC-SA 3.0 ([TC-11](https://tc11.cvc.uab.es/datasets/OHFCD_1)).
- **FC_B, its scanned extension and FA** state only "free to download" under a CMP copyright notice ([CMP](http://cmp.felk.cvut.cz/~breslmar/flowcharts/)).
- Rendering their InkML to images changes nothing.

Two permissive sources carry the load. **hdBPMN** is CC BY 4.0, verified in its README, its LICENSE file and GitHub's SPDX field. It holds **704 real photos and scans** of paper and whiteboard drawings, and its BPMN XML stores edges as ordered waypoints, from which tail and head can be derived ([dwslab/hdBPMN](https://github.com/dwslab/hdBPMN)). **DIDI** is CC BY 4.0 per Google's own repository, which settles a doubt raised in one note that had seen only a mirror. The arXiv page's NC-SA badge covers the paper, not the data. DIDI holds **58,655 hand-traced diagrams** from Graphviz prompts, but has no per-stroke labels, so labels must be derived by aligning each drawing to its prompt's xdot geometry ([DIDI](https://github.com/google-research/google-research/tree/master/didi_dataset)).

| Dataset | Content | Licence (as stated) | Verdict |
|---|---|---|---|
| [hdBPMN](https://github.com/dwslab/hdBPMN) | 704 real images; BPMN XML plus word boxes | CC BY 4.0 | **Use** |
| [DIDI](https://github.com/google-research/google-research/tree/master/didi_dataset) | 58,655 inks; box, oval, diamond, parallelogram and octagon nodes; directed edges | CC BY 4.0 | **Use** (derive labels) |
| [Quick, Draw!](https://github.com/googlecreativelab/quickdraw-dataset) | Single doodles: circle, square, diamond, line; **no arrow or rectangle** | CC BY 4.0 | Use (components) |
| [HDS](https://github.com/frobertpixto/hand-drawn-shapes-dataset) | 27,292 single hand-drawn shapes with vertices | CC BY 4.0 | Use (components) |
| [Geometric Shapes Mathematics](https://www.kaggle.com/datasets/reevald/geometric-shapes-mathematics) | Synthetic hand-drawn-style shapes | CC0 | Use (minor) |
| [CAS2UML](https://huggingface.co/datasets/Seym0n/cas2uml_hand-drawn_to_plantuml_dataset) | 557 hand-drawn UML diagrams, PlantUML labels, no boxes | CC BY 4.0 | Maybe (eval or pseudo-labels) |
| GoodFlow V3 / FlowGen / QZhou | Synthetic *printed* flowcharts | MIT / Apache-2.0 / Apache-2.0 | Maybe (printed only; check for per-element boxes) |
| [hdFlowmind](https://huggingface.co/datasets/caijanfeng/hdflowmind) | 1,776 real photos and scans with boxes and **arrow head/tail keypoints**: the best fit | "openrail", variant unnamed | Maybe (legal review, or ask the authors) |
| FC_A; FC_B, FC_Bscan, FA | Online flowcharts; best arrow annotations | NC-SA; none stated | **No** (internal benchmark at most) |
| [Flowchart 3b](https://www.kaggle.com/datasets/davbetm/flowchart-3b) | About 9k photographed symbols, four-way arrows | "Unknown" | **No** (ask the authors) |
| Large Roboflow Universe flowchart sets | Re-uploads, some of CMP data | Uploader-asserted CC BY 4.0 | **No** |
| SkeTikZ, DiagramSketch, FlowLearn, FlowVQA | — | Unstated / research-only / NC-SA / "refrain from using" | **No** |

**Training route.**
1. **Generator** (all tooling is MIT, Apache or EPL): sample graphs of 2–20 nodes, lay them out with dagre or mermaid (MIT), and render them sketchily with [rough.js](https://github.com/rough-stuff/rough) (MIT). Vary the arrowhead styles. Composite the result onto paper and whiteboard backgrounds with perspective, blur and glare. Every box, head and tail label comes exactly from the generator.
2. **Real strokes:** swap in real ink from DIDI, Quick, Draw! and HDS.
3. **Fine-tune** on hdBPMN plus consented Folio captures.

A plausible schedule is 50k–200k synthetic images, then fine-tuning on 1–3k real or rasterised-ink images. That schedule is an inference; no study has measured transfer from rough.js-style diagrams. The nearest evidence is a mockup detector trained on synthetic sketches and then real drawings, which reached about 95% mAP, roughly 1.5× better than real-only training ([SciTePress 2021](https://www.scitepress.org/Papers/2021/101936)). Hold out real Folio captures as the test set. The same generator output, as boxes only, trains the Create ML baseline.

## Equations: Pix2Text MFR covers print; handwriting needs Folio's own run

The handwritten-math research models are the right size for a phone, at **6–8M parameters**, and reach **55–65% ExpRate on CROHME** ([TAMER paper](https://arxiv.org/html/2408.08578v2)). However, every released checkpoint is trained on CROHME, which is "only for research purpose without any commercial use" ([ISI](https://www.isical.ac.in/~crohme/CROHME_data.html)), and/or on unlicensed HME100K.

The notes disagree on two models, and both are resolved here against the brief's three-axis rule:
- **pix2tex** has MIT code and weights, but its training data (Wikipedia, arXiv, im2latex) carries no data licence. It is reference-only.
- **TexTeller**'s handwritten subsets were "collected entirely from existing open source work" including test sets ([HF](https://huggingface.co/datasets/OleehyO/latex-formulas-80M)). It also used Nougat (CC BY-NC weights) to label its printed data ([paper](https://arxiv.org/html/2508.09220v1)). It fails the data axis.

| Candidate | What it does | Code · weights · training data | Size | Core ML feasibility | Activity | Verdict |
|---|---|---|---|---|---|---|
| [Pix2Text MFR 1.5](https://huggingface.co/breezedeus/pix2text-mfr-1.5) | Printed formula crop to LaTeX (handwritten examples, no metrics). DeiT-S encoder at 384×384 plus a 6-layer TrOCR decoder, vocab 1,868 ([config](https://huggingface.co/breezedeus/pix2text-mfr-1.5/blob/main/config.json)) | MIT · MIT · **undisclosed** | About 30M (est. from 87.5 + 32.0 MB fp32 ONNX) | Official ONNX only; no Core ML port. Same `VisionEncoderDecoder` shape as the converted [manga-ocr](https://huggingface.co/masahiroid/manga-ocr-base-coreml) | [3,273★, 2026-08-23](https://github.com/breezedeus/Pix2Text) | **Use** for print, pending a data answer |
| [PP-FormulaNet_plus-S](https://huggingface.co/PaddlePaddle/PP-FormulaNet_plus-S) | Printed; PP-HGNetV2-B4 encoder. En-BLEU 88.71; 179 ms on a T4 ([docs](https://www.paddleocr.ai/latest/en/version3.x/module_usage/formula_recognition.html)) | Apache-2.0 · Apache-2.0 · internal set, undisclosed | 57M; 248–257 MB | Paddle only. Texo's PyTorch port shows it can leave Paddle | 90,901★, 2026-09-16 | Maybe (accuracy upgrade) |
| [granite-docling-258M](https://huggingface.co/ibm-granite/granite-docling-258M) | Document VLM with a "Convert formula to LaTeX." mode. Equation BLEU 0.893 on IBM's benchmark | Apache-2.0 · Apache-2.0 · synthetic SynthFormulaNet plus DoclingMatix | 257.5M; 515 MB bf16 | MLX and ONNX exist; no Core ML port | — | Maybe (optional download; handwriting not claimed) |
| [TrOCR small-stage1](https://github.com/microsoft/unilm/tree/master/trocr) | Text-line encoder-decoder pretrained on synthetic print | MIT repo · no HF licence field on small or stage1 · synthetic | 62M | Same template | 22,229★, 2026-09-21 | Use as an alternative fine-tune base |
| [BTTR](https://github.com/Green-Wood/BTTR), [CAN](https://github.com/LBH1024/CAN) | Handwritten-math code | MIT · no weights in repo; public checkpoints are CROHME-trained | Small | — | 129★ (archived) / 387★, 2022 | Maybe (code to retrain) |
| [pix2tex](https://github.com/lukas-blecher/LaTeX-OCR) | Printed; ViT-ResNet hybrid plus a resizer net. BLEU 0.88 | MIT · MIT (release assets) · no data licence | About 25M (est.) | No ONNX or Core ML; tracing is still a TODO | 16,588★, 2025-01-18 | **No** to ship; reference |
| CoMER, TAMER, ICAL, SAN, WAP, PosFormer, NAMER | Handwritten math, 55–65% CROHME | No licence / "BSD-2, academic only" / no repo · CROHME, HME100K | 6.4–8.2M | GGUF ports only, NC | 2022–2025 | **No** |
| [TexTeller 3](https://github.com/OleehyO/TexTeller) | Printed, handwritten and scanned | Apache-2.0 · Apache-2.0 · tainted, as above | 298M; 1.19 GB fp32 | int8/int4 ONNX. A 2024 Core ML trace used a fixed 100-token decoder with no KV cache ([post](https://web.navan.dev/posts/2024-10-19-vision-encoder-decoder-swift-onnx-coreml.html)) | 761★, 2025-08-22 | **No** |
| [UniMERNet](https://arxiv.org/html/2404.15254) | Printed and handwritten | Apache-2.0 · Apache-2.0 · includes CROHME and HME100K | 107–325M | ONNX (tiny) | 506★, 2025-09-28 | **No** |
| [Texo / FormulaNet](https://github.com/alephpi/Texo) | 20M parameters, about UniMERNet-T accuracy | AGPL-3.0 · AGPL-3.0 | 20M; 80 MB | ONNX | 907★, 2026-09-18 | **No** (copy the recipe only) |
| MixTeX, Sumen, Nougat, Texify/Surya, GOT-OCR2.0 | — | AGPL code; CROHME-containing set; CC BY-NC weights; GPL, CC BY-SA, NC-SA or revenue-capped OpenRAIL-M; NC data badge | 86M–716M | — | — | **No** |
| TrOCR math fine-tunes (fhswf, Azu, us4, krplt) | — | AFL-3.0 / none / none / CC BY-NC | 0.25–0.6B | — | — | **No** |

**Ranked shortlist for equations**

1. **Pix2Text MFR 1.5**, converted for print now and then fine-tuned for handwriting on clean synthetic data. Pix2Text ships ONNX only, and coremltools documents only PyTorch and TensorFlow sources, not ONNX ([docs](https://apple.github.io/coremltools/docs-guides/source/unified-conversion-api.html)). The model therefore has to be rebuilt in PyTorch from its `config.json`, with weights loaded from the ONNX graphs. Fine-tuning needs that step anyway. The research found no write-up of it; the fallback is ONNX Runtime with its Core ML execution provider.
2. **A Folio-trained model of about 20M parameters.** Follow Texo's recipe (an HGNetV2-B4 encoder plus a 2-layer decoder) or use the CoMER size, starting from the MIT BTTR or CAN code. Train only on licence-clean data. This is the fallback if Pix2Text's data proves tainted, and possibly the main handwriting model.
3. **PP-FormulaNet_plus-S** as an accuracy upgrade for print, if the PyTorch port works and its data question is answered.
4. **granite-docling-258M** as an optional download through Managed Background Assets, which require iOS 26+ ([App Store Connect](https://developer.apple.com/help/app-store-connect/manage-asset-packs/overview-of-apple-hosted-asset-packs)).

**Conversion recipe** (same for options 1 and 2):
- Ship a fixed-size encoder `.mlpackage` and a decoder with a stateful KV cache (`ct.StateType`, iOS 18+).
- Run greedy decoding in Swift.
- Palettise weights to 6–8 bits.
- Watch for fp16 attention overflow.

On a toy model the KV cache cut 100 iterations from about 4,246 ms to 238 ms on an M3 Max ([coremltools](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)). The expected iPhone cost for a 20–40M model is single-digit milliseconds for the encoder and 1–5 ms per token, so roughly **0.1–0.5 s for a 100-token formula**. That is an extrapolation from DistilBERT and WhisperKit figures, not a measurement.

## Math data: no human-handwritten set clears the licence gate

The well-known handwritten sets are all excluded:
- CROHME (every year): NC-SA or research-only.
- MathWriting: CC BY-NC-SA 4.0 for the data, even though its paper is CC BY ([repo](https://github.com/google-research/google-research/tree/master/mathwriting)).
- HME100K: no stated licence ([TAL](https://ai.100tal.com/dataset)).
- M²E: CC BY-NC 4.0.

The big Hugging Face aggregates (UniMER-1M, latex-formulas-80M, Fusion, linxy/LaTeX_OCR) put Apache or OpenRAIL labels over NC or unlicensed parts ([UniMER card](https://huggingface.co/datasets/wanderkid/UniMER_Dataset)). Nearly every printed corpus also takes its formulas from arXiv, and arXiv says it is "unable to grant others the right to distribute arXiv articles" ([arXiv bulk data](https://info.arxiv.org/help/bulk_data_s3.html)).

| Dataset | Content | Licence | Verdict |
|---|---|---|---|
| [Aida Calculus](https://www.kaggle.com/api/v1/datasets/view/aidapearson/ocr-data) (Pearson) | 100k **synthetic** photos of handwritten limits, with LaTeX, boxes and masks | [CDLA-Sharing-1.0](https://cdla.dev/sharing-1-0/); §3.5 puts no obligations on "Results" | **Maybe**: best handwritten option, needs a policy exception |
| [HASYv2](https://zenodo.org/records/259444) / [Detexify](https://github.com/kirel/detexify-data) | 168k 32×32 symbols in 369 classes / online strokes | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/); a trained model is plausibly a "Produced Work" needing only a notice | Maybe (glyph source; contributor terms unknown) |
| [im2latex-100k](https://zenodo.org/records/56198) / 230k | Printed arXiv formulas | CC0 from the re-packager | Maybe (arXiv provenance sign-off) |
| [IBEM v2](https://zenodo.org/records/4757865/latest) | 600 papers, about 166k expressions | CC BY 4.0 | Maybe (attribution plus arXiv caveat) |
| CROHME, MathWriting, HME100K, MLHME-38K, M²E | Real handwriting | NC-SA / NC / none | **No** |
| UniMER-1M, latex-formulas-80M, Fusion, linxy | Aggregates | Labels over NC parts | **No** |
| im2latex-170k; Kaggle xainano symbols; HumynLabs notes | — | "© Original Authors"; CROHME-derived; bars commercial reuse | **No** |
| Wikipedia, ProofWiki, OEIS formula text | Formula sources | CC BY-SA | Risky |
| Mathpix output | — | ToS bars using output for competing models ([terms](https://mathpix.com/terms)) | **No** |

**Training route.**
- **Printed:** extract formulas from arXiv papers whose own licence is CC0 or CC BY 4.0, filtered through OAI-PMH metadata, and keep an attribution manifest. Add a programmatic LaTeX grammar and the Apache-2.0 [DeepMind generator](https://github.com/google-deepmind/mathematics_dataset) output converted to LaTeX. Render with KaTeX (MIT) or MathJax (Apache-2.0) in OFL fonts; OFL does not reach rendered output ([OFL FAQ](https://openfontlicense.org/ofl-faq/)).
- **Handwritten:** reimplement MathWriting's *method*: take per-token boxes from the renderer and stitch in handwritten glyphs. Glyph sources, in order of preference:
  1. Glyphs collected in-house under a contributor agreement.
  2. HASYv2 or Detexify strokes.
  3. Aida, if the policy exception is granted.
- **Mix and augmentation:** follow TexTeller and hold real handwriting at about 5% of samples, with paper, ink and lighting augmentation. Its 298M model reached 88.0 ExpRate on CROHME14, and the paper also trained 15M, 22M and 35M variants ([TexTeller paper](https://arxiv.org/html/2508.09220v1)).
- **Compute:** a 20–40M model on a few million images is a job of a few single-GPU days (est.).
- **Testing:** an in-house real handwritten test set is unavoidable, because no public real set may tune shipped weights.

One design choice follows from Folio's code (an inference, not a research finding): restrict the model's token vocabulary to the LaTeX subset `LaTeXToOMML` accepts. Every decoded formula then validates by construction.

## Figures and style: PP-DocLayoutV3 finds regions; heuristics read styles

**PP-DocLayoutV3** has 25 classes, including `chart`, `image`, `display_formula`, `inline_formula`, `figure_title` and `formula_number`. It was trained with slides and with warp and perspective augmentation. On real-world captures its end-to-end score (with the PaddleOCR-VL-1.5 recogniser) is **92.05 against DocLayout-YOLO's 74.07** ([paper](https://arxiv.org/html/2606.23344)). Its training data is an undisclosed in-house set of 38k images, but the publisher licenses the weights as Apache-2.0. No layout model claims handwritten-notes training data. **"Diagram" is not a native class anywhere.** Docling's MIT **DocumentFigureClassifier v2.5** fills that gap: it splits picture crops into 26 types, including `flow_chart`, `bar_chart` and `photograph`, at 0.907 accuracy ([HF](https://huggingface.co/docling-project/DocumentFigureClassifier-v2.5)).

| Candidate | Code · weights · data | Size / Core ML | Verdict |
|---|---|---|---|
| [PP-DocLayoutV3](https://huggingface.co/PaddlePaddle/PP-DocLayoutV3) | Apache-2.0 · Apache-2.0 · in-house, undisclosed | 33M params. Two community Core ML ports that **conflict**: [fp32, 124.5 MB](https://huggingface.co/aoiandroid/PP-DocLayoutV3-safetensors-CoreML), whose author says "fp16 MIL cast diverges", and [fp16, 86.6 MB](https://huggingface.co/hugging-mac/pp-doclayout-v3-coreml). A `transformers` safetensors copy gives Folio its own PyTorch export path | **Use** (prototype first) |
| [DocumentFigureClassifier v2.5](https://huggingface.co/docling-project/DocumentFigureClassifier-v2.5) | MIT · MIT · FinePDFs subset (ODC-By) | EfficientNet-B0, 16 MB; safetensors available | **Use** (second stage) |
| [Docling heron](https://huggingface.co/docling-project/docling-layout-heron) / egret-m | MIT · Apache-2.0 · DocLayNet (CDLA-P) plus proprietary DocLayNet-v2 and WordScape | 42.9M / 19.5M. [Core ML port](https://huggingface.co/dawsonvosburg/docling-layout-heron-coreml): 81.8 MB fp16, 640 px, iOS 18+. Has `Picture` and `Formula` classes but **no chart class**; appears tuned to born-digital PDFs | Use (A/B alternative) |
| PP-DocLayoutV2 / PP-DocLayout-S | Apache-2.0 · Apache-2.0 | V2: 53M, with a 63 MB fp16 Core ML port at about 14 ms per page on an M5 Max ([HF](https://huggingface.co/rageyu/platen2-pdf-doclayout)). S: 4.8 MB, mAP 70.9, Paddle-only | Maybe |
| DocLayout-YOLO, YOLO-DocLayNet fine-tunes, Surya, MinerU, LayoutLMv3, Unstructured yolox | AGPL / conflicting / OpenRAIL-M or NC-SA / no weights licence | — | **No** |

Fine-tuning data that clears the bar:
- **DocLayNet** (CDLA-Permissive-1.0, 80,863 pages).
- **PubLayNet annotations** (CDLA-Permissive; the images follow PMC Open Access terms).
- **PlotQA** (CC BY 4.0) for charts.
- **IBEM** (CC BY 4.0, with the arXiv caveat) for formula boxes.

M6Doc (NC-ND), ChartQA (GPL-3.0) and SlideVQA (evaluation-only) are out.

**Style cues.** No maintained, permissive bold/italic/underline model or dataset exists. Tesseract's LSTM engine "does not perform font detection at all" ([tesseract.js #907](https://github.com/naptha/tesseract.js/issues/907)). Ship heuristics first, each judged against the line median rather than as an absolute:
- Bold: relative stroke width.
- Italic: shear of near-vertical strokes.
- Underline: a long horizontal run below the baseline.

If photos defeat the heuristics, train a tiny multi-label CNN on synthetic renders from OFL Google Fonts families. It would be under 1 MB (est.). A historical-print study found MobileNetV2 performed about as well as a human expert at word-level style ([BIR](https://hal-enc.archives-ouvertes.fr/hal-03355683v1)).

## Every model slots in after the classical region pass

Apple ships no shape, arrow or math recogniser. The useful built-ins are:
- **RecognizeDocumentsRequest** (iOS 26) for text ([WWDC25](https://developer.apple.com/videos/play/wwdc2025/272/)).
- **DetectContoursRequest** (iOS 18+) for vector paths ([docs](https://developer.apple.com/documentation/vision/detectcontoursrequest.md)).
- The WWDC26 PencilKit recognizer, whose docs describe PencilKit strokes as input, not photos ([docs](https://developer.apple.com/documentation/pencilkit/recognizing-handwriting-and-converting-to-text.md)).

Core AI (`.aimodel`, [WWDC26 325](https://developer.apple.com/videos/play/wwdc2026/325)) needs iOS 27+ according to third-party docs ([Ultralytics](https://docs.ultralytics.com/integrations/coreai)). For the iOS 26 target, ship coremltools 9.0 `.mlpackage` files and keep models `torch.export`-friendly so a later port stays cheap.

| Model | Input | Output | Plug-in point |
|---|---|---|---|
| PP-DocLayoutV3 | Whole perspective-corrected page, 800×800 fixed | `logits [1,300,25]`, `pred_boxes` (cxcywh), `order_logits`. Swift applies sigmoid, top-k and per-class thresholds | Upstream of both detectors. `display_formula` / `inline_formula` boxes go to the equation path and set `display:`. `image` boxes go to the classifier. Charts become `.figure` with `figure_title` as the caption |
| DocumentFigureClassifier | Each `image` crop | 26-class probabilities | `flow_chart` → the diagram path; charts and photos → `.figure` |
| RF-DETR keypoint (fine-tuned) | The `DetectedDiagram.frame` crop (or the whole page for whiteboards), 576×576 | `dets` (boxes), `labels`, `keypoints` (arrow head and tail) | Replaces `DiagramDetector`'s `findShapes` and the direction part of `findSegments`/`link`. `labelNodes`/`labelEdges` OCR assignment stays. Head → `Edge.to`, tail → `Edge.from` via the same nearest-node rule. Low keypoint confidence, or disagreement with the classical result, sets `Edge.flag` (keep / reverse / remove) |
| YOLOX fallback | Same crop, 640×640 letterboxed | Raw `[1, N, 5+C]` head; Swift decodes it, scores obj × class and runs per-class NMS | Same slot. Arrowhead and arrow-tail box centres become the endpoints |
| Create ML baseline | Same crop (Vision scales it) | `VNRecognizedObjectObservation` boxes and labels | Same slot; a benchmark only |
| Pix2Text MFR 1.5 | Image crop of a line that `EquationDetector.mathScore` passes (≥ 0.6), or a `display_formula` box, fitted to 384×384 | LaTeX token IDs (vocab 1,868), decoded greedily in Swift | Replaces `latex(fromLinear:)` when `LaTeXToOMML.convert` accepts the result. Otherwise the text converter's output stands, and `refine` (Foundation Models) stays optional afterwards |
| Folio-trained handwriting model | Grayscale crop in enumerated buckets, e.g. 64×256, 96×384, 128×512 | Tokens from a vocabulary limited to the `LaTeXToOMML` subset | Same gate; used for `handwritten` and `whiteboard` pages |
| granite-docling-258M (download) | Formula crop at 512 px plus a prompt | LaTeX text | Same gate; optional high-accuracy tier |
| Style heuristics / tiny CNN | Vision word boxes; 32×128 crops normalised to x-height | Bold / italic / underline scores, compared with the line median | Sets `FolioRun.bold/italic/underline` |

The current IR has two gaps:
- `Diagram.Edge` has no undirected form, so a detected `line` must become a flagged edge or the IR needs a `directed` field.
- DIDI's parallelograms and octagons, and BPMN data stores, need mapping onto the four shapes.

`EquationDetector` finds equations by scoring OCR text, so it will miss handwritten formulas that Vision misreads. No permissive model detects handwritten formula regions.

## Licence and legal flags

**SAP patents.** SAP SE holds US 10,956,727 B1 (active, anticipated expiry 2039-09-11). Its claim 1 covers ML localisation and classification of handwritten-diagram objects, structure recognition, handwriting recognition and generation of an editable model, without reciting a specific network ([Google Patents](https://patents.google.com/patent/US10956727B1/en)). SAP also holds US 11,663,761 B2 (expiry 2042-01-01), which covers DiagramNet-style edge prediction with keypoint arrow paths ([Google Patents](https://patents.google.com/patent/US11663761B2/en)). The ML diagram tier is the exposed part whichever detector Folio uses. This needs a freedom-to-operate opinion before commercial release.

**Ultralytics.** "All Ultralytics YOLO trained models fall under the AGPL-3.0 License by default", including fine-tuned and from-scratch models ([Ultralytics](https://www.ultralytics.com/license)). Never train Folio's models with Ultralytics code.

**Roboflow Universe badges.** The uploader picks the licence at publish time ([Roboflow docs](https://docs.roboflow.com/datasets/manage/make-a-project-public)). One 2,563-image "CC BY 4.0" project is CMP's unlicensed FC_B/FA data, identifiable by filenames such as `writer013_fc_019.png` ([project](https://universe.roboflow.com/webagent/flowchart-detection-6qzow)). A badge does not cure the upstream licence.

**NC and SA.** Creative Commons says NC covers every stage, from copying data during training to sharing the trained model. Its conservative SA reading puts a shared model under the same licence ([CC guidance](https://creativecommons.org/using-cc-licensed-works-for-ai-training/)). CC BY-SA 4.0 also bars downstream restrictions, which sits badly with App Store terms. The policy is: NC is No; SA is No for shipped weights unless counsel signs off.

**Needs the user's or counsel's sign-off before use:**

| Item | Question |
|---|---|
| Aida (CDLA-Sharing-1.0) | Do trained weights count as "Results" free of share-alike? |
| HASYv2 / Detexify (ODbL) | Is the model a "Produced Work"? What are the contributor terms for individual drawings? |
| im2latex-100k/230k (CC0), IBEM and DocBank | Re-packagers cannot waive arXiv authors' rights. Are isolated formulas thin enough to use? |
| hdFlowmind and Flowmind2digital (openrail) | Behavioural-use restrictions must flow to derivatives, and the card does not name which OpenRAIL variant applies |
| Pix2Text MFR 1.5 | Undisclosed training data, which could include CROHME or HME100K |
| PP-DocLayoutV3, PP-FormulaNet, Docling heron | Training data is in-house or proprietary under Apache-2.0 weights. The risk is provenance, not licence terms |
| Graphviz (EPL-2.0) | Its licence page is silent on generated layouts; low risk, but log it |
| PubLayNet images | PMC Open Access terms apply if images are ever redistributed |
| Using NC sets (FC_A, CROHME) as internal benchmarks | A policy decision for a company publisher |

## Open questions and next steps

1. **Measure on device.** No iPhone latency or memory figure exists for any recommended model. Profile RF-DETR, YOLOX, PP-DocLayoutV3 and the converted Pix2Text in Xcode's Core ML performance report. Check where `resample`, top-k and gather run, check fp16 parity (the PP-DocLayoutV3 ports conflict), and check arrowhead recall at 576 px on whole-whiteboard photos.
2. **Ask breezedeus (Pix2Text)** which datasets trained MFR 1.5, and whether CROHME, HME100K or Mathpix-labelled data were used. Also check the lineage of `pix2text-mfd-coreml` before relying on its MIT tag.
3. **Ask CMP Prague (Bresler, Průša)** for a CC BY 4.0 grant on FC_B, FC_Bscan and FA. These are the best arrow head/shaft annotations available.
4. **Ask the hdFlowmind authors (Xidian)** for CC BY 4.0, and **the Flowchart 3b authors (UPIIZ/IPN)** for any permissive licence.
5. **Validate RF-DETR keypoint export** on a fine-tuned multi-class checkpoint, and confirm that zero-keypoint and two-keypoint classes can mix.
6. **Prototype DIDI label derivation**: align the xdot prompt geometry to the ink to get node boxes and edge head/tail.
7. **Build the synthetic generators** (rough.js diagrams; KaTeX math with stitched glyphs) and start a consented in-house collection of glyphs and real test captures.
8. **Get counsel's view** on the SAP patents and the sign-off table above.
9. **Decide the IR changes**: undirected edges and extra shape classes.
10. **Ask Pearson** how the Aida handwriting was synthesised, to confirm it is free of NC sources.

## Conclusion

The research reverses the usual build-or-borrow framing. Folio can borrow almost any architecture it wants, but it cannot borrow knowledge of human handwriting in either domain: every well-annotated human-drawn diagram set and every human-written math set is NC, research-only or unlicensed. Folio's durable tier-3 assets are therefore its **synthetic generators and its consented in-house captures**, not any particular checkpoint. Three emails, to CMP, Xidian and Pix2Text's author, could change that picture more cheaply than any amount of model work.

The classical baselines do not become obsolete. They become the **validation and flagging layer**: the ML detector proposes shapes and arrow keypoints, and disagreements with the contour pass become `Edge.flag` prompts. The ML recogniser proposes LaTeX, and `LaTeXToOMML` decides whether it ships. Constraining the model's outputs to the IR's four shapes and to the LaTeX subset `LaTeXToOMML` accepts makes that hand-off reliable by design.
