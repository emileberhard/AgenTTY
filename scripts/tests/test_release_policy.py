import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ReleasePolicyTests(unittest.TestCase):
    def test_the_main_target_never_compiles_the_local_unlock(self):
        project = (ROOT / "AgenTTY.xcodeproj/project.xcproj").read_text()
        start = project.index('"name": "AgenTTY-iOS",')
        end = project.index('"name": "AgenTTY-iOS-Dev",')
        self.assertNotIn("AGENTTY_LOCAL_MAIN_UNLOCK", project[start:end])

    def test_the_release_workflow_does_not_pass_the_local_unlock(self):
        self.assertNotIn("AGENTTY_LOCAL_MAIN_UNLOCK", (ROOT / ".github/workflows/release.yml").read_text())
