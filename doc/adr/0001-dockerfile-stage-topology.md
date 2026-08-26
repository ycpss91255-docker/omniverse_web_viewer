# Dockerfile Stage Topology: Dedicated Build Stages + Lean Runtime From `devel-base`

The Dockerfile is a diamond, not a linear chain. Two dedicated per-app build
stages (`usd-viewer-build`, `stream-only-build`) produce the static dists; the
shippable `runtime` stage and the interactive `devel` stage are SIBLINGS, both
`FROM devel-base`, and each `COPY --from` the prebuilt dists. `runtime` is
deliberately NOT `FROM devel` and is NOT downstream of `devel`.

## Context

The stage graph reads, to a first glance, as "wrong" in two recurring ways,
and this ADR exists so the next reviewer does not try to "fix" it:

1. "Shouldn't `runtime` come after `devel`?" -- i.e. `runtime` should
   `COPY --from=devel` the final artifact.
2. "Shouldn't the app builds come before `devel`?" -- i.e. `devel` should be
   downstream of the build stages.

Both intuitions describe a LINEAR pipeline `base -> build -> devel -> runtime`,
where `devel` is the builder and `runtime` is a stripped copy of it. That is a
valid pattern in general, but it conflicts with two properties this image must
hold:

- **Lean runtime (PRD D4 / S5).** The deployable image must carry only
  `node` + `serve` (from `devel-base`) plus the two built dists -- no npm,
  no source tree, no app `node_modules`, no dev toolchain.

  Being `FROM devel-base` does not deliver that on its own, and for a long
  time it did not: `devel-base` apt-installs `sudo git curl ca-certificates`
  and the nodejs deb brings `npm` + `corepack` with it, so the published
  image carried all of them while this bullet said otherwise. Anyone sizing
  the sidecar's blast radius from this ADR was underestimating it. The
  `runtime` stage now removes what it does not ship (`npm`, `npx`,
  `corepack`, `git`, `sudo`) and `runtime-test` asserts their absence
  in-image, so this bullet is enforced rather than merely stated. One
  documented exception: **`curl` stays**, because the two `FROM runtime`
  test stages use it as their HTTP client (`RUNTIME_SMOKE_CMD` and
  `test/e2e/run-in-image.sh`), and removing it while `node` -- which has a
  global `fetch` -- remains would change the contract without changing what
  an attacker can do.
- **Two apps with different builds.** `usd-viewer` is the upstream
  `web-viewer-sample` built UNMODIFIED (D2) from its own `src/` + `npm install`;
  `stream-only` is our own app built through the npm WORKSPACE so it resolves
  its sibling `stream-core`. These are genuinely different build procedures.

Key fact that makes the "use devel as the builder" idea misleading: `devel`
today is NOT a builder. It runs `npm install` and copies `src/` so a human can
rebuild in place, but it does NOT run `npm run build`; the dists it serves are
`COPY --from` the dedicated build stages. Making `runtime` copy from `devel`
would require turning `devel` into a dual-purpose dev-environment-plus-builder
that builds BOTH apps, and would put the fat `devel` image on the production
build path.

## Decision

Use the multi-stage builder pattern with DEDICATED build stages:

```
                  +- usd-viewer-build  --+
  devel-base -----+                      +-(COPY dist)-> runtime  (ship, lean)
       |          +- stream-only-build --+                  +- runtime-test
       |                                                    +- e2e-test
       +-------------------------------------(COPY dist)-> devel
                                                              +- devel-test
```

- `sys -> devel-base` is the shared foundation (`devel-base` installs `node` +
  `serve`).
- `usd-viewer-build` and `stream-only-build` are `FROM devel-base`, each runs
  its own build, and stages its dist at `/app/<mode>/dist`.
- `runtime` is `FROM devel-base` and `COPY --from` both dists. It is the only
  shippable image and stays lean.
- `devel` is a SIBLING `FROM devel-base` for interactive development; it also
  `COPY --from` both dists so the uniform entrypoint (`serve /app/$mode/dist`)
  behaves identically to `runtime` for `devel-test`.
- `runtime-test` / `e2e-test` are `FROM runtime`; `devel-test` is `FROM devel`.

## Consequences

Benefits (why dedicated builders beat devel-as-builder):

- **Lean runtime preserved.** `runtime FROM devel-base` carries no source /
  `node_modules` / toolchain. `runtime FROM devel` would inherit all of it.
- **The two different builds stay separated** in their own stages instead of
  being crammed into one.
- **Parallel builds.** BuildKit builds the two `*-build` stages concurrently;
  a single in-`devel` build would be sequential.
- **Cache isolation.** A dev-only change (bashrc, entrypoint, shell setup)
  invalidates `devel` but NOT the build stages, so the shipped dist stays
  cached. With devel-as-builder, dev churn would invalidate the artifact.
- **Production does not depend on the dev image.** The ship path
  `sys -> devel-base -> *-build -> runtime` never builds `devel`. Copying from
  `devel` would force the fat, slow dev image onto every production build.

Costs (accepted):

- `devel` and the `*-build` stages each run an install (NOT each run a build).
  Which install differs, and the difference is deliberate: `stream-only-build`
  (and the `example` stage) run `npm ci` from the committed workspace lockfile,
  because the bundle they emit is what ships; `usd-viewer-build` and `devel`
  run `npm install`, because that tree is the upstream `web-viewer-sample`
  submodule, which ships no lockfile and which D2 says is built UNMODIFIED.
  This duplicate install is the unavoidable price of keeping a separate
  interactive dev image AND dedicated builders; it buys all the benefits above.

## Alternatives considered

- **Linear `devel` as the builder** (`runtime COPY --from=devel`). Rejected:
  puts the fat dev image on the production build path, serializes the two app
  builds, couples artifact cache to dev churn, and forces both build procedures
  into one stage.
- **Build inside `runtime`** (no separate builders). Rejected: bloats the
  shippable image with npm + source + `node_modules`, the exact anti-pattern
  S5 removed.

## Status

Accepted.
