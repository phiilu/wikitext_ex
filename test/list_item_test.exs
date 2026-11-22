defmodule WikitextEx.ListItemTest do
  use ExUnit.Case, async: true

  test "a list item holds the rest of its line" do
    assert WikitextEx.parse!("* Chamois\n* Alpine ibex") == [
             {:list_item, %{marker: "*"}, [" Chamois"]},
             "\n",
             {:list_item, %{marker: "*"}, [" Alpine ibex"]}
           ]
  end

  test "markers in a row are one item, nested as deep as they are long" do
    assert WikitextEx.parse!("*# Early life") == [
             {:list_item, %{marker: "*#"}, [" Early life"]}
           ]
  end

  test "an item holds the markup on its line" do
    assert WikitextEx.parse!("* [[Großglockner]] {{flag|Austria}}\nnext") == [
             {:list_item, %{marker: "*"},
              [
                " ",
                {:link, %{target: "Großglockner", target_padding: {"", ""}, pipe: false}, []},
                " ",
                {:template, %{name: "flag", name_padding: {"", ""}},
                 [{:param, %{name: "1", name_padding: {"", ""}, named: false}, ["Austria"]}]}
              ]},
             "\nnext"
           ]
  end

  test "a definition term and its definition are items of their own" do
    assert WikitextEx.parse!(";Height: 3798 m") == [
             {:list_item, %{marker: ";"}, ["Height"]},
             {:list_item, %{marker: ":"}, [" 3798 m"]}
           ]
  end

  test "an item inside a template parameter holds the rest of its line there" do
    assert [{:template, _meta, [{:param, _param_meta, value}]}] =
             WikitextEx.parse!("{{Div col|\n* Chamois\n}}")

    assert value == ["\n", {:list_item, %{marker: "*"}, [" Chamois"]}, "\n"]
  end

  test "a list item writes back to its line" do
    text = "* [[Großglockner]]\n*# ''Hohe Tauern''\n;Height: 3798 m"

    assert text
           |> WikitextEx.parse!()
           |> WikitextEx.to_wikitext() == text
  end
end
