"""
Generate reference output from mwparserfromhell for WikitextEx's conformance tests.

For every input it records the token stream mwparserfromhell's tokenizer emits and
the node tree its builder produces, the tree written in WikitextEx's AST shape
(before WikitextEx groups list items). The Elixir tests compare against this file.

Inputs are either mwparserfromhell's own tokenizer suite (`.mwtest` files, only the
`input:` lines are read) or a directory of `.wikitext` files.

Usage (needs mwparserfromhell installed, e.g. in a virtualenv):

    python -I scripts/mwph_reference.py mwtest path/to/mwparserfromhell/tests/tokenizer out.json
    python -I scripts/mwph_reference.py files path/to/wikitext_dir out.json

Set MWPH_TOKENIZER=python to use the pure-Python tokenizer instead of the C one.
"""

import json
import os
import sys
from pathlib import Path

import mwparserfromhell
from mwparserfromhell import nodes
from mwparserfromhell.nodes.extras import Parameter
from mwparserfromhell.parser import tokens as T
from mwparserfromhell.parser.builder import Builder

WHITESPACE = "".join(chr(c) for c in range(sys.maxunicode + 1) if chr(c).isspace())


def tokenizer():
    if os.environ.get("MWPH_TOKENIZER") == "python":
        from mwparserfromhell.parser.tokenizer import Tokenizer

        return Tokenizer()
    from mwparserfromhell.parser._tokenizer import CTokenizer

    return CTokenizer()


def split_padding(text):
    stripped = text.strip()
    if not stripped:
        return "", [text, ""]
    start = text.index(stripped)
    return stripped, [text[:start], text[start + len(stripped) :]]


def dump_token(token):
    name = type(token).__name__
    attrs = {key: value for key, value in dict(token).items()}
    if name == "Text":
        return attrs["text"]
    return [name, attrs]


def dump_nodes(wikicode):
    return [dump_node(node) for node in wikicode.nodes] if wikicode is not None else []


def node(type_, meta, children=None):
    return {"type": type_, "meta": meta, "children": children or []}


def dump_attr(attr):
    return {
        "name": str(attr.name),
        "value": None if attr.value is None else str(attr.value),
        "quote": attr.quotes,
        "pad_first": attr.pad_first,
        "pad_before_eq": attr.pad_before_eq,
        "pad_after_eq": attr.pad_after_eq,
    }


def normalized_char(entity):
    code = ord(entity.normalize())
    return "�" if 0xD800 <= code <= 0xDFFF else chr(code)


def dump_param(param: Parameter):
    name, padding = split_padding(str(param.name))
    meta = {"name": name, "name_padding": padding, "named": param.showkey}
    return node("param", meta, dump_nodes(param.value))


def dump_node(n):
    if isinstance(n, nodes.Text):
        return n.value
    if isinstance(n, nodes.Template):
        name, padding = split_padding(str(n.name))
        return node(
            "template",
            {"name": name, "name_padding": padding},
            [dump_param(p) for p in n.params],
        )
    if isinstance(n, nodes.Argument):
        name, padding = split_padding(str(n.name))
        meta = {"name": name, "name_padding": padding, "default": n.default is not None}
        return node("argument", meta, dump_nodes(n.default))
    if isinstance(n, nodes.Wikilink):
        target, padding = split_padding(str(n.title))
        meta = {"target": target, "target_padding": padding, "pipe": n.text is not None}
        return node("link", meta, dump_nodes(n.text))
    if isinstance(n, nodes.ExternalLink):
        if n.title is None:
            separator = None
        else:
            separator = "" if n.suppress_space else " "
        meta = {"url": str(n.url), "brackets": n.brackets, "separator": separator}
        return node("external_link", meta, dump_nodes(n.title))
    if isinstance(n, nodes.Heading):
        return node("heading", {"level": n.level}, dump_nodes(n.title))
    if isinstance(n, nodes.Comment):
        return node("comment", {"content": n.contents})
    if isinstance(n, nodes.HTMLEntity):
        return node("entity", {"source": str(n), "char": normalized_char(n)})
    if isinstance(n, nodes.Tag):
        return dump_tag(n)
    raise TypeError(f"unknown node {type(n).__name__}")


def dump_tag(n):
    markup = n.wiki_markup
    attrs = [dump_attr(a) for a in n.attributes]
    contents = dump_nodes(n.contents) if not n.self_closing else []
    if markup == "''":
        return node("italic", {}, contents)
    if markup == "'''":
        return node("bold", {}, contents)
    if markup in ("*", "#", ";", ":"):
        return node("list_item", {"marker": markup})
    if markup and markup.startswith("----"):
        return node("hr", {"markup": markup})
    if markup in ("{|", "|-"):
        type_ = "table" if markup == "{|" else "table_row"
        return node(type_, {"attributes": attrs, "padding": n.padding}, contents)
    if markup in ("|", "||", "!", "!!"):
        meta = {
            "header": str(n.tag) == "th",
            "markup": markup,
            "attributes": attrs,
            "padding": n.padding,
            "separator": n.wiki_style_separator,
        }
        return node("table_cell", meta, contents)
    if markup:
        raise TypeError(f"unknown wiki markup {markup!r}")
    meta = {
        "tag": str(n.tag),
        "attributes": attrs,
        "self_closing": n.self_closing,
        "padding": n.padding,
        "implicit": n.implicit,
        "invalid": n.invalid,
        "closing_tag": None if n.self_closing else str(n.closing_tag),
    }
    return node("html_tag", meta, contents)


def reference(name, text):
    tokens = tokenizer().tokenize(text)
    dumped_tokens = [dump_token(t) for t in tokens]
    tree = Builder().build(tokens)
    assert str(tree) == text, f"{name}: mwparserfromhell did not round-trip"
    return {"name": name, "input": text, "tokens": dumped_tokens, "tree": dump_nodes(tree)}


def mwtest_inputs(directory):
    for path in sorted(Path(directory).glob("*.mwtest")):
        for test in path.read_text(encoding="utf8").split("\n---\n"):
            name = raw = None
            for line in test.strip().splitlines():
                if line.startswith("name:"):
                    name = line[len("name:") :].strip()
                elif line.startswith("input:"):
                    raw = line[len("input:") :].strip()
            if name is None or raw is None:
                continue
            if raw[0] == '"' and raw[-1] == '"':
                raw = raw[1:-1]
            text = raw.encode("raw_unicode_escape").decode("unicode_escape")
            yield f"{path.stem}:{name}", text


def file_inputs(directory):
    for path in sorted(Path(directory).rglob("*.wikitext")):
        yield path.name, path.read_text(encoding="utf8")


def main():
    mode, source, out = sys.argv[1:4]
    inputs = mwtest_inputs(source) if mode == "mwtest" else file_inputs(source)
    cases = [reference(name, text) for name, text in inputs]
    with open(out, "w", encoding="utf8") as fp:
        json.dump(
            {"mwparserfromhell": mwparserfromhell.__version__, "cases": cases},
            fp,
            ensure_ascii=False,
            indent=None,
        )
        fp.write("\n")
    print(f"wrote {len(cases)} cases to {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
