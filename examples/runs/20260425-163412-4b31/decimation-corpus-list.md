# Decimation Corpus — Paper List for Pre-Forge Augmentation

**Run:** `20260425-163412-4b31`
**Decision:** ADD CORPUS — aggressive medical/dental bridge posture
**Target landing path:** `corpora2/extracted/Publications/Decimation_CG_Literature/{foundational,modern_neural,dental_medical_bridges}/`
**Subtopic label:** `decimation` (path-prefix mapper, applied at forge-prep time)

## Counts and cost projection

| Bucket | Target count | Realistic landed (after paywall losses) | Est. raw tokens | Est. clean tokens (13% audit retention) | Synth cost impact |
|---|---|---|---|---|---|
| foundational | 40 | ~38 | ~600K | ~80K | ~$0.30 |
| modern_neural | 35 | ~30 | ~500K | ~65K | ~$0.24 |
| dental_medical_bridges | 30 | ~22 | ~350K | ~46K | ~$0.17 |
| **Total** | **105** | **~90** | **~1.45M** | **~190K** | **~$0.71** |

Total projected synth cost increase against the $358 baseline: **~0.2%**. Negligible against $500 cap with $134 headroom.

## How to read this list

- **Confidence:** `H` = high (canonical work, free PDFs known), `M` = medium (probably free, may need search), `L` = low (paywall risk significant)
- **Source hint:** domain or repository where the PDF most likely lives. Step 2 (bulk download) will validate URLs and report failures; ~10% loss expected, hence the buffer in target counts.
- Estimated tokens are rough: ~10-15K per conference paper, ~25-40K per journal article, ~80-120K per dissertation/book chapter.

---

## 1. Foundational decimation literature

| # | Title | Year | Authors | Source hint | Conf. | Notes |
|---|---|---|---|---|---|---|
| F-1 | Decimation of Triangle Meshes | 1992 | Schroeder, Zarge, Lorensen | kitware.com / acm.org | H | Original decimation paper; Kitware hosts |
| F-2 | Mesh Optimization | 1993 | Hoppe, DeRose, Duchamp et al. | hoppe.com/proj/meshopt | H | Free on Hoppe's site |
| F-3 | Multi-resolution 3D approximations for rendering complex scenes | 1993 | Rossignac, Borrel | research IBM | M | Vertex clustering classic |
| F-4 | A Data Reduction Scheme for Triangulated Surfaces | 1994 | Hamann | author homepage / cigna.org | M | |
| F-5 | Multiresolution Analysis of Arbitrary Meshes | 1995 | Eck, DeRose, Duchamp, Hoppe et al. | hoppe.com | H | |
| F-6 | Progressive Meshes | 1996 | Hoppe | hoppe.com/proj/pm | H | The canonical PM paper |
| F-7 | Simplification Envelopes | 1996 | Cohen, Varshney, Manocha et al. | UNC site / acm.org | H | UNC GAMMA group |
| F-8 | Mesh reduction with error control | 1996 | Klein, Liebich, Strasser | research site | M | |
| F-9 | View-Dependent Refinement of Progressive Meshes | 1997 | Hoppe | hoppe.com | H | |
| F-10 | Surface Simplification Using Quadric Error Metrics | 1997 | Garland, Heckbert | mgarland.org | H | The QEM paper |
| F-11 | Survey of Polygonal Surface Simplification Algorithms | 1997 | Heckbert, Garland | cmu.edu | H | The survey |
| F-12 | Multiresolution Modeling: Survey and Future Opportunities | 1997 | Garland | cmu.edu | H | |
| F-13 | Survey of Polygonal Mesh Simplification | 1997 | Luebke | cs.virginia.edu | H | |
| F-14 | Smooth View-Dependent Level-of-Detail Control | 1998 | Hoppe | hoppe.com | H | |
| F-15 | Efficient Implementation of Progressive Meshes | 1998 | Hoppe | hoppe.com | H | |
| F-16 | Fast and Memory Efficient Polygonal Simplification | 1998 | Lindstrom, Turk | LLNL / gatech.edu | H | |
| F-17 | Appearance-Preserving Simplification | 1998 | Cohen, Olano, Manocha | UNC | H | |
| F-18 | Metro: Measuring Error on Simplified Surfaces | 1998 | Cignoni, Rocchini, Scopigno | vcg.isti.cnr.it | H | Tool used to evaluate decimation |
| F-19 | Quadric-Based Polygonal Surface Simplification (PhD diss.) | 1999 | Garland | mgarland.org | H | The full theory |
| F-20 | Hierarchical Face Clustering on Polygonal Surfaces | 1999 | Garland, Willmott, Heckbert | mgarland.org | H | |
| F-21 | New Quadric Metric for Simplifying Meshes with Appearance Attributes | 1999 | Hoppe | hoppe.com | H | |
| F-22 | Evaluation of Memoryless Simplification | 1999 | Lindstrom, Turk | LLNL | H | |
| F-23 | Image-Driven Simplification | 2000 | Lindstrom, Turk | LLNL | H | |
| F-24 | Out-of-Core Simplification of Large Polygonal Models | 2000 | Lindstrom | LLNL | H | |
| F-25 | Efficient Simplification of Point-Sampled Surfaces | 2002 | Pauly, Gross, Kobbelt | ETH/RWTH author sites | H | Point-cloud bridge |
| F-26 | Geometry Images | 2002 | Gu, Gortler, Hoppe | hoppe.com | H | Related decimation/parameterization |
| F-27 | Mesh Saliency | 2005 | Lee, Varshney, Jacobs | umd.edu | H | Saliency-driven decimation |
| F-28 | Quadric-Based Simplification in Any Dimension | 2005 | Garland, Zhou | mgarland.org | H | |
| F-29 | Polygonal Mesh Simplification with Face Color and Boundary Edge Preservation | 2007 | Garland, Hu | mgarland.org / acm | M | |
| F-30 | View-dependent simplification of arbitrary polygonal environments | 1997 | Luebke, Erikson | cs.virginia.edu | M | |
| F-31 | Multiresolution decimation based on global error | 1996 | Ciampalini, Cignoni, Montani, Scopigno | vcg.isti.cnr.it | M | |
| F-32 | Real-time Continuous Level of Detail Rendering of Height Fields | 1996 | Lindstrom et al. | gatech.edu | M | Terrain decimation classic |
| F-33 | Decimating samples for mesh simplification | 2003 | Boubekeur, Schlick | author site | L | |
| F-34 | A general framework for mesh decimation | 1998 | Kobbelt, Campagna, Seidel | RWTH | M | |
| F-35 | Bounded distortion polygonal mesh simplification | 1999 | Cheney | research site | M | |
| F-36 | Stream Decimation: vertex-based progressive meshes | 2002 | Pajarola, Rossignac | author sites | M | |
| F-37 | Permission Grids: Practical, Error-Bounded Simplification | 2002 | Zelinka, Garland | mgarland.org | H | |
| F-38 | Adaptive Real-Time Level-of-detail-based Rendering for Polygonal Models | 1997 | Xia, Varshney | umd.edu | M | |
| F-39 | Mesh Decimation Using VTK (book chapter / tech report) | 2003 | Schroeder, Martin, Lorensen | kitware.com (VTK book) | H | VTK reference |
| F-40 | Level of Detail for 3D Graphics (chapter excerpts on decimation) | 2002 | Luebke, Watson, Cohen et al. | book — partial PDFs floating | L | Risk: paywall on full book |

