# TPO vs STP Comparison

Generated: 2026-08-26T21:14:10.721

Ratios are TPO / STP.
< 1 means TPO is cheaper or faster.

## Cost Quality (TPO / STP ratio at each step)

| Instance | Bundles | Greedy | LB | Mixed | Init | LS |
|---|---|---|---|---|---|---|
| small | 312 | 1.0056 | 0.9994 | 0.9997 | 1.0056 | 1.0023 |
| medium | 632 | 1.0016 | 0.9995 | 1.0002 | 1.0016 | 1.0022 |
| large | 1165 | 0.9968 | 0.9983 | 0.9983 | 0.9968 | 1.0013 |
| extra_large | 2521 | 0.9997 | 0.9994 | 0.9995 | 0.9997 | 1.0026 |

Geometric-mean init-cost ratio: **1.0009**

Geometric-mean LS-cost ratio: **1.0021**

## Timing (seconds)

| Instance | TPO build | STP build | TPO filter | STP filter | TPO init | STP init |
|---|---|---|---|---|---|---|
| small | 0.11 | 0.12 | 0.45 | 0.45 | 1.69 | 1.06 |
| medium | 0.35 | 0.35 | 2.96 | 1.51 | 6.18 | 4.42 |
| large | 1.14 | 0.72 | 3.88 | 1.72 | 4.54 | 5.18 |
| extra_large | 5.43 | 6.02 | 55.53 | 19.08 | 52.42 | 78.09 |

## Local Search Throughput

| Instance | TPO iters | STP iters | TPO iter/s | STP iter/s | Ratio |
|---|---|---|---|---|---|
| small | 3421 | 6305 | 427.3 | 782.1 | 0.546 |
| medium | 2542 | 4912 | 165.1 | 321.7 | 0.513 |
| large | 4812 | 13360 | 231.2 | 660.4 | 0.350 |
| extra_large | 1983 | 5321 | 79.2 | 204.1 | 0.388 |

