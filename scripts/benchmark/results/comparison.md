# TPO vs STP Comparison

Generated: 2026-08-15T16:57:46.720

Ratios are TPO / STP.
< 1 means TPO is cheaper or faster.

## Cost Quality (TPO / STP ratio at each step)

| Instance | Bundles | Greedy | LB | Mixed | Init | LS |
|---|---|---|---|---|---|---|
| small | 312 | 1.0163 | 1.0006 | 1.0009 | 1.0163 | 1.0013 |
| medium | 632 | 1.0126 | 0.9999 | 1.0019 | 1.0126 | 1.0047 |
| large | 1165 | 0.9970 | 0.9982 | 0.9989 | 0.9970 | 0.9979 |
| extra_large | 2521 | 1.0019 | 0.9992 | 0.9999 | 1.0019 | 1.0058 |

Geometric-mean init-cost ratio: **1.0069**

Geometric-mean LS-cost ratio: **1.0024**

## Timing (seconds)

| Instance | TPO build | STP build | TPO filter | STP filter | TPO init | STP init |
|---|---|---|---|---|---|---|
| small | 0.10 | 0.18 | 0.39 | 0.53 | 1.50 | 1.20 |
| medium | 0.36 | 0.49 | 2.05 | 1.80 | 5.56 | 4.80 |
| large | 1.04 | 0.92 | 3.37 | 2.18 | 3.88 | 5.26 |
| extra_large | 6.39 | 7.02 | 53.74 | 21.61 | 51.65 | 85.32 |

## Local Search Throughput

| Instance | TPO iters | STP iters | TPO iter/s | STP iter/s | Ratio |
|---|---|---|---|---|---|
| small | 1280 | 7349 | 110.7 | 730.4 | 0.152 |
| medium | 1334 | 10033 | 40.9 | 332.0 | 0.123 |
| large | 6637 | 38918 | 107.7 | 646.2 | 0.167 |
| extra_large | 1539 | 20516 | 12.3 | 169.7 | 0.072 |