---

## 2. Modern neural / learning-based mesh simplification

| # | Title | Year | Authors | Source hint | Conf. | Notes |
|---|---|---|---|---|---|---|
| N-1 | PointNet: Deep Learning on Point Sets | 2017 | Qi et al. | arXiv:1612.00593 | H | Foundational, point-cloud bridge |
| N-2 | PointNet++ | 2017 | Qi et al. | arXiv:1706.02413 | H | |
| N-3 | MeshCNN: A Network with an Edge | 2019 | Hanocka et al. | arXiv:1809.05910 | H | Edge-based mesh learning, includes pooling/decimation |
| N-4 | MeshNet: Mesh Neural Network for 3D Shape Representation | 2019 | Feng et al. | arXiv:1811.11424 | H | |
| N-5 | Point2Mesh: A Self-Prior for Deformable Meshes | 2020 | Hanocka et al. | arXiv:2005.11084 | H | |
| N-6 | Learning Mesh-Based Simulation with Graph Networks | 2020 | Pfaff, Fortunato et al. (DeepMind) | arXiv:2010.03409 | H | |
| N-7 | Neural Mesh Simplification | 2022 | Potamias, Ploumpis, Zafeiriou | arXiv:2204.14068 | H | The directly-named paper |
| N-8 | Diffusion is All You Need for Learning on Surfaces | 2022 | Sharp, Crane | arXiv:2201.07069 | H | |
| N-9 | MeshGPT: Generating Triangle Meshes with Decoder-Only Transformers | 2023 | Siddiqui et al. | arXiv:2311.15475 | H | |
| N-10 | PointConv: Deep Convolutional Networks on 3D Point Clouds | 2018 | Wu et al. | arXiv:1811.07246 | H | |
| N-11 | Dynamic Graph CNN for Learning on Point Clouds | 2019 | Wang et al. | arXiv:1801.07829 | H | DGCNN — relevant to mesh learning |
| N-12 | Geometric Deep Learning on Graphs and Manifolds (survey) | 2017 | Bronstein et al. | arXiv:1611.08097 | H | |
| N-13 | A Survey on Deep Geometry Learning | 2020 | Xiao et al. | arXiv:2002.07995 | M | |
| N-14 | Deep Learning Advances on Different 3D Data Representations: A Survey | 2018 | Ahmed et al. | arXiv:1808.01462 | M | |
| N-15 | Neural Subdivision | 2020 | Liu, Kim, Chaudhuri et al. | arXiv:2005.01819 | H | Inverse of decimation, related |
| N-16 | Self-supervised Geometric Perception | 2021 | various | arXiv search | M | |
| N-17 | Differentiable Surface Splatting for Point-based Rendering | 2019 | Yifan et al. | arXiv | M | |
| N-18 | Pixel2Mesh: Generating 3D Mesh Models | 2018 | Wang et al. | arXiv:1804.01654 | H | |
| N-19 | AtlasNet: A Papier-Mâché Approach to Learning 3D Surface Generation | 2018 | Groueix et al. | arXiv:1802.05384 | H | |
| N-20 | Convolutional Neural Networks on Surfaces via Seamless Toric Covers | 2017 | Maron et al. | arXiv | M | |
| N-21 | Subdivision-based mesh convolution networks | 2021 | Hu et al. | arXiv:2106.02285 | M | |
| N-22 | Neural QEM (mesh decimation with learned error metrics) | 2023 | varies | arXiv search | L | Search-dependent |
| N-23 | Learning to Simplify Meshes via GNN | 2022-2023 | varies | arXiv search | L | Search-dependent |
| N-24 | DiffusionNet: Discretization-Agnostic Learning on Surfaces | 2022 | Sharp et al. | arXiv:2012.00888 | H | |
| N-25 | Mesh Convolutional Neural Networks for Wing Pressure Prediction | 2021 | Bonnet et al. | arXiv | M | Application of mesh NNs |
| N-26 | Learning a Probabilistic Latent Space of Object Shapes | 2016 | Wu et al. (3DGAN) | arXiv:1610.07584 | M | |
| N-27 | Occupancy Networks: Learning 3D Reconstruction in Function Space | 2019 | Mescheder et al. | arXiv:1812.03828 | H | |
| N-28 | DeepSDF: Learning Continuous Signed Distance Functions | 2019 | Park et al. | arXiv:1901.05103 | H | |
| N-29 | NeRF: Representing Scenes as Neural Radiance Fields | 2020 | Mildenhall et al. | arXiv:2003.08934 | H | Tangentially related |
| N-30 | Neural Geometric Level of Detail | 2021 | Takikawa et al. | arXiv:2101.10994 | H | LOD with NN — directly relevant |
| N-31 | Adaptive Coarse-to-Fine Mesh Simplification | 2023 | varies | arXiv search | L | |
| N-32 | Learning Local Mesh Operators for 3D Reconstruction | 2022 | varies | arXiv search | L | |
| N-33 | Field-Aligned Mesh Joinery (instant mesh / quad-remeshing context) | 2015 | Jakob et al. | author homepage | H | |
| N-34 | Instant Field-Aligned Meshes | 2015 | Jakob, Tarini, Panozzo, Sorkine-Hornung | author site | H | |
| N-35 | Mesh Simplification via Renormalization Group | 2023 | varies | arXiv search | L | |

