# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "mwparserfromhell==0.7.2",
# ]
# ///
"""
Generate reference output from mwparserfromhell for WikitextEx's conformance tests.

For every input it records the token stream mwparserfromhell's tokenizer emits and
the node tree its builder produces, the tree written in WikitextEx's AST shape
(before WikitextEx groups list items). The Elixir tests compare against this file.

Inputs are either mwparserfromhell's own tokenizer suite (`.mwtest` files, only the
`input:` lines are read) or a directory of `.wikitext` files.

The mise tasks `reference:suite`, `reference:edge-cases` and `corpus` run it
through uv, on the mwparserfromhell version pinned above:

    uv run scripts/mwph_reference.py mwtest path/to/mwparserfromhell/tests/tokenizer out.json
    uv run scripts/mwph_reference.py files path/to/wikitext_dir out.json

Set MWPH_TOKENIZER=python to use the pure-Python tokenizer instead of the C one.
"""

import json
import os
import sys
from pathlib import Path

from mwparserfromhell import nodes
from mwparserfromhell.nodes.extras import Parameter
from mwparserfromhell.parser.builder import Builder


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
    attrs = dict(token)
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


def dump_node(wiki_node):
    if isinstance(wiki_node, nodes.Text):
        return wiki_node.value
    if isinstance(wiki_node, nodes.Template):
        name, padding = split_padding(str(wiki_node.name))
        return node(
            "template",
            {"name": name, "name_padding": padding},
            [dump_param(param) for param in wiki_node.params],
        )
    if isinstance(wiki_node, nodes.Argument):
        name, padding = split_padding(str(wiki_node.name))
        meta = {"name": name, "name_padding": padding, "default": wiki_node.default is not None}
        return node("argument", meta, dump_nodes(wiki_node.default))
    if isinstance(wiki_node, nodes.Wikilink):
        target, padding = split_padding(str(wiki_node.title))
        meta = {"target": target, "target_padding": padding, "pipe": wiki_node.text is not None}
        return node("link", meta, dump_nodes(wiki_node.text))
    if isinstance(wiki_node, nodes.ExternalLink):
        if wiki_node.title is None:
            separator = None
        else:
            separator = "" if wiki_node.suppress_space else " "
        meta = {"url": str(wiki_node.url), "brackets": wiki_node.brackets, "separator": separator}
        return node("external_link", meta, dump_nodes(wiki_node.title))
    if isinstance(wiki_node, nodes.Heading):
        return node("heading", {"level": wiki_node.level}, dump_nodes(wiki_node.title))
    if isinstance(wiki_node, nodes.Comment):
        return node("comment", {"content": wiki_node.contents})
    if isinstance(wiki_node, nodes.HTMLEntity):
        return node("entity", {"source": str(wiki_node), "char": normalized_char(wiki_node)})
    if isinstance(wiki_node, nodes.Tag):
        return dump_tag(wiki_node)
    raise TypeError(f"unknown node {type(wiki_node).__name__}")


def dump_tag(tag):
    markup = tag.wiki_markup
    attrs = [dump_attr(attr) for attr in tag.attributes]
    contents = dump_nodes(tag.contents) if not tag.self_closing else []
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
        return node(type_, {"attributes": attrs, "padding": tag.padding}, contents)
    if markup in ("|", "||", "!", "!!"):
        meta = {
            "header": str(tag.tag) == "th",
            "markup": markup,
            "attributes": attrs,
            "padding": tag.padding,
            "separator": tag.wiki_style_separator,
        }
        return node("table_cell", meta, contents)
    if markup:
        raise TypeError(f"unknown wiki markup {markup!r}")
    meta = {
        "tag": str(tag.tag),
        "attributes": attrs,
        "self_closing": tag.self_closing,
        "padding": tag.padding,
        "implicit": tag.implicit,
        "invalid": tag.invalid,
        "closing_tag": None if tag.self_closing else str(tag.closing_tag),
    }
    return node("html_tag", meta, contents)


def reference(name, text):
    tokens = tokenizer().tokenize(text)
    dumped_tokens = [dump_token(token) for token in tokens]
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
            {"cases": cases},
            fp,
            ensure_ascii=False,
            indent=None,
        )
        fp.write("\n")
    print(f"wrote {len(cases)} cases to {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
