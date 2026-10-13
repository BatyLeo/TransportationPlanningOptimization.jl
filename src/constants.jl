const EPS = 1e-8
const COST_IMPROVEMENT_EPS = 1e-6
# Number of work items (arcs, labels or settled nodes) between two deadline checks.
const DEADLINE_CHECK_EVERY = 64
# Removal sizes up to this use a linear scan, larger ones a Dict multiset.
const LINEAR_REMOVAL_MAX = 8
