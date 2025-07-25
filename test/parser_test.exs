defmodule WikitextEx.ParserTest do
  use ExUnit.Case, async: true

  alias WikitextEx.{AST, Parser}

  describe "basic parsing" do
    test "parses a bare template" do
      {:ok, [ast], _, _, _, _} = Parser.parse("{{Foo|bar|baz=qux}}")
      assert ast.type == :template
      assert ast.value.name == "Foo"
      assert [{:positional, "bar"}, {:named, %{"baz" => "qux"}}] = ast.value.args
    end

    test "parses text around templates" do
      {:ok, asts, _, _, _, _} = Parser.parse("Hello {{T|X}} world")

      assert [
               %AST{type: :text, value: %AST.Text{content: "Hello "}},
               %AST{type: :template, value: %AST.Template{name: "T", args: [{:positional, "X"}]}},
               %AST{type: :text, value: %AST.Text{content: " world"}}
             ] = asts
    end

    test "parses template with nested template in argument" do
      {:ok, [ast], _, _, _, _} = Parser.parse("{{tt|Rayquaza {{Star}}|this Pokémon}}")

      assert %AST{
               type: :template,
               value: %AST.Template{
                 name: "tt",
                 args: [
                   {:positional,
                    [
                      "Rayquaza ",
                      %AST{type: :template, value: %AST.Template{name: "Star", args: []}}
                    ]},
                   {:positional, "this Pokémon"}
                 ]
               }
             } = ast
    end
  end

  describe "formatting" do
    test "parses bold text" do
      {:ok, [ast], _, _, _, _} = Parser.parse("'''bold text'''")

      assert %AST{
               type: :bold,
               children: [
                 %AST{type: :text, value: %AST.Text{content: "bold text"}}
               ]
             } = ast
    end

    test "parses italic text" do
      {:ok, [ast], _, _, _, _} = Parser.parse("''italic text''")

      assert %AST{
               type: :italic,
               children: [
                 %AST{type: :text, value: %AST.Text{content: "italic text"}}
               ]
             } = ast
    end

    test "parses bold+italic combination" do
      {:ok, [ast], _, _, _, _} = Parser.parse("'''''bold italic text'''''")

      assert %AST{
               type: :bold,
               children: [
                 %AST{
                   type: :italic,
                   children: [
                     %AST{type: :text, value: %AST.Text{content: "bold italic text"}}
                   ]
                 }
               ]
             } = ast
    end

    test "parses nested formatting with templates" do
      {:ok, [ast], _, _, _, _} = Parser.parse("'''bold {{template}} text'''")

      assert %AST{
               type: :bold,
               children: [
                 %AST{type: :text, value: %AST.Text{content: "bold "}},
                 %AST{type: :template, value: %AST.Template{name: "template", args: []}},
                 %AST{type: :text, value: %AST.Text{content: " text"}}
               ]
             } = ast
    end

    test "parses italic with templates" do
      {:ok, [ast], _, _, _, _} = Parser.parse("''italic {{template}} text''")

      assert %AST{
               type: :italic,
               children: [
                 %AST{type: :text, value: %AST.Text{content: "italic "}},
                 %AST{type: :template, value: %AST.Template{name: "template", args: []}},
                 %AST{type: :text, value: %AST.Text{content: " text"}}
               ]
             } = ast
    end

    test "parses mixed bold and italic" do
      {:ok, asts, _, _, _, _} = Parser.parse("'''bold''' and ''italic'' text")

      assert [
               %AST{
                 type: :bold,
                 children: [%AST{type: :text, value: %AST.Text{content: "bold"}}]
               },
               %AST{type: :text, value: %AST.Text{content: " and "}},
               %AST{
                 type: :italic,
                 children: [%AST{type: :text, value: %AST.Text{content: "italic"}}]
               },
               %AST{type: :text, value: %AST.Text{content: " text"}}
             ] = asts
    end

    test "handles single quotes correctly" do
      {:ok, asts, _, _, _, _} = Parser.parse("don't use this")

      # Should parse as a single continuous text node
      assert [%AST{type: :text, value: %AST.Text{content: "don't use this"}}] = asts
    end

    test "parses formatting with links" do
      {:ok, [ast], _, _, _, _} = Parser.parse("'''bold [[link]] text'''")

      assert %AST{
               type: :bold,
               children: [
                 %AST{type: :text, value: %AST.Text{content: "bold "}},
                 %AST{type: :link, value: %AST.Link{target: "link", display: "link"}},
                 %AST{type: :text, value: %AST.Text{content: " text"}}
               ]
             } = ast
    end

    test "parses bold text within italic text" do
      {:ok, [ast], _, _, _, _} = Parser.parse("''(text with '''BOLD''' word)''")

      assert %AST{
               type: :italic,
               children: [
                 %AST{type: :text, value: %AST.Text{content: "(text with "}},
                 %AST{
                   type: :bold,
                   children: [%AST{type: :text, value: %AST.Text{content: "BOLD"}}]
                 },
                 %AST{type: :text, value: %AST.Text{content: " word)"}}
               ]
             } = ast
    end

    test "parses contractions with nested formatting" do
      {:ok, [ast], _, _, _, _} = Parser.parse("''don't use '''BOLD''' words''")

      assert %AST{
               type: :italic,
               children: [
                 %AST{type: :text, value: %AST.Text{content: "don't use "}},
                 %AST{
                   type: :bold,
                   children: [%AST{type: :text, value: %AST.Text{content: "BOLD"}}]
                 },
                 %AST{type: :text, value: %AST.Text{content: " words"}}
               ]
             } = ast
    end

    test "parses bold text containing HTML tags" do
      {:ok, [ast], _, _, _, _} = Parser.parse("'''Flyinium Z<small>: Air Slash</small>'''")

      assert %AST{
               type: :bold,
               children: [
                 %AST{type: :text, value: %AST.Text{content: "Flyinium Z"}},
                 %AST{
                   type: :html_tag,
                   value: %AST.HtmlTag{
                     tag: "small",
                     attributes: %{}
                   },
                   children: [%AST{type: :text, value: %AST.Text{content: ": Air Slash"}}]
                 }
               ]
             } = ast
    end
  end

  describe "links" do
    test "parses category links" do
      {:ok, [ast], _, _, _, _} = Parser.parse("[[Category:Example Items]]")

      assert %AST{
               type: :category,
               value: %AST.Category{name: "Example Items"}
             } = ast
    end

    test "parses interlang links" do
      {:ok, [ast], _, _, _, _} =
        Parser.parse("[[de:Article Name (German Translation)]]")

      assert %AST{
               type: :interlang_link,
               value: %AST.InterlangLink{
                 lang: "de",
                 title: "Article Name (German Translation)"
               }
             } = ast
    end

    test "parses regular links without display text" do
      {:ok, [ast], _, _, _, _} = Parser.parse("[[5ban Graphics]]")

      assert %AST{
               type: :link,
               value: %AST.Link{target: "5ban Graphics", display: "5ban Graphics"}
             } = ast
    end

    test "parses regular links with display text" do
      {:ok, [ast], _, _, _, _} = Parser.parse("[[Video games|the games]]")

      assert %AST{
               type: :link,
               value: %AST.Link{target: "Video games", display: "the games"}
             } = ast
    end
  end

  describe "headers" do
    test "parses level 1-6 headers" do
      1..6
      |> Enum.map(&{&1, "#{String.duplicate("=", &1)} Level #{&1} #{String.duplicate("=", &1)}"})
      |> Enum.map(fn {level, template} -> {level, Parser.parse(template)} end)
      |> Enum.each(fn
        {level, {:ok, [ast], _, _, _, _}} ->
          expected_content = "Level #{level}"

          assert %AST{
                   type: :header,
                   value: %AST.Header{level: ^level}
                 } = ast

          # Verify content can be extracted from children
          assert AST.text_content(ast) == expected_content

        {level, {:error, _}} ->
          flunk("Failed to parse header for level #{level}")
      end)
    end

    test "parses headers with file embeddings and mixed content" do
      {:ok, [ast], _, _, _, _} =
        Parser.parse("===[[File:SetSymbolPromo.png|40px]] Black Star Promotional Cards===")

      # Should parse header with children containing the file and text
      assert %AST{
               type: :header,
               value: %AST.Header{level: 3},
               children: [
                 %AST{
                   type: :file,
                   value: %AST.File{name: "SetSymbolPromo.png", parameters: ["40px"]}
                 },
                 %AST{type: :text, value: %AST.Text{content: " Black Star Promotional Cards"}}
               ]
             } = ast

      # Verify content extraction works correctly
      assert AST.text_content(ast) == "Black Star Promotional Cards"
    end

    test "header children should allow text extraction for series grouping" do
      {:ok, [ast], _, _, _, _} =
        Parser.parse("===[[File:SetSymbolPromo.png|40px]] Black Star Promotional Cards===")

      # The children should contain parsed nodes that allow extracting just the text
      # Filter for text nodes and get their content
      text_nodes = Enum.filter(ast.children, &(&1.type == :text))
      assert length(text_nodes) == 1
      assert hd(text_nodes).value.content == " Black Star Promotional Cards"

      # Verify the helper function extracts clean text content
      assert AST.text_content(ast) == "Black Star Promotional Cards"
    end

    test "header with templates and links extracts text correctly" do
      {:ok, [ast], _, _, _, _} =
        Parser.parse("===See also {{Topic|Template}} and [[Link]]====")

      # Should have text, template, and link children
      # "See also ", template, " and ", link
      assert length(ast.children) == 4

      # Should extract just the text parts
      assert AST.text_content(ast) == "See also  and"
    end
  end

  describe "templates" do
    test "preserves spaces around templates in template arguments" do
      template = "{{TestTemplate|effect=text before {{e|Fire}} text after}}"

      {:ok, [ast], _, _, _, _} = Parser.parse(template)

      assert %AST{
               type: :template,
               value: %AST.Template{
                 name: "TestTemplate",
                 args: [
                   {:named,
                    %{
                      "effect" => [
                        "text before ",
                        %AST{
                          type: :template,
                          value: %AST.Template{name: "e", args: [{:positional, "Fire"}]}
                        },
                        " text after"
                      ]
                    }}
                 ]
               }
             } = ast
    end

    test "preserves spaces in complex template arguments with multiple templates" do
      template =
        "{{Ability|effect=During the next turn, prevent all damage done to this character by attacks from Basic non-{{e|Neutral}} characters.}}"

      {:ok, [ast], _, _, _, _} = Parser.parse(template)

      effect_value =
        get_in(ast, [
          Access.key(:value),
          Access.key(:args),
          Access.at(0),
          Access.elem(1),
          Access.key("effect")
        ])

      assert [
               "During the next turn, prevent all damage done to this character by attacks from Basic non-",
               %AST{
                 type: :template,
                 value: %AST.Template{name: "e", args: [{:positional, "Neutral"}]}
               },
               " characters."
             ] = effect_value
    end
  end

  describe "complex content" do
    test "parses complex character description with formatting" do
      template =
        "'''Hero{{ex}}''' (Translation: '''ヒーローex''' ''Hero ex'') is a {{ct|Neutral}} Basic {{Game|Character ex}} card."

      {:ok, asts, _, _, _, _} = Parser.parse(template)

      # Should have bold text with template, then regular text, then another bold section, etc.
      assert length(asts) > 5

      # First element should be bold with Hero and ex template
      first_ast = List.first(asts)

      assert %AST{
               type: :bold,
               children: [
                 %AST{type: :text, value: %AST.Text{content: "Hero"}},
                 %AST{type: :template, value: %AST.Template{name: "ex", args: []}}
               ]
             } = first_ast
    end

    test "parses formatting within complex template arguments" do
      template =
        "{{GameText|effect=Draw 2 cards. If your opponent has '''3 or fewer''' points remaining, draw ''2 more'' cards.}}"

      {:ok, [ast], _, _, _, _} = Parser.parse(template)

      # The effect argument should contain the formatting as AST nodes
      effect_value =
        get_in(ast, [
          Access.key(:value),
          Access.key(:args),
          Access.at(0),
          Access.elem(1),
          Access.key("effect")
        ])

      # Should be a list containing text and formatting AST nodes
      assert is_list(effect_value)

      # Should contain text, bold formatting, more text, italic formatting, and final text
      assert [
               "Draw 2 cards. If your opponent has ",
               %AST{
                 type: :bold,
                 children: [%AST{type: :text, value: %AST.Text{content: "3 or fewer"}}]
               },
               " points remaining, draw ",
               %AST{
                 type: :italic,
                 children: [%AST{type: :text, value: %AST.Text{content: "2 more"}}]
               },
               " cards."
             ] = effect_value
    end
  end

  describe "edge cases" do
    test "handles empty bold formatting" do
      {:ok, asts, _, _, _, _} = Parser.parse("''''''")

      # Should parse as bold+italic with empty content
      case asts do
        [%AST{type: :bold, children: [%AST{type: :italic, children: []}]}] ->
          # Correct bold+italic parsing
          :ok

        [%AST{type: :bold, children: []}] ->
          # Just bold parsing - also acceptable
          :ok

        [] ->
          # Empty result - acceptable for edge case
          :ok
      end
    end

    test "handles unmatched formatting gracefully" do
      # This should be treated as regular text since bold isn't closed
      result = Parser.parse("'''unmatched bold")

      # Should either parse as text or fail gracefully
      case result do
        {:ok, [%AST{type: :text, value: %AST.Text{content: "'''unmatched bold"}}], _, _, _, _} ->
          # Successfully parsed as text
          :ok

        {:error, _, _, _, _, _} ->
          # Parser failed to match - this is also acceptable behavior
          :ok

        {:ok, [], _, _, _, _} ->
          # Parser consumed input but produced no output - also acceptable
          :ok
      end
    end

    test "handles nested single quotes in text" do
      {:ok, asts, _, _, _, _} = Parser.parse("don't worry about 'quotes'")

      # Should parse as a single continuous text node
      assert [%AST{type: :text, value: %AST.Text{content: "don't worry about 'quotes'"}}] = asts
    end
  end

  describe "real wikitext fixtures" do
    test "parses character ex wikitext with spaced formatting" do
      # Test a portion of character wikitext file that has different formatting (with spaces around parameters)
      character_template = """
      {{CharacterInfobox
       | cardname      = Hero
       | jname         = ヒーローEX
       | jtrans        = Hero EX
       | species       = Hero
       | evostage      = AdvancedEX
       | type          = Neutral
       | hp            = 240
       | weakness      = Fire
       | retreatcost   = 4
       | class         = AdvancedEX
      }}
      """

      {:ok, asts, _, _, _, _} = Parser.parse(character_template)

      # Should parse template and newline - extract the template
      template_ast = Enum.find(asts, &(&1.type == :template))

      # Should parse the same as compact formatting - whitespace differences should be normalized
      assert %AST{
               type: :template,
               value: %AST.Template{
                 name: "CharacterInfobox",
                 args: [
                   named: %{"cardname" => "Hero"},
                   named: %{"jname" => "ヒーローEX"},
                   named: %{"jtrans" => "Hero EX"},
                   named: %{"species" => "Hero"},
                   named: %{"evostage" => "AdvancedEX"},
                   named: %{"type" => "Neutral"},
                   named: %{"hp" => "240"},
                   named: %{"weakness" => "Fire"},
                   named: %{"retreatcost" => "4"},
                   named: %{"class" => "AdvancedEX"}
                 ]
               }
             } = template_ast
    end
  end

  describe "complex template structures" do
    test "parses complex wikitext with nested templates and mixed content" do
      wikitext = """
      {{CharacterInfobox
      |cardname=Test Character
      |caption={{Game|Stellar Edition}}<br>Regular print<br>Illus. [[Example Graphics]]
      |expansion={{Game|Test Set}}
      |rarity={{rar|Rare}}
      }}
      {{Cardtext/Ability
      |name=Test Ability
      |cost={{e|Fire}}{{e|Water}}
      |damage=120
      |effect=Discard all Energy from {{tt|Test Character {{Star}}|this character}}.
      }}
      """

      {:ok, asts, _, _, _, _} = Parser.parse(wikitext)

      # Should have multiple AST nodes: template, text, template, text
      assert length(asts) == 4

      # First template should be CharacterInfobox
      [infobox_ast, _, ability_ast, _] = asts

      assert %AST{
               type: :template,
               value: %AST.Template{
                 name: "CharacterInfobox",
                 args: infobox_args
               }
             } = infobox_ast

      # Convert args to map for easier testing
      infobox_map =
        Enum.reduce(infobox_args, %{}, fn
          {:named, map}, acc -> Map.merge(acc, map)
          _, acc -> acc
        end)

      # Verify key fields are parsed correctly
      assert infobox_map["cardname"] == "Test Character"

      # Verify complex nested structure in caption (templates + HTML tags + links + text)
      assert [
               %AST{type: :template, value: %AST.Template{name: "Game"}},
               %AST{type: :html_tag, value: %AST.HtmlTag{tag: "br"}},
               "Regular print",
               %AST{type: :html_tag, value: %AST.HtmlTag{tag: "br"}},
               "Illus. ",
               %AST{type: :link, value: %AST.Link{target: "Example Graphics"}}
             ] = infobox_map["caption"]

      # Verify ability template
      assert %AST{
               type: :template,
               value: %AST.Template{name: "Cardtext/Ability", args: ability_args}
             } = ability_ast

      ability_map =
        Enum.reduce(ability_args, %{}, fn
          {:named, map}, acc -> Map.merge(acc, map)
          _, acc -> acc
        end)

      assert ability_map["name"] == "Test Ability"
      assert ability_map["damage"] == "120"

      # Verify nested template in effect text (the critical nested template case)
      effect_content = ability_map["effect"]
      assert is_list(effect_content)

      assert Enum.any?(effect_content, fn item ->
               match?(%AST{type: :template, value: %AST.Template{name: "tt"}}, item)
             end)
    end
  end

  describe "HTML tags" do
    test "parses br tags" do
      {:ok, asts, _, _, _, _} = Parser.parse("Line 1<br>Line 2")

      assert [
               %AST{type: :text, value: %AST.Text{content: "Line 1"}},
               %AST{
                 type: :html_tag,
                 value: %AST.HtmlTag{tag: "br", attributes: %{}},
                 children: []
               },
               %AST{type: :text, value: %AST.Text{content: "Line 2"}}
             ] = asts
    end

    test "parses br tags with attributes" do
      {:ok, asts, _, _, _, _} = Parser.parse(~s(Text<br class="clear">More text))

      assert [
               %AST{type: :text, value: %AST.Text{content: "Text"}},
               %AST{
                 type: :html_tag,
                 value: %AST.HtmlTag{tag: "br", attributes: %{"class" => "clear"}},
                 children: []
               },
               %AST{type: :text, value: %AST.Text{content: "More text"}}
             ] = asts
    end

    test "parses span tags with content" do
      {:ok, asts, _, _, _, _} = Parser.parse("Text with <span>content</span> here")

      assert [
               %AST{type: :text, value: %AST.Text{content: "Text with "}},
               %AST{
                 type: :html_tag,
                 value: %AST.HtmlTag{tag: "span", attributes: %{}},
                 children: [%AST{type: :text, value: %AST.Text{content: "content"}}]
               },
               %AST{type: :text, value: %AST.Text{content: " here"}}
             ] = asts
    end

    test "parses div tags with nested content" do
      {:ok, asts, _, _, _, _} =
        Parser.parse(~s(Before<div class="box">Text with '''bold''' content</div>After))

      assert [
               %AST{type: :text, value: %AST.Text{content: "Before"}},
               %AST{
                 type: :html_tag,
                 value: %AST.HtmlTag{tag: "div", attributes: %{"class" => "box"}},
                 children: [
                   %AST{type: :text, value: %AST.Text{content: "Text with "}},
                   %AST{
                     type: :bold,
                     children: [%AST{type: :text, value: %AST.Text{content: "bold"}}]
                   },
                   %AST{type: :text, value: %AST.Text{content: " content"}}
                 ]
               },
               %AST{type: :text, value: %AST.Text{content: "After"}}
             ] = asts
    end

    test "parses multiple br tags in template argument (real example)" do
      {:ok, asts, _, _, _, _} =
        Parser.parse("{{Game|Stellar Edition}}<br>Regular print<br>Illus. [[Example Graphics]]")

      assert [
               %AST{
                 type: :template,
                 value: %AST.Template{name: "Game", args: [positional: "Stellar Edition"]}
               },
               %AST{
                 type: :html_tag,
                 value: %AST.HtmlTag{tag: "br", attributes: %{}},
                 children: []
               },
               %AST{type: :text, value: %AST.Text{content: "Regular print"}},
               %AST{
                 type: :html_tag,
                 value: %AST.HtmlTag{tag: "br", attributes: %{}},
                 children: []
               },
               %AST{type: :text, value: %AST.Text{content: "Illus. "}},
               %AST{
                 type: :link,
                 value: %AST.Link{target: "Example Graphics", display: "Example Graphics"}
               }
             ] = asts
    end

    test "parses small tags with content (GX attack case)" do
      {:ok, asts, _, _, _, _} =
        Parser.parse(
          "This attack does 40 damage for each Prize card. <small>(You can't use more than 1 GX attack in a game.)</small>"
        )

      assert [
               %AST{
                 type: :text,
                 value: %AST.Text{content: "This attack does 40 damage for each Prize card. "}
               },
               %AST{
                 type: :html_tag,
                 value: %AST.HtmlTag{tag: "small", attributes: %{}},
                 children: [
                   %AST{
                     type: :text,
                     value: %AST.Text{content: "(You can't use more than 1 GX attack in a game.)"}
                   }
                 ]
               }
             ] = asts
    end
  end

  describe "lists" do
    test "parses unordered list items" do
      {:ok, asts, _, _, _, _} = Parser.parse("* First item\n* Second item")

      assert [
               %AST{
                 type: :list_item,
                 value: %AST.ListItem{type: :unordered, level: 1},
                 children: [%AST{type: :text, value: %AST.Text{content: "First item"}}]
               },
               %AST{type: :text, value: %AST.Text{content: "\n"}},
               %AST{
                 type: :list_item,
                 value: %AST.ListItem{type: :unordered, level: 1},
                 children: [%AST{type: :text, value: %AST.Text{content: "Second item"}}]
               }
             ] = asts
    end

    test "parses ordered list items" do
      {:ok, asts, _, _, _, _} = Parser.parse("# First item\n# Second item")

      assert [
               %AST{
                 type: :list_item,
                 value: %AST.ListItem{type: :ordered, level: 1},
                 children: [%AST{type: :text, value: %AST.Text{content: "First item"}}]
               },
               %AST{type: :text, value: %AST.Text{content: "\n"}},
               %AST{
                 type: :list_item,
                 value: %AST.ListItem{type: :ordered, level: 1},
                 children: [%AST{type: :text, value: %AST.Text{content: "Second item"}}]
               }
             ] = asts
    end

    test "parses nested lists" do
      {:ok, asts, _, _, _, _} = Parser.parse("* Item 1\n** Nested item\n* Item 2")

      assert [
               %AST{
                 type: :list_item,
                 value: %AST.ListItem{type: :unordered, level: 1},
                 children: [%AST{type: :text, value: %AST.Text{content: "Item 1"}}]
               },
               %AST{type: :text, value: %AST.Text{content: "\n"}},
               %AST{
                 type: :list_item,
                 value: %AST.ListItem{type: :unordered, level: 2},
                 children: [%AST{type: :text, value: %AST.Text{content: "Nested item"}}]
               },
               %AST{type: :text, value: %AST.Text{content: "\n"}},
               %AST{
                 type: :list_item,
                 value: %AST.ListItem{type: :unordered, level: 1},
                 children: [%AST{type: :text, value: %AST.Text{content: "Item 2"}}]
               }
             ] = asts
    end

    test "parses list items with formatting" do
      {:ok, asts, _, _, _, _} = Parser.parse("* '''Bold''' item with [[link]]")

      assert [
               %AST{
                 type: :list_item,
                 value: %AST.ListItem{type: :unordered, level: 1},
                 children: [
                   %AST{
                     type: :bold,
                     children: [%AST{type: :text, value: %AST.Text{content: "Bold"}}]
                   },
                   %AST{type: :text, value: %AST.Text{content: " item with "}},
                   %AST{type: :link, value: %AST.Link{target: "link", display: "link"}}
                 ]
               }
             ] = asts
    end
  end

  describe "comments" do
    test "parses HTML comments" do
      {:ok, asts, _, _, _, _} = Parser.parse("Text <!-- this is a comment --> more text")

      assert [
               %AST{type: :text, value: %AST.Text{content: "Text "}},
               %AST{type: :comment, value: %AST.Comment{content: " this is a comment "}},
               %AST{type: :text, value: %AST.Text{content: " more text"}}
             ] = asts
    end

    test "parses multiline comments" do
      {:ok, asts, _, _, _, _} = Parser.parse("Before<!--\nMultiline\ncomment\n-->After")

      assert [
               %AST{type: :text, value: %AST.Text{content: "Before"}},
               %AST{type: :comment, value: %AST.Comment{content: "\nMultiline\ncomment\n"}},
               %AST{type: :text, value: %AST.Text{content: "After"}}
             ] = asts
    end

    test "parses empty comments" do
      {:ok, asts, _, _, _, _} = Parser.parse("Text<!---->more")

      assert [
               %AST{type: :text, value: %AST.Text{content: "Text"}},
               %AST{type: :comment, value: %AST.Comment{content: ""}},
               %AST{type: :text, value: %AST.Text{content: "more"}}
             ] = asts
    end
  end

  describe "special tags" do
    test "parses ref tags" do
      {:ok, asts, _, _, _, _} = Parser.parse("Text with reference<ref>Source info</ref> here")

      assert [
               %AST{type: :text, value: %AST.Text{content: "Text with reference"}},
               %AST{
                 type: :ref,
                 value: %AST.Ref{name: nil, group: nil},
                 children: [%AST{type: :text, value: %AST.Text{content: "Source info"}}]
               },
               %AST{type: :text, value: %AST.Text{content: " here"}}
             ] = asts
    end

    test "parses ref tags with name attribute" do
      {:ok, asts, _, _, _, _} = Parser.parse(~s(Text<ref name="source1">Citation</ref>))

      assert [
               %AST{type: :text, value: %AST.Text{content: "Text"}},
               %AST{
                 type: :ref,
                 value: %AST.Ref{name: "source1", group: nil},
                 children: [%AST{type: :text, value: %AST.Text{content: "Citation"}}]
               }
             ] = asts
    end

    test "parses ref tags with group attribute" do
      {:ok, asts, _, _, _, _} = Parser.parse(~s(Text<ref group="notes">Note content</ref>))

      assert [
               %AST{type: :text, value: %AST.Text{content: "Text"}},
               %AST{
                 type: :ref,
                 value: %AST.Ref{name: nil, group: "notes"},
                 children: [%AST{type: :text, value: %AST.Text{content: "Note content"}}]
               }
             ] = asts
    end

    test "parses ref tags with both name and group" do
      {:ok, asts, _, _, _, _} =
        Parser.parse(~s(Text<ref name="citation1" group="notes">Citation</ref>))

      assert [
               %AST{type: :text, value: %AST.Text{content: "Text"}},
               %AST{
                 type: :ref,
                 value: %AST.Ref{name: "citation1", group: "notes"},
                 children: [%AST{type: :text, value: %AST.Text{content: "Citation"}}]
               }
             ] = asts
    end

    test "parses self-closing ref tags" do
      {:ok, asts, _, _, _, _} = Parser.parse(~s(Text<ref name="source1" /> more text))

      assert [
               %AST{type: :text, value: %AST.Text{content: "Text"}},
               %AST{type: :ref, value: %AST.Ref{name: "source1", group: nil}, children: []},
               %AST{type: :text, value: %AST.Text{content: " more text"}}
             ] = asts
    end

    test "parses nowiki tags" do
      {:ok, asts, _, _, _, _} =
        Parser.parse("Normal text <nowiki>'''not bold''' [[not link]]</nowiki> normal again")

      assert [
               %AST{type: :text, value: %AST.Text{content: "Normal text "}},
               %AST{type: :nowiki, value: %AST.Nowiki{content: "'''not bold''' [[not link]]"}},
               %AST{type: :text, value: %AST.Text{content: " normal again"}}
             ] = asts
    end
  end
end
