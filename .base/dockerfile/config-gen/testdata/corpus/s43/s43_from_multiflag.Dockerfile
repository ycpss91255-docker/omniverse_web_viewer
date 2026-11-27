# arch-literal-lint: allow-begin -- fixture bytes for the FROM-line parser, never built (base#2095)
# tool-pin: ignore -- fixture bytes for the FROM-line parser, never built (base#2095)
FROM --platform=linux/arm64 --link ubuntu:24.04 AS runtime
# arch-literal-lint: allow-end
