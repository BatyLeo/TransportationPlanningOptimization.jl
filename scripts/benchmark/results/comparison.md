# TPO vs STP Comparison

Generated: 2026-08-17T19:13:39.757

Ratios are TPO / STP.
< 1 means TPO is cheaper or faster.

## Cost Quality (TPO / STP ratio at each step)

| Instance | Bundles | Greedy | LB | Mixed | Init | LS |
|---|---|---|---|---|---|---|
| small | 312 | 1.0163 | 1.0006 | 1.0009 | 1.0163 | 1.0276 |
| medium | 632 | 1.0126 | 0.9999 | 1.0019 | 1.0126 | 1.0231 |
| large | 1165 | 0.9970 | 0.9982 | 0.9989 | 0.9970 | 1.0254 |
| extra_large | 2521 | 1.0019 | 0.9992 | 0.9999 | 1.0019 | 1.0092 |

Geometric-mean init-cost ratio: **1.0069**

Geometric-mean LS-cost ratio: **1.0213**

## Timing (seconds)

| Instance | TPO build | STP build | TPO filter | STP filter | TPO init | STP init |
|---|---|---|---|---|---|---|
| small | 0.16 | 0.30 | 0.50 | 0.74 | 2.15 | 1.37 |
| medium | 0.43 | 0.67 | 2.35 | 3.73 | 6.68 | 7.31 |
| large | 1.78 | 1.26 | 7.04 | 2.76 | 8.24 | 9.28 |
| extra_large | 6.34 | 7.37 | 65.39 | 25.78 | 53.55 | 107.57 |

## Local Search Throughput

| Instance | TPO iters | STP iters | TPO iter/s | STP iter/s | Ratio |
|---|---|---|---|---|---|
| small | 8110 | 5744 | 807.6 | 570.9 | 1.415 |
| medium | 2437 | 3675 | 81.2 | 119.7 | 0.678 |
| large | 15000 | 25698 | 316.2 | 425.9 | 0.742 |
| extra_large | 9069 | 17792 | 74.8 | 147.1 | 0.508 |

