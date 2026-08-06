import contextlib
import io
import unittest
from unittest import mock

from phyllary.project_gate import cmd_backlog_proof


class BacklogProofTests(unittest.TestCase):
    def test_proof_normalizes_numbered_and_bulleted_criteria(self):
        out = io.StringIO()
        with mock.patch(
            "phyllary.project_gate._work",
            return_value=("dotfiles-123", "title", "1. First criterion\n- Second criterion\n"),
        ), contextlib.redirect_stdout(out):
            self.assertEqual(cmd_backlog_proof("bd", None, ["dotfiles-123"], None), 0)
        self.assertEqual(
            out.getvalue(),
            """{
  \"acceptance\": [
    {
      \"text\": \"First criterion\",
      \"evidence\": \"\"
    },
    {
      \"text\": \"Second criterion\",
      \"evidence\": \"\"
    }
  ]
}
""",
        )


if __name__ == "__main__":
    unittest.main()
