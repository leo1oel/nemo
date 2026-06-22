#!/usr/bin/env bash
# Print the crewmate harness. This fork is Claude-only, so it always prints "claude".
# Usage: fm-harness.sh [crew]   -> claude
# (Upstream firstmate detects several harnesses here and resolves config/crew-harness;
#  pull that from upstream to restore multi-harness support.)
set -u
echo claude
