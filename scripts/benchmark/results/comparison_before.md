# TPO vs STP Comparison

Generated: 2026-08-26T20:04:28.579

Ratios are TPO / STP.
< 1 means TPO is cheaper or faster.

## Cost Quality (TPO / STP ratio at each step)

| Instance | Bundles | Greedy | LB | Mixed | Init | LS |
|---|---|---|---|---|---|---|
| small | 312 | 1.0056 | 0.9994 | 0.9997 | 1.0056 | 1.0032 |
| medium | 632 | 1.0016 | 0.9995 | 1.0002 | 1.0016 | 1.0011 |
| large | 1165 | 0.9968 | 0.9983 | 0.9983 | 0.9968 | 1.0005 |
| extra_large | 2521 | 0.9997 | 0.9994 | 0.9995 | 0.9997 | 1.0027 |

Geometric-mean init-cost ratio: **1.0009**

Geometric-mean LS-cost ratio: **1.0019**

## Timing (seconds)

| Instance | TPO build | STP build | TPO filter | STP filter | TPO init | STP init |
|---|---|---|---|---|---|---|
| small | 0.10 | 0.11 | 0.42 | 0.43 | 1.07 | 1.05 |
| medium | 0.34 | 0.33 | 1.82 | 1.48 | 5.10 | 4.43 |
| large | 1.15 | 0.71 | 3.60 | 1.68 | 4.53 | 4.92 |
| extra_large | 5.32 | 5.64 | 45.92 | 18.67 | 43.85 | 74.52 |

## Local Search Throughput

| Instance | TPO iters | STP iters | TPO iter/s | STP iter/s | Ratio |
|---|---|---|---|---|---|
| small | 3513 | 5924 | 432.0 | 733.2 | 0.589 |
| medium | 2390 | 5462 | 156.3 | 357.5 | 0.437 |
| large | 5114 | 12834 | 247.2 | 634.6 | 0.390 |
| extra_large | 2076 | 5572 | 76.2 | 212.8 | 0.358 |

