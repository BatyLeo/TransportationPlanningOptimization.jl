const EPS = 1e-8
const COST_IMPROVEMENT_EPS = 1e-6
# Number of arcs between two deadline checks in the virtual-bundle cost-matrix sweep.
const DEADLINE_CHECK_EVERY = 64
# Removal sizes up to this use a linear scan, larger ones a Dict multiset.
const LINEAR_REMOVAL_MAX = 8