---

## 3. Dental / medical bridges (aggressive posture)

| # | Title | Year | Authors | Source hint | Conf. | Notes |
|---|---|---|---|---|---|---|
| B-1 | Marching Cubes: A High Resolution 3D Surface Construction Algorithm | 1987 | Lorensen, Cline | acm / kitware | H | Origin of medical surface meshes |
| B-2 | A Fully Automatic AI System for Tooth and Alveolar Bone Segmentation from CBCT Images | 2022 | Cui et al. | Nature Communications open access | H | Discusses mesh preprocessing |
| B-3 | MeshSegNet: Deep Multi-Scale Mesh Feature Learning for End-to-End Tooth Labeling | 2020 | Lian, Wang et al. | arXiv:2008.05223 | H | May overlap with existing corpus |
| B-4 | TSegNet: An efficient and accurate tooth segmentation network | 2021 | Cui et al. | Medical Image Analysis | M | |
| B-5 | Automatic 3D Tooth Segmentation using Convolutional Neural Networks | 2019 | Xu et al. | arXiv | M | |
| B-6 | Mesh Decimation Strategies for Intraoral Scan Processing | 2021 | varies | journal search | L | Search-dependent |
| B-7 | Surface Mesh Simplification for Surgical Planning | 2018 | varies | medical imaging journals | M | |
| B-8 | FreeSurfer (overview paper) | 2012 | Fischl | freesurfer.net | H | Cortical surface processing — uses mesh decimation |
| B-9 | Cortical Surface-Based Analysis I: Segmentation and Surface Reconstruction | 1999 | Dale, Fischl, Sereno | nih.gov free | H | FreeSurfer foundation, includes decimation |
| B-10 | Cortical Surface-Based Analysis II: Inflation, Flattening, and a Surface-Based Coordinate System | 1999 | Fischl, Sereno, Dale | nih.gov free | H | |
| B-11 | A High-Resolution Computational Atlas of the Human Hippocampus | 2015 | Iglesias et al. | NeuroImage open access | M | Mesh preprocessing for organ atlases |
| B-12 | Statistical Shape Models for 3D Medical Image Segmentation | 2009 | Heimann, Meinzer | Medical Image Analysis review | M | Mesh-based shape models |
| B-13 | VTK: An Open-Source Visualization Toolkit | 2006 | Schroeder, Martin, Lorensen | kitware.com | H | Decimation reference for medical |
| B-14 | Open3D: A Modern Library for 3D Data Processing | 2018 | Zhou, Park, Koltun | arXiv:1801.09847 | H | Decimation algorithms used in medical |
| B-15 | Adaptive Mesh Refinement for Medical Image Analysis | 2017 | varies | journal search | M | |
| B-16 | Cardiac Mesh Generation and Simplification for Electrophysiology Modeling | 2019 | varies | Cardiac Atlas Project / open journals | M | |
| B-17 | Surface Reconstruction from Unorganized Points | 1992 | Hoppe et al. | hoppe.com | H | Foundational, used in medical pipelines |
| B-18 | Mesh-based reconstruction and simplification of human anatomy | 2016 | varies | medical imaging journals | L | |
| B-19 | Decimation-Aware Tooth Mesh Segmentation | 2022 | varies | search | L | If exists, valuable bridge |
| B-20 | Preprocessing Pipelines for Intraoral 3D Scan AI | 2022 | varies | search | L | |
| B-21 | Polygonal Mesh Reduction for Real-Time Surgical Simulation | 2014 | varies | IEEE TVCG / medical imaging | L | |
| B-22 | High-Quality 3D Mesh Reconstruction of Human Anatomy from Medical Images | 2015 | varies | journal | L | |
| B-23 | Mesh-Based Crown Generation: Pipeline Considerations | (existing corpus likely covers) | n/a | already in corpus | — | Skip if duplicate |
| B-24 | Computer-Aided Design and Manufacturing of Dental Restorations: State of the Art | 2018 | various | Journal of Dentistry / open archives | M | |
| B-25 | A Review of 3D Reconstruction Techniques for Dentistry | 2021 | various | Journal of Dentistry | M | |
| B-26 | Geometry Processing for Anatomical Modeling | 2014 | various | book chapter / tutorial | L | |
| B-27 | Decimation in CAD/CAM Dental Workflows | 2019 | varies | trade journal / open access | L | |
| B-28 | Mesh Quality Metrics for Medical Surface Models | 2010 | Knupp et al. | Sandia / NIH | M | |
| B-29 | Surface Simplification with Feature Preservation for Anatomical Models | 2008 | varies | medical imaging | L | |
| B-30 | Subdivision Surfaces in Medical Imaging Applications | 2013 | varies | journal | L | |

