# WaitIO tutorials, talks, and papers

[Package README](../README.md) · [Japanese reading guide](../inJapanese/WAITIO_RESOURCES.md)

Tutorials reviewed on 2026-10-30; paper references updated on 2026-11-04.
This list covers the underlying **h3-Open-SYS/WaitIO**
project. Its C/Fortran examples, transport implementations, and related couplers
provide background for using WaitIO.jl; they do not document this package's Julia API.
Links point to the original organizers, authors' slides, or publishers.

## Suggested reading order

1. Read the English ASE talk for the architecture and parallel-block model.
2. Work through the 2024 WaitIO/MP tutorial for communication and paired-job setup.
3. Read the 2026 Miyabi material for an example involving G/C and QC–HPC workloads.
4. Use the RDMA paper and the research overview to distinguish upstream transport
   development from features validated in a particular Julia deployment.

## Tutorials and hands-on material

### WaitIO/MP workshop — University of Tokyo, 2024-10-30

[Workshop page](https://www.cc.u-tokyo.ac.jp/events/lectures/236/) ·
[Slides, 129 pages, Japanese](https://www.cc.u-tokyo.ac.jp/events/lectures/236/20241030-2.pdf)

Shinji Sumimoto and Takashi Arakawa introduce coupled applications on Wisteria.
The slides progress from file-mediated coupling to WaitIO communication, introduce
the WaitIO-MPI conversion interface, and provide sample programs and batch scripts.
They also explain the role of the higher-level h3-Open-UTIL/MP coupler.

Read this for PB IDs, master-host discovery, launching separate jobs, and integrating
existing programs. The old queue names, project IDs, paths, and module choices are
examples from that course; use your site's current settings.

### Introductory WaitIO/MP workshop — University of Tokyo, 2022-10-14

[Workshop, materials, and recording links (Japanese)](https://www.cc.u-tokyo.ac.jp/events/lectures/191/index.php)

This earlier course introduces heterogeneous coupling on Odyssey and Aquarius,
including replacing file exchange with MPI-like WaitIO calls and connecting
Fortran/C applications with Python through MP. The event page lists both lecture
and hands-on recordings. It is useful when a recorded introduction is preferable
to reading slides. Recording contents were not independently reviewed here.

### CUDA-Q and Miyabi workshop — University of Tokyo, 2026-07-21

[Workshop and recording links](https://www.cc.u-tokyo.ac.jp/events/lectures/277/) ·
[WaitIO introduction slides, 82 pages, Japanese](https://www.cc.u-tokyo.ac.jp/events/lectures/277/20260721-5.pdf)

The WaitIO section is presented by Shinji Sumimoto. The material explains parallel
blocks, basic send/receive operations, and the WaitIO-MPI conversion library in the
context of heterogeneous application coupling. The wider workshop uses Miyabi
for CUDA-Q and QC–HPC exercises. The event page also provides separate hybrid-environment
materials and recording links; recordings were not independently reviewed here.

Use this material to understand WaitIO deployment on Miyabi. For the Julia API
and site aliases, follow this package's [README](../README.md).

### NCTS winter school — National Taiwan University, 2025-02-17–18

[Course description and timetable (English)](https://ncts.ntu.edu.tw/events_3_detail.php?nid=358)

Kengo Nakajima, Takashi Arakawa, Shinji Sumimoto, and Hisashi Yashiro teach the
integration of simulation, data analysis, and machine learning on a heterogeneous
supercomputer. The published outline includes WaitIO programming and Wisteria
hands-on work, followed by coupling with UtilMP. Use it as an English description
of a complete learning path. The linked page was reviewed as a syllabus, not as
a downloadable exercise collection.

## Architecture and research

### WaitIO-Socket — PDCAT 2022, published 2023

Shinji Sumimoto et al.,
[A System-Wide Communication to Couple Multiple MPI Programs for Heterogeneous Computing](https://doi.org/10.1007/978-3-031-29927-8_25),
LNCS 13798, pp. 314–327, 2023.

The publisher's abstract introduces communication between independent MPI programs
with different MPI libraries, processors, and interconnects, evaluated on Wisteria's
Odyssey and Aquarius. Read this for the original motivation and architecture.
Its application results concern upstream WaitIO and the UTIL/MP coupler, not WaitIO.jl.

### WaitIO-Hybrid — PDCAT 2024, published 2025

Shinji Sumimoto et al.,
[WaitIO-Hybrid: Communication for Coupling MPI Programs Among Heterogeneous Systems](https://doi.org/10.1007/978-981-96-4207-6_13),
LNCS 15502, pp. 140–153, 2025.

The publisher's abstract describes using sockets and shared files for heterogeneous
application coupling, including Wisteria and Flow evaluations. This provides
background on transport choices; the Julia tests do not benchmark WaitIO-Hybrid.

### WaitIO architecture — 45th ASE Seminar, 2023-11-29

[Program and recording link](https://www.cc.u-tokyo.ac.jp/en/events/ase/45/45.php) ·
[Shinji Sumimoto's slides, 20 pages, English](https://www.cc.u-tokyo.ac.jp/en/events/ase/45/Sumimoto.pdf)

The talk describes coupling multiple MPI programs across heterogeneous systems.
It introduces the communication model and the Socket, File, and Hybrid approaches.
Read it to understand why applications can keep their local MPI environments while
exchanging data through WaitIO. The program links a recording of the seminar;
the slides, rather than the recording, were reviewed for this list.

### RDMA communication — HPC Asia workshops, 2025

Shinji Sumimoto et al.,
[Accelerating Heterogeneous Coupling Computing with WaitIO Using RDMA](https://doi.org/10.1145/3703001.3724382).

The publisher's abstract describes WaitIO-Verbs and WaitIO-Tofu, which use
user-level RDMA, and motivates them against the existing Socket/File approaches.
It reports communication and application evaluations across heterogeneous clusters.
This entry is based on the abstract; no numerical performance claims are reproduced.
The paper concerns upstream native transports. WaitIO.jl's Miyabi socket tests
do not validate these RDMA paths or direct GPU communication.

### WaitIO and communication between centers — research overview

[University of Tokyo research overview (English)](https://www.cc.u-tokyo.ac.jp/en/outline/researches.php)

The WaitIO section explains interoperability between MPI programs using different
processors, MPI libraries, and networks. The separate WaitIO-Router section
describes work toward QC–HPC coupling across computing centers, including routing,
multiple socket streams, and encrypted transfer. It points to CLUSTER 2024 and
SCAsia 2025 posters.

Use this overview to distinguish heterogeneous application coupling from deployment
across administrative and network boundaries. WaitIO.jl's recorded G/C and
Odyssey/Aquarius runs are not evidence of communication between separate centers.

## Applying these materials to WaitIO.jl

WaitIO supplies communication between parallel blocks. The higher-level UTIL/MP
coupler adds application coupling facilities; it is a separate layer. WaitIO.jl
provides Julia bindings and Julia-specific request/buffer handling on top of the
native WaitIO installation.

Follow the [English README](../README.md) for Julia configuration and examples.
Use the upstream tutorials for the underlying communication model and site job
procedures. See the [README](../README.md#tested-environments-and-limitations)
for supported installations and known limitations.
