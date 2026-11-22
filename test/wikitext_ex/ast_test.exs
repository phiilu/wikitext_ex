defmodule WikitextEx.ASTTest do
  use ExUnit.Case, async: true

  alias WikitextEx.AST

  doctest AST

  @page "{{Speciesbox|name={{lang|de|Alpenmurmeltier}}}} and ''{{sfn|Huber|2019}}''"

  describe "prewalk/3" do
    test "visits every node before its children, template parameters included" do
      {_nodes, names} =
        @page
        |> WikitextEx.parse!()
        |> AST.prewalk([], fn
          {:template, %{name: name}, _params} = node, names -> {node, [name | names]}
          node, names -> {node, names}
        end)

      assert Enum.reverse(names) == ["Speciesbox", "lang", "sfn"]
    end
  end

  describe "postwalk/2" do
    test "rewrites nodes after their children" do
      nodes =
        "''[[Main Page]]''"
        |> WikitextEx.parse!()
        |> AST.postwalk(fn
          {:link, %{target: target}, _text} -> target
          node -> node
        end)

      assert nodes == [{:italic, %{}, ["Main Page"]}]
    end
  end

  test "Macro.prewalk/3 walks the tree as well" do
    {_nodes, count} =
      @page
      |> WikitextEx.parse!()
      |> Macro.prewalk(0, fn
        {:template, _meta, _params} = node, count -> {node, count + 1}
        node, count -> {node, count}
      end)

    assert count == 3
  end

  describe "filter/2" do
    test "finds nodes anywhere in the tree, in document order" do
      templates =
        @page
        |> WikitextEx.parse!()
        |> AST.filter(&match?({:template, _meta, _params}, &1))

      assert Enum.map(templates, fn {:template, %{name: name}, _params} -> name end) ==
               ["Speciesbox", "lang", "sfn"]
    end
  end

  describe "text/1" do
    test "is what a reader sees: link text, entities as characters, no templates or comments" do
      nodes =
        WikitextEx.parse!(
          "'''[[Rupicapra rupicapra|Chamois]]''' &amp; {{cite book|title=Fauna of the Alps}}<!-- note --> [http://x.org site]"
        )

      assert AST.text(nodes) == "Chamois &  site"
    end

    test "is a link's target when it has no text" do
      assert "[[Großglockner]] [[Category:Mountains of Austria]]"
             |> WikitextEx.parse!()
             |> AST.text() ==
               "Großglockner Category:Mountains of Austria"
    end
  end

  describe "attributes/1" do
    test "are a tag's attributes by lowercase name, the last of a name winning" do
      [tag] = WikitextEx.parse!(~s(<span class="a" CLASS='b' hidden>x</span>))

      assert AST.attributes(tag) == %{"class" => "b", "hidden" => ""}
    end

    test "are a table cell's attributes too" do
      [{:table, _meta, [cell | _cells]}] = WikitextEx.parse!(~s({|\n| style="color:red" | x\n|}))

      assert AST.attributes(cell) == %{"style" => "color:red"}
    end
  end
end
