# tool-pin: ignore -- fixture bytes for the stage hash, never built (base#2094)
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
