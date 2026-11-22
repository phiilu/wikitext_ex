defmodule WikitextEx.ListItemTest do
  use ExUnit.Case, async: true

  test "a list item holds the rest of its line" do
    assert WikitextEx.parse!("* Vienna\n* Salzburg") == [
             {:list_item, %{marker: "*"}, [" Vienna"]},
             "\n",
             {:list_item, %{marker: "*"}, [" Salzburg"]}
           ]
  end

  test "markers in a row are one item, nested as deep as they are long" do
    assert WikitextEx.parse!("*# Early life") == [
             {:list_item, %{marker: "*#"}, [" Early life"]}
           ]
  end

  test "an item holds the markup on its line" do
    assert WikitextEx.parse!("* [[Vienna]] {{flag|Austria}}\nnext") == [
             {:list_item, %{marker: "*"},
              [
                " ",
                {:link, %{target: "Vienna", target_padding: {"", ""}, pipe: false}, []},
                " ",
                {:template, %{name: "flag", name_padding: {"", ""}},
                 [{:param, %{name: "1", name_padding: {"", ""}, named: false}, ["Austria"]}]}
              ]},
             "\nnext"
           ]
  end

  test "a definition term and its definition are items of their own" do
    assert WikitextEx.parse!(";Born: 1756") == [
             {:list_item, %{marker: ";"}, ["Born"]},
             {:list_item, %{marker: ":"}, [" 1756"]}
           ]
  end

  test "an item inside a template parameter holds the rest of its line there" do
    assert [{:template, _meta, [{:param, _param_meta, value}]}] =
             WikitextEx.parse!("{{Div col|\n* Vienna\n}}")

    assert value == ["\n", {:list_item, %{marker: "*"}, [" Vienna"]}, "\n"]
  end

  test "a list item writes back to its line" do
    text = "* [[Vienna]]\n*# ''Ringstraße''\n;Born: 1756"

    assert text
           |> WikitextEx.parse!()
           |> WikitextEx.to_wikitext() == text
  end
end
