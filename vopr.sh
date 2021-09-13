#!/usr/bin/env bash
set -e

# If a seed is provided as an argument then replay the seed, otherwise test a 1,000 seeds:
if [ "$1" ]; then
    # Build in fast ReleaseSafe mode if required, useful where you don't need debug logging:
    if [ "$2" == "-OReleaseSafe" ]; then
        echo "Replaying seed $1 in ReleaseSafe mode..."
        BUILD_MODE="-OReleaseSafe"
    else
        echo "Replaying seed $1 in Debug mode with full debug logging enabled..."
        BUILD_MODE="-ODebug"
    fi
    echo ""

    zig run src/simulator.zig $BUILD_MODE -- $1
else
    zig build-exe src/simulator.zig -OReleaseSafe
    for I in {1..1000}
    do
        ./simulator
    done
fi
