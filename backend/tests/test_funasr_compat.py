import os
import subprocess
import sys


def test_funasr_auto_model_import_is_quiet():
    env = os.environ.copy()
    env.pop("FUNASR_IMPORT_DEBUG", None)
    env.pop("FUNASR_STRICT_IMPORT", None)
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "from app.funasr_compat import get_auto_model_class; print(get_auto_model_class().__name__)",
        ],
        cwd=os.getcwd(),
        env=env,
        text=True,
        capture_output=True,
        timeout=60,
        check=False,
    )

    combined = result.stdout + result.stderr
    assert result.returncode == 0, combined
    assert "AutoModel" in result.stdout
    assert "Failed to import funasr" not in combined
