# CUGR incremental non-determinism — SUPERSEDED

**This document's conclusion (multithreaded STA/resizer FP-order) is REFUTED as of
2026-07-08.** See `cugr_incremental_nondeterminism.md` for the corrected
characterization.

Why refuted: under matched conditions the process is genuinely single-threaded at
NUM_CORES=1 (Threads=1 for the whole run), and the resizer/STA/est repair path is
provably deterministic (FastRoute gives byte-identical results ×6 on the same
path). The non-determinism is a single-threaded, address/content-dependent
computation **inside CUGR's incremental reroute**; the resizer only amplifies it
via tie-sensitive TNS moves. The old evidence below measured route hashes
(deterministic) rather than repair QoR (non-deterministic), which is why it
mislocated the cause.

---
(Original refuted notes removed; see git history if needed.)
