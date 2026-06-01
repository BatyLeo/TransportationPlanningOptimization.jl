# TPO vs STP — step-by-step cost comparison

Generated: 2026-05-29T17:27:41.902

All costs are full-instance costs (filtered + sub merged back).
Ratios are TPO / STP. < 1 means TPO is cheaper.

## small  (LS 10s, ILS 20s)

| Step | TPO cost | STP cost | TPO / STP |
|---|---|---|---|
| greedy candidate | 3302815.8 | 3252865.8 | 1.0154 |
| lower-bound candidate | 3727050.4 | 3728605.2 | 0.9996 |
| mixed candidate | 3668893.9 | 3668669.1 | 1.0001 |
| **init (best of 3)** | **3302815.8** | **3252865.8** | **1.0154** |
| **after LS** | **3217946.9** | **3215055.5** | **1.0009** |
| **after STP ILS** | n/a | **3215055.5** | — |

## medium  (LS 30s, ILS 60s)

| Step | TPO cost | STP cost | TPO / STP |
|---|---|---|---|
| greedy candidate | 11628863.7 | 11490479.7 | 1.0120 |
| lower-bound candidate | 12999047.4 | 13005255.8 | 0.9995 |
| mixed candidate | 12980809.5 | 12960720.7 | 1.0015 |
| **init (best of 3)** | **11628863.7** | **11490479.7** | **1.0120** |
| **after LS** | **11475453.1** | **11346418.0** | **1.0114** |
| **after STP ILS** | n/a | **11346418.0** | — |

## large  (LS 60s, ILS 120s)

| Step | TPO cost | STP cost | TPO / STP |
|---|---|---|---|
| greedy candidate | 25861973.6 | 25943848.5 | 0.9968 |
| lower-bound candidate | 26556550.1 | 26608515.9 | 0.9980 |
| mixed candidate | 26590898.4 | 26626383.2 | 0.9987 |
| **init (best of 3)** | **25861973.6** | **25943848.5** | **0.9968** |
| **after LS** | **25244043.6** | **25267312.3** | **0.9991** |
| **after STP ILS** | n/a | **25267312.3** | — |

## extra_large  (LS 120s, ILS 240s)

| Step | TPO cost | STP cost | TPO / STP |
|---|---|---|---|
| greedy candidate | 78163842.4 | 78053397.2 | 1.0014 |
| lower-bound candidate | 82095776.0 | 82185472.2 | 0.9989 |
| mixed candidate | 81876125.9 | 81907753.9 | 0.9996 |
| **init (best of 3)** | **78163842.4** | **78053397.2** | **1.0014** |
| **after LS** | **77846472.8** | **77378938.4** | **1.0060** |
| **after STP ILS** | n/a | **77378938.4** | — |

## Summary — TPO/STP ratios at each step

| instance | greedy | lower_b. | mixed | init | LS | (STP ILS abs) |
|---|---|---|---|---|---|---|
| small | 1.0154 | 0.9996 | 1.0001 | 1.0154 | 1.0009 | 3215055.5 |
| medium | 1.0120 | 0.9995 | 1.0015 | 1.0120 | 1.0114 | 11346418.0 |
| large | 0.9968 | 0.9980 | 0.9987 | 0.9968 | 0.9991 | 25267312.3 |
| extra_large | 1.0014 | 0.9989 | 0.9996 | 1.0014 | 1.0060 | 77378938.4 |

## STP only — does ILS improve over LS?

| instance | LS cost | ILS cost | ILS / LS |
|---|---|---|---|
| small | 3215055.5 | 3215055.5 | 1.000000 |
| medium | 11346418.0 | 11346418.0 | 1.000000 |
| large | 25267312.3 | 25267312.3 | 1.000000 |
| extra_large | 77378938.4 | 77378938.4 | 1.000000 |
