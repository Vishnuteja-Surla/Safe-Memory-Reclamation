# Research Mini-Project

The research mini-project is worth **16%** of the final grade and is done in
groups of **3**. The project should involve implementing a concurrent algorithm
or data structure that is **not discussed in class** but is related to the
course objectives. The implementation language is flexible — it need not be
OCaml 5.

See [`project_ideas.md`](project_ideas.md) for the list of 27 suggested project
topics, and [`report-template/`](report-template/) for the LaTeX template you
must use for the written report.

## Use of LLMs

You are expected to use LLMs (e.g., GitHub Copilot, ChatGPT, Claude) as part of
your workflow. We strongly recommend signing up for [GitHub Copilot for
Education](https://docs.github.com/en/copilot/managing-copilot/managing-copilot-as-an-individual-subscriber/managing-your-copilot-subscription/getting-free-access-to-copilot-as-a-student-teacher-or-maintainer),
which is free for students.

**However:** while an LLM may generate code, **you are responsible for every
line it produces.** You must review and understand all LLM-generated code
before submitting it. During the Q&A after the presentation, an answer of
*"the LLM generated it, I don't know what it does"* will receive the lowest
marks possible.

The report must include a dedicated **Reflection on the use of LLMs** section
(see the template): which models/tools you used, what worked well, what
didn't, what surprised you, and what was difficult. This reflection is graded
as part of the report.

## Deliverables

Every project must produce three deliverables:

1. **Implementation** — working code for a concurrency problem not covered in
   lectures, with tests and/or evaluation demonstrating correctness and
   performance.
2. **Written report** — 5–10 pages, written with the provided LaTeX
   template ([`report-template/`](report-template/)). The report should cover:
   goals of the project, tasks undertaken, evaluation, reflection on the use
   of LLMs, and conclusions. The report **must** list the contributions of
   each group member in terms of percentages.
3. **Presentation** — a **recorded video submission**, exactly **10 minutes**
   long, with **one group member** presenting on behalf of the group. Q&A will
   happen separately (in person or over Slack/video call) with the whole
   group — every member must be able to answer questions about any part of
   the work. See [Recording & hosting the video](#recording--hosting-the-video)
   below for suggested tools.

Code, report, and video (or a link to the video) must be submitted as a single
GitHub repository. The repository **must contain the LaTeX sources** of the
report (`.tex`, `.bib`, any figures) alongside the compiled `report.pdf` — not
just the PDF. Add the link to your GitHub repository in the "GitHub repo"
column of the project sign-up sheet.

## Recording & hosting the video

**Recording.** Any tool that captures slides + narration is fine. Suggestions:

- [OBS Studio](https://obsproject.com/) — free, cross-platform, records
  screen + webcam overlay. Good default.
- **Keynote** or **PowerPoint** built-in "record slideshow" — simplest if
  you only need slides + voice.
- **Zoom** — start a meeting with only yourself, enable "record to this
  computer", and share your screen.

**Hosting.** Do **not** commit the video file to your GitHub repo — a
10-minute 1080p video can be several hundred MB and will bloat the
repository. Instead:

- Upload to **YouTube** as an **Unlisted** video (free, no size or length
  limits, easy to share).
- Or upload to **Google Drive** on your `@smail.iitm.ac.in` account and
  share the link with "anyone with the link can view".

Put the video link prominently in your repository's top-level `README.md`.

## Grading Rubric (out of 16 marks)

| Component | Marks | What we look for |
|---|---|---|
| Challenge of the problem undertaken | 3 | Ambition, novelty, relevance to course topics. Each project in `project_ideas.md` has a difficulty rating (★ to ★★★★★). **Higher-difficulty projects receive higher marks in this component even if completion is partial.** |
| Progress made towards the challenge | 5 | Working implementation, depth of evaluation, evidence of effort |
| Written report | 5 | Clarity, technical depth, proper evaluation, LLM reflection, contribution breakdown |
| Presentation | 3 | Clear explanation, good use of the 10 minutes, Q&A over Slack |

## Important Dates

| Task | Date |
|---|---|
| Project topic approval | 30/03/2026 |
| Report, code & video submission | 29/04/2026 |

Fill in your group members and chosen project topic in the
[sign-up sheet](https://docs.google.com/spreadsheets/d/1kINa3ipNcyxAqh1wXC9_65xeZg25QFDirSUEqUU3IyA/edit?gid=0#gid=0)
by the topic approval deadline.

## Proposing your own topic

You are free to propose your own topic (subject to instructor approval). If
you are presenting a new project topic, make a PR against `project_ideas.md`
adding your proposal in the same format as the existing entries.


## Project 22: Memory Reclamation — Hazard Pointers and Epoch-Based Reclamation

**Difficulty: ★★★★☆** — Hazard pointer scanning and epoch tracking require careful lifetime reasoning; demonstrating and preventing ABA is subtle.

### Background

Lock-free data structures that unlink nodes (e.g., the Harris list from
Lecture 07, the Michael-Scott queue from Lecture 08) face a fundamental problem:
when can an unlinked node be safely freed? A concurrent reader may still hold a
reference to it. In languages without GC this is the infamous **ABA problem**
(AoMPP §10.6); in OCaml 5 the GC handles physical memory, but **logical
reclamation** — knowing when a node can be reused or its slot recycled — is
still relevant for bounded pools, caches, and epoch-indexed structures.
**Hazard pointers** (Michael, 2004) let each thread publish the addresses it is
currently accessing; reclaimers scan all hazard pointers before freeing.
**Epoch-based reclamation (EBR)** partitions time into epochs; nodes retired in
epoch `e` are freed once all threads have observed epoch `e + 2`. This project
implements both schemes and applies them to a lock-free data structure.

### Tasks

1. Implement a **hazard pointer library** in OCaml 5: each domain maintains a
   small fixed set of `Atomic` hazard pointer slots. Provide `protect` (publish
   a pointer), `release` (clear a slot), and `retire` (add a node to a
   per-domain retired list; when the list exceeds a threshold, scan all hazard
   pointers and reclaim safe nodes).
2. Implement an **epoch-based reclamation (EBR) library** in OCaml 5: maintain
   a global `Atomic` epoch counter. Each domain has a local epoch that it
   updates on entry to a critical section. Retired nodes are placed in
   epoch-tagged limbo lists and freed when all domains have advanced past that
   epoch.
3. Apply both reclamation schemes to a **lock-free pool** (fixed-size free
   list): nodes are allocated from the pool and returned to it after use.
   Without reclamation, a concurrent pop/push sequence can suffer ABA — the
   pool reuses a node that another thread still references. Demonstrate the ABA
   bug with a test, then show that both HP and EBR prevent it.
4. Integrate one scheme with the **Michael-Scott queue** from Lecture 08 to
   manage node recycling (instead of relying on GC allocation for every
   enqueue).
5. Verify correctness with **QCheck-Lin** and **dscheck**, including stress
   tests designed to trigger ABA (rapid push-pop-push cycles on a small pool).
6. Run **TSAN** on both implementations.
7. Benchmark throughput of the HP-protected and EBR-protected lock-free pool
   against (a) a GC-allocated baseline (plain `Atomic.make` per node) and
   (b) a mutex-protected free list, across 2–8 threads.

### Research Question

What is the throughput cost of hazard pointer scanning vs. epoch-based
reclamation for protecting a lock-free pool, and how does each scheme's
latency profile differ (HP has bounded garbage, EBR can delay reclamation
under stalled threads)?

### References

- M. M. Michael, "Hazard Pointers: Safe Memory Reclamation for Lock-Free Objects," *IEEE TPDS*, 2004
- K. Fraser, "Practical Lock-Freedom," *PhD thesis, University of Cambridge*, 2004, Chapter 5
- AoMPP Chapter 10, Section 10.6 (Memory Reclamation and the ABA Problem)

---
