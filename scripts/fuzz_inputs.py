"""
Write generated wikitext inputs for differential fuzzing against the reference.

Each input joins random pieces of wikitext markup, so constructs open, close and
overlap in ways real pages rarely do. Constructs nested around the depth limit
are written too. No input holds NUL, where the reference's C tokenizer stops.

Usage (`mise run fuzz` runs it, generates the reference and the tests):

    uv run scripts/fuzz_inputs.py out_dir seed count
"""

import random
import sys
from pathlib import Path

PIECES = [
    # templates, arguments and links
    "{{", "}}", "{{{", "}}}", "[[", "]]", "[", "]", "{", "}", "|", "=", "x=", "b=",
    "http://", "http://x.org", "x.org", "mailto:", "Category:", "File:", "(", ")",
    # headings, lists and rules
    "==", "*", "#", ":", ";", "-", "----", "\n", "\n",
    # bold and italics
    "'", "''", "'''",
    # tags, attributes and comments
    "<", ">", "</", "/>", "<b>", "</b>", "<br", "<br>", "<br/>", "<ref", "<ref>",
    "</ref>", '<ref name="a">', "<span", "</span>", "<div", "<div class=x>", "</div>",
    "<td", "<td>", "<li>", "<nowiki", "<nowiki>", "</nowiki>", "<!--", "-->",
    'style="a"', "style", "class", '"', "\\", "\\\\",
    # entities
    "&", "&amp;", "&quot;", "&#", "&#039;", "&#x41;",
    # tables
    "{|", "|}", "|-", "||", "!", "!!",
    # text and whitespace
    "a", "b c", ".", ",", " ", " ", "\t", "　", "\x1c", "é", "日本", "😀",
]

DEPTHS = [99, 100, 101, 150]


def random_input(rng):
    return "".join(rng.choice(PIECES) for _ in range(rng.randint(1, 80)))


def nested_inputs():
    for depth in DEPTHS:
        yield f"deep_template_{depth}", "{{" * depth + "x" + "}}" * depth
        yield f"deep_link_{depth}", "[[a|" * depth + "x" + "]]" * depth
        yield f"deep_style_{depth}", "''a'''b" * depth


def main():
    out, seed, count = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    for index in range(count):
        (out / f"fuzz_{seed}_{index:05d}.wikitext").write_text(random_input(rng), encoding="utf8")
    for name, text in nested_inputs():
        (out / f"{name}.wikitext").write_text(text, encoding="utf8")


if __name__ == "__main__":
    main()
