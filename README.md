# Memory Reclamation in Lock-Free Data Structures

### Hazard Pointers vs Epoch-Based Reclamation (EBR)

- **Course:** CS6868 — Concurrent Programming
- **Authors:** Vishnu Surla (CS25M050), Sinigi Ramya Sri (CS25M049)
- **Language:** C++ (C++20 recommended)

---

## Overview

Lock-free data structures provide high scalability but introduce a critical challenge:

> **When is it safe to reclaim (free or reuse) a node that has been removed?**

A thread may still hold a reference to that node, leading to subtle concurrency bugs — most notably the **ABA problem**.

This project explores two widely-used memory reclamation techniques:

* **Hazard Pointers (HP)** — Explicit protection via published pointers
* **Epoch-Based Reclamation (EBR)** — Deferred reclamation via global epochs

We implement both schemes in C++, apply them to lock-free data structures, and evaluate their **correctness, performance, and trade-offs**.

---

## The ABA Problem (Motivation)

In lock-free structures, a pointer can change from:

```
A → B → A
```

A CAS operation may falsely succeed because the pointer appears unchanged, even though the underlying node was removed and reused.

This leads to:

* Use-after-free
* Logical corruption
* Hard-to-reproduce concurrency bugs

---

## Techniques Implemented

### 1. Hazard Pointers (HP)

Each thread publishes the nodes it is currently accessing.

**Key idea:**

> A node cannot be reclaimed if any thread has it in its hazard pointer list.

**Features:**

* Per-thread hazard pointer slots
* Retired list with threshold-triggered scanning
* Safe reclamation via global hazard scan

---

### 2. Epoch-Based Reclamation (EBR)

Time is divided into global epochs.

**Key idea:**

> A node retired in epoch `e` can be reclaimed once all threads have advanced beyond `e + 1`.

**Features:**

* Global atomic epoch counter
* Per-thread local epochs
* Epoch-tagged limbo lists
* Batched reclamation

---

## Implementations

### Lock-Free Pool (Free List)

* Fixed-size node pool
* Supports concurrent `push` and `pop`
* Demonstrates ABA under naive reuse

### Michael-Scott Queue

* Lock-free queue using CAS
* Integrated with HP and EBR for node recycling

---

## Demonstrating ABA

We intentionally construct a failing scenario:

1. Thread T1 reads node `A`
2. Thread T2 removes `A`, reuses it, and inserts back
3. T1 performs CAS assuming node unchanged

Result: **Incorrect success → ABA bug**

We provide:

* Reproducible test (`aba_test.cpp`)
* High-contention stress scenarios

---

## Fixing ABA

| Technique       | Prevention Mechanism                 |
| --------------- | ------------------------------------ |
| Hazard Pointers | Prevent reclamation while referenced |
| EBR             | Delay reclamation across epochs      |

Both implementations eliminate ABA in our test suite.

---

## Testing & Verification

### Linearizability Testing

* Custom + randomized tests
* Designed for concurrent interleavings

### Stress Testing

* Rapid push-pop cycles
* Small pool to force reuse
* High contention (2–8 threads)

### Thread Sanitizer (TSAN)

Run:

```bash
./scripts/run_tsan.sh
```

Detects:

* Data races
* Unsafe memory access

---

## Benchmarking

We compare:

1. **Hazard Pointer Pool**
2. **EBR Pool**
3. **GC-like Baseline** (fresh allocation per node)
4. **Mutex-Protected Free List**

### Metrics

* Throughput (ops/sec)
* Latency distribution
* Memory overhead
* Reclamation delay

### Run Benchmark

```bash
g++ -O3 -std=c++20 benchmarks/benchmark_pool.cpp -lpthread
./a.out
```

---

## Research Question

> What is the throughput cost of hazard pointer scanning vs epoch-based reclamation, and how do their latency profiles differ?

### Expected Observations

| Property                       | Hazard Pointers         | EBR                       |
| ------------------------------ | ----------------------- | ------------------------- |
| Reclamation latency            | Low (eager)             | Potentially high          |
| Throughput                     | Lower (due to scanning) | Higher                    |
| Memory usage                   | Bounded                 | Can grow if threads stall |
| Sensitivity to stalled threads | Low                     | High                      |

---

## Build Instructions

### Requirements

* C++20
* pthreads
* GCC / Clang (TSAN support recommended)

### Build

```bash
g++ -std=c++20 -O2 -pthread src/*.cpp tests/*.cpp -o test
./test
```

---

## References

* M. M. Michael, *Hazard Pointers: Safe Memory Reclamation for Lock-Free Objects*, IEEE TPDS, 2004
* K. Fraser, *Practical Lock-Freedom*, PhD Thesis, University of Cambridge, 2004
* Maurice Herlihy & Nir Shavit, *The Art of Multiprocessor Programming*, Section 10.6

---

## Contributors

* **Vishnu Surla** (CS25M050)
* **Sinigi Ramya Sri** (CS25M049)

---


