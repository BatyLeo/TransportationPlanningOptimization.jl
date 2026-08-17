# TPO vs STP Comparison

Generated: 2026-08-17T19:50:04.318

Ratios are TPO / STP.
< 1 means TPO is cheaper or faster.

## Cost Quality (TPO / STP ratio at each step)

| Instance | Bundles | Greedy | LB | Mixed | Init | LS |
|---|---|---|---|---|---|---|
| small | 312 | 1.0163 | 1.0006 | 1.0009 | 1.0163 | 1.0270 |
| medium | 632 | 1.0126 | 0.9999 | 1.0019 | 1.0126 | 1.0246 |
| large | 1165 | 0.9970 | 0.9982 | 0.9989 | 0.9970 | 1.0264 |
| extra_large | 2521 | 1.0019 | 0.9992 | 0.9999 | 1.0019 | 1.0099 |

Geometric-mean init-cost ratio: **1.0069**

Geometric-mean LS-cost ratio: **1.0220**

## Timing (seconds)

| Instance | TPO build | STP build | TPO filter | STP filter | TPO init | STP init |
|---|---|---|---|---|---|---|
| small | 0.12 | 0.22 | 0.76 | 0.63 | 1.65 | 1.49 |
| medium | 0.48 | 0.77 | 2.74 | 2.15 | 6.62 | 6.35 |
| large | 1.24 | 0.97 | 3.49 | 2.32 | 4.45 | 6.04 |
| extra_large | 6.79 | 10.09 | 58.94 | 25.95 | 52.33 | 102.32 |

## Local Search Throughput

| Instance | TPO iters | STP iters | TPO iter/s | STP iter/s | Ratio |
|---|---|---|---|---|---|
| small | 3086 | 4511 | 308.2 | 446.8 | 0.690 |
| medium | 2090 | 7895 | 69.6 | 261.0 | 0.267 |
| large | 15000 | 35284 | 374.6 | 585.7 | 0.640 |
| extra_large | 4493 | 10736 | 37.4 | 88.5 | 0.423 |

