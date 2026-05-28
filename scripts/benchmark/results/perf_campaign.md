# Runtime performance campaign (instance: small)

Best-of-1 wall-clock seconds per stage.

| label | greedy_s | lower_bound_s | filtering_s | mix_s |
| --- | --- | --- | --- | --- |
| baseline | 9.331 | 1.783 | 1.851 | 12.030 |
| bin buffer reuse | 4.550 | 1.734 | 1.755 | 7.158 |
| sort once | 3.476 | 1.750 | 2.044 | 6.226 |
