#!/usr/bin/env bash
set -euo pipefail
echo 'PASS ci-probe: setup'
intentional_failure() { false; }
intentional_failure
