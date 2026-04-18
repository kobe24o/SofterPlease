#!/usr/bin/env python3
"""构建中文口语情绪语料（文本版）。

说明：
- 该脚本生成弱标注语料，用于先训练一个可落地的“情绪好坏/分值”基线模型。
- 语料来自人工整理的家庭沟通短句模板 + 语气增强，不包含真实用户隐私数据。
"""

from __future__ import annotations

import csv
import random
from pathlib import Path

random.seed(42)

GOOD_SENTENCES = [
    "谢谢你今天帮我照顾孩子",
    "我们慢慢说，我在听",
    "没关系，我们一起想办法",
    "你辛苦了，先休息一下",
    "我理解你的感受",
    "我们先冷静一下再聊",
    "这个建议很好，我接受",
    "你做得很棒",
    "今天沟通很顺畅",
    "我愿意先道歉",
]

BAD_SENTENCES = [
    "你怎么又这样",
    "我受够了，别说了",
    "快点，别废话",
    "你到底懂不懂",
    "烦死了，闭嘴",
    "我现在非常生气",
    "为什么总是你拖后腿",
    "你从来都不听",
    "别烦我",
    "滚开",
]

NEUTRAL_SENTENCES = [
    "晚饭七点开始",
    "孩子作业写完了吗",
    "我先去接个电话",
    "你明天几点出门",
    "今天需要买牛奶",
    "待会儿开个家庭会",
    "这个周末回爸妈家",
    "我把门关上了",
]

PREFIXES = ["", "请", "能不能", "拜托", "现在", "真的", "麻烦你"]
SUFFIXES = ["", "。", "！", "!!", "好吗", "行吗", "吧"]


def augment(base: str, count: int) -> list[str]:
    outs: list[str] = []
    for _ in range(count):
        p = random.choice(PREFIXES)
        s = random.choice(SUFFIXES)
        sentence = f"{p}{base}{s}".strip()
        # 轻微重复，模拟口语
        if random.random() < 0.15:
            sentence += random.choice(["", "啊", "呀", "...", "！！"])
        outs.append(sentence)
    return outs


def build_rows() -> list[tuple[str, str, float]]:
    rows: list[tuple[str, str, float]] = []

    for sentence in GOOD_SENTENCES:
        for aug in augment(sentence, 24):
            score = round(random.uniform(0.05, 0.35), 3)
            rows.append((aug, "good", score))

    for sentence in BAD_SENTENCES:
        for aug in augment(sentence, 24):
            score = round(random.uniform(0.65, 0.98), 3)
            rows.append((aug, "bad", score))

    for sentence in NEUTRAL_SENTENCES:
        for aug in augment(sentence, 18):
            score = round(random.uniform(0.42, 0.58), 3)
            label = "bad" if score >= 0.5 else "good"
            rows.append((aug, label, score))

    random.shuffle(rows)
    return rows


def write_csv(rows: list[tuple[str, str, float]], out_file: Path) -> None:
    out_file.parent.mkdir(parents=True, exist_ok=True)
    with out_file.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["text", "label", "score"])
        writer.writerows(rows)


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    out_file = repo_root / "training" / "data" / "emotion_text_corpus_zh.csv"
    rows = build_rows()
    write_csv(rows, out_file)
    print(f"Wrote {len(rows)} rows -> {out_file}")


if __name__ == "__main__":
    main()
