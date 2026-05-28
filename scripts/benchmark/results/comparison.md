# TPO vs STP full-pipeline comparison

Generated: 2026-05-26T15:37:20.058

Ratios are TPO / STP (< 1 means TPO is cheaper / faster).

| instance | n_bundles | tpo_build_s | stp_build_s | tpo_filter_s | stp_filter_s | tpo_init_cost | stp_init_cost | init_cost_ratio | tpo_init_s | stp_init_s | tpo_ls_cost | stp_ls_cost | ls_cost_ratio | tpo_ls_s | stp_ls_s | tpo_init_feasible | stp_init_feasible | tpo_ls_feasible | stp_ls_feasible |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| small | 312 | 0.17 | 0.22 | 2.59 | 0.77 | 3.3028158e6 | 3.2528658e6 | 1.0154 | 6.85 | 2.09 | 3.2280857e6 | 3.2100082e6 | 1.0056 | 10.03 | 10.09 | true | true | true | true |
| medium | 632 | 0.67 | 0.61 | 12.1 | 2.28 | 1.16288637e7 | 1.14904797e7 | 1.012 | 30.27 | 6.14 | 1.15101749e7 | 1.13551303e7 | 1.0137 | 30.09 | 30.44 | true | true | true | true |
| large | 1165 | 1.93 | 1.22 | 19.07 | 3.07 | 2.58619736e7 | 2.59438485e7 | 0.9968 | 19.46 | 7.69 | 2.51476293e7 | 2.52425881e7 | 0.9962 | 60.04 | 60.33 | true | true | true | true |

## Summary

- Geometric-mean init-cost ratio (TPO/STP): 1.0080
- Geometric-mean LS-cost ratio (TPO/STP): 1.0051
