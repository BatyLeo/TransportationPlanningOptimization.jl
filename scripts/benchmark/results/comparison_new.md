# TPO vs STP Comparison

Generated: 2026-08-17T02:43:25.361

Ratios are TPO / STP.
< 1 means TPO is cheaper or faster.

## Cost Quality (TPO / STP ratio at each step)

| Instance | Bundles | Greedy | LB | Mixed | Init | LS |
|---|---|---|---|---|---|---|
| small | 312 | 1.0163 | 1.0006 | 1.0009 | 1.0163 | 1.0278 |
| medium | 632 | 1.0126 | 0.9999 | 1.0019 | 1.0126 | 1.0253 |
| large | 1165 | 0.9970 | 0.9982 | 0.9989 | 0.9970 | 1.0257 |
| extra_large | 2521 | 1.0019 | 0.9992 | 0.9999 | 1.0019 | 1.0095 |

Geometric-mean init-cost ratio: **1.0069**

Geometric-mean LS-cost ratio: **1.0220**

## Timing (seconds)

| Instance | TPO build | STP build | TPO filter | STP filter | TPO init | STP init |
|---|---|---|---|---|---|---|
| small | 0.10 | 0.14 | 0.39 | 0.47 | 1.30 | 1.11 |
| medium | 0.35 | 0.39 | 1.97 | 1.67 | 4.68 | 4.37 |
| large | 1.04 | 0.89 | 3.25 | 2.07 | 3.74 | 4.86 |
| extra_large | 4.70 | 6.49 | 48.12 | 21.91 | 39.15 | 80.21 |

## Local Search Throughput

| Instance | TPO iters | STP iters | TPO iter/s | STP iter/s | Ratio |
|---|---|---|---|---|---|
| small | 4078 | 7646 | 407.5 | 759.9 | 0.536 |
| medium | 2463 | 9422 | 70.5 | 311.0 | 0.227 |
| large | 12272 | 43336 | 203.4 | 720.0 | 0.283 |
| extra_large | 4542 | 21667 | 36.2 | 179.2 | 0.202 |

