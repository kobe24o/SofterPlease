from __future__ import annotations

from typing import Any


def get_auto_model_class() -> type[Any]:
    from funasr.auto.auto_model import AutoModel

    return AutoModel