---

## Search-augmentation strategy (for low-confidence entries)

For B-6, B-7, B-15, B-16, B-18-22, B-26-30 (and N-22, N-23, N-31, N-32, N-35) — these are search-dependent. Step 2 download script will attempt the named title as a Google Scholar query, take the first 1-2 results, validate as PDF, and accept. If no free PDF surfaces in 30 seconds, skip and log. Buffer of 15 papers (105 → 90 landed) accounts for this.

If aggressive bridges count drops below 18, I'll surface that during step 3 inventory and either:
- accept the lower count (still meets "aggressive" intent)
- or pull from a backup list of arXiv mesh-medical preprints (5-10 candidates kept in reserve)

## Notable gaps (transparent about what I'm not pulling)

- **SIGGRAPH proceedings full archive** — ACM paywall blocks bulk download. We get the canonical papers via author homepages; we miss 2-3 obscure decimation papers per year for 30 years. Not worth the friction.
- **IEEE TVCG / Computer Graphics and Applications** — same paywall problem. The journal-level work is partly covered by author pages.
- **Foreign-language papers** — not pulled. Russian, Chinese, German graphics community has independent decimation work; outside scope for an English-trained SLM.

## Approval and execution

Three actions to take on this list:

1. **Eyeball the list.** Mark anything obviously wrong, missing, or that you want removed.
2. **Specify any must-have papers I missed** — your domain visibility is higher than mine on the dental bridges.
3. **Approve to proceed to download.**

Once approved, step 2 generates a URL manifest, runs the download with content-type validation, drops PDFs into the three sub-folders, logs failures. Step 3 reports the inventory. Then patches start.
