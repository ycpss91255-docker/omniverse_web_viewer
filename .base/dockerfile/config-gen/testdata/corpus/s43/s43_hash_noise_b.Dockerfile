# tool-pin: ignore -- fixture bytes for the stage hash, never built (base#2094)
FROM ubuntu:24.04 AS sys
RUN apt-get install -y wget
FROM sys AS base
ENV BAZ=qux
# new comment
FROM base AS devel
