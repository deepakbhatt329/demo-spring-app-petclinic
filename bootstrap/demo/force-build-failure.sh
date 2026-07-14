#!/usr/bin/env bash
# Push a commit that intentionally breaks a test so the next Jenkins run FAILS.
# Combined with trigger-incident.sh, this demonstrates: deploy failure -> PagerDuty -> IM.
#
# Usage:
#   ./force-build-failure.sh
#
# Undo:
#   git revert HEAD --no-edit && git push

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

TEST_FILE="src/test/java/org/springframework/samples/petclinic/demo/ForcedFailureTest.java"
mkdir -p "$(dirname "$TEST_FILE")"

cat > "$TEST_FILE" <<'JAVA'
package org.springframework.samples.petclinic.demo;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.fail;

class ForcedFailureTest {
    @Test
    void demoIntentionalFailure() {
        fail("Intentional failure to demo Jenkins -> PagerDuty -> IM path");
    }
}
JAVA

git add "$TEST_FILE"
git commit -m "demo: intentional test failure to exercise incident path"
git push
echo
echo "Pushed. Watch Jenkins for the next FAILED build, then run trigger-incident.sh."
