# test/bats/acceptance/ (no specs, by design)

**Acceptance** level (UAT / OAT). ISTQB taxonomy,
ADR-00000018 -- verifies what the downstream consumer receives (the
scaffolded framework + its UX: `just` commands, help, completion, the
generated layout), from the consumer's chair.

Its checks are not bats specs. They drive a real scaffolded consumer and a
built image on the host, through `script/ci/acceptance.sh`: the
`acceptance` job in CI, `just test acceptance` locally. This directory
stays an intentional empty placeholder (`.gitkeep`) so the full level x
type grid is visible in the tree. See
[acceptance.md](../../../doc/test/acceptance.md).
