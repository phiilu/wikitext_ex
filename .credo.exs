%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["bench/", "lib/", "test/", "credo_checks/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      plugins: [{ExDNA.Credo, []}, {ExSlop, []}],
      requires: ["./credo_checks/**/*.ex"],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled:
          [
            ## Consistency Checks
            {Credo.Check.Consistency.ExceptionNames, []},
            {Credo.Check.Consistency.LineEndings, []},
            {Credo.Check.Consistency.ParameterPatternMatching, []},
            {Credo.Check.Consistency.SpaceAroundOperators, []},
            {Credo.Check.Consistency.SpaceInParentheses, []},
            {Credo.Check.Consistency.TabsOrSpaces, []},
            {Credo.Check.Consistency.UnusedVariableNames, [force: :meaningful]},

            ## Design Checks
            {Credo.Check.Design.AliasUsage,
             [if_nested_deeper_than: 2, if_called_more_often_than: 2]},
            {Credo.Check.Design.SkipTestWithoutComment, []},
            {Credo.Check.Design.TagFIXME, []},
            {Credo.Check.Design.TagTODO, [exit_status: 2]},

            ## Readability Checks
            {Credo.Check.Readability.AliasAs, []},
            {Credo.Check.Readability.AliasOrder, []},
            {Credo.Check.Readability.FunctionNames, []},
            {Credo.Check.Readability.ImplTrue, []},
            {Credo.Check.Readability.LargeNumbers, []},
            {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
            {Credo.Check.Readability.ModuleAttributeNames, []},
            {Credo.Check.Readability.ModuleDoc, []},
            {Credo.Check.Readability.ModuleNames, []},
            {Credo.Check.Readability.MultiAlias, []},
            {Credo.Check.Readability.NestedFunctionCalls, []},
            {Credo.Check.Readability.OneArityFunctionInPipe, []},
            {Credo.Check.Readability.OnePipePerLine, []},
            {Credo.Check.Readability.ParenthesesInCondition, []},
            {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
            {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
            {Credo.Check.Readability.PredicateFunctionNames, []},
            {Credo.Check.Readability.PreferImplicitTry, []},
            {Credo.Check.Readability.RedundantBlankLines, []},
            {Credo.Check.Readability.Semicolons, []},
            {Credo.Check.Readability.SeparateAliasRequire, []},
            {Credo.Check.Readability.SinglePipe, []},
            {Credo.Check.Readability.SpaceAfterCommas, []},
            {Credo.Check.Readability.Specs, [files: %{excluded: ["test/**"]}]},
            {Credo.Check.Readability.StrictModuleLayout,
             [
               order:
                 ~w(moduledoc behaviour use import require alias shortdoc module_attribute defstruct type typep opaque callback macrocallback optional_callbacks module public_fun public_macro callback_impl private_fun private_macro)a,
               # A guard has to come before the functions using it.
               ignore: ~w(module public_guard private_guard)a
             ]},
            {Credo.Check.Readability.TrailingBlankLine, []},
            {Credo.Check.Readability.TrailingWhiteSpace, []},
            {Credo.Check.Readability.VariableNames, []},
            {WikitextEx.Checks.SingleLetterVariable, []},
            {Credo.Check.Readability.WithCustomTaggedTuple, []},
            {Credo.Check.Readability.WithSingleClause, []},

            ## Refactoring Opportunities
            {Credo.Check.Refactor.ABCSize, [max_size: 35]},
            {Credo.Check.Refactor.AppendSingleItem, []},
            {Credo.Check.Refactor.Apply, []},
            {Credo.Check.Refactor.CaseTrivialMatches, []},
            {Credo.Check.Refactor.CondStatements, []},
            {Credo.Check.Refactor.CyclomaticComplexity, []},
            {Credo.Check.Refactor.DoubleBooleanNegation, []},
            {Credo.Check.Refactor.FilterCount, []},
            {Credo.Check.Refactor.FilterFilter, []},
            {Credo.Check.Refactor.FilterReject, []},
            {Credo.Check.Refactor.FunctionArity, []},
            {Credo.Check.Refactor.IoPuts, [files: %{excluded: [~r"/test/"]}]},
            {Credo.Check.Refactor.LongQuoteBlocks, []},
            {Credo.Check.Refactor.MapJoin, []},
            {Credo.Check.Refactor.MapMap, []},
            {Credo.Check.Refactor.MatchInCondition, []},
            {Credo.Check.Refactor.ModuleDependencies,
             [max_deps: 18, dependency_namespaces: ["WikitextEx"]]},
            {Credo.Check.Refactor.NegatedConditionsInUnless, []},
            {Credo.Check.Refactor.NegatedConditionsWithElse, []},
            {Credo.Check.Refactor.NegatedIsNil, []},
            {Credo.Check.Refactor.Nesting, []},
            {Credo.Check.Refactor.PassAsyncInTestCases, []},
            {Credo.Check.Refactor.PipeChainStart, []},
            {Credo.Check.Refactor.RedundantWithClauseResult, []},
            {Credo.Check.Refactor.RejectFilter, []},
            {Credo.Check.Refactor.RejectReject, []},
            {Credo.Check.Refactor.UnlessWithElse, []},
            {Credo.Check.Refactor.UtcNowTruncate, []},
            {Credo.Check.Refactor.VariableRebinding, []},
            {Credo.Check.Refactor.WithClauses, []},

            ## Warnings
            {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
            {Credo.Check.Warning.BoolOperationOnSameValues, []},
            {Credo.Check.Warning.Dbg, []},
            {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
            {Credo.Check.Warning.IExPry, []},
            {Credo.Check.Warning.IoInspect, []},
            {Credo.Check.Warning.LeakyEnvironment, []},
            {Credo.Check.Warning.MapGetUnsafePass, []},
            {Credo.Check.Warning.MixEnv, []},
            {Credo.Check.Warning.OperationOnSameValues, []},
            {Credo.Check.Warning.OperationWithConstantResult, []},
            {Credo.Check.Warning.RaiseInsideRescue, []},
            {Credo.Check.Warning.SpecWithStruct, []},
            {Credo.Check.Warning.UnsafeExec, []},
            {Credo.Check.Warning.UnsafeToAtom, []},
            {Credo.Check.Warning.UnusedEnumOperation, []},
            {Credo.Check.Warning.UnusedFileOperation, []},
            {Credo.Check.Warning.UnusedKeywordOperation, []},
            {Credo.Check.Warning.UnusedListOperation, []},
            {Credo.Check.Warning.UnusedMapOperation, []},
            {Credo.Check.Warning.UnusedPathOperation, []},
            {Credo.Check.Warning.UnusedRegexOperation, []},
            {Credo.Check.Warning.UnusedStringOperation, []},
            {Credo.Check.Warning.UnusedTupleOperation, []},
            {Credo.Check.Warning.WrongTestFileExtension, []}
          ] ++
            Enum.map(ExSlop.recommended_checks(), &{&1, []}) ++
            [
              {ExSlop.Check.Refactor.CaseTrueFalse, []},
              {ExSlop.Check.Refactor.LengthInGuard, []},
              {ExSlop.Check.Refactor.ListFold, []},
              {ExSlop.Check.Refactor.PreferEnumSlice, []},
              {ExSlop.Check.Refactor.UseMapJoin, []},
              {ExSlop.Check.Readability.DocFalseOnPublicFunction, [min_count: 1]},
              {ExSlop.Check.Readability.ObviousComment, []},
              {ExSlop.Check.Readability.StepComment, []},
              {ExSlop.Check.Readability.UnaliasedModuleUse, []},
              {CredoUnnecessaryReduce.Check, []},
              {Jump.CredoChecks.AssertReceiveTimeout, [min_assert_receive_timeout: 5_000]},
              {Jump.CredoChecks.AvoidFunctionLevelElse, []},
              {Jump.CredoChecks.ConditionalAssertion, []},
              {Jump.CredoChecks.DoctestIExExamples, []},
              {Jump.CredoChecks.NoWordSigilInterpolation, []},
              {Jump.CredoChecks.SafeBinaryToTerm, []},
              {Jump.CredoChecks.TestHasNoAssertions, []},
              {Jump.CredoChecks.TooManyAssertions, []},
              {Jump.CredoChecks.TopLevelAliasImportRequire, []},
              {Jump.CredoChecks.UndeclaredExternalResource, []},
              {Jump.CredoChecks.VacuousTest, []},
              {Jump.CredoChecks.WeakAssertion, []}
            ],
        disabled: [
          # Quokka handles individual alias lines via MultiAlias
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Refactor.MapInto, []},
          {Credo.Check.Warning.LazyLogging, []}
        ]
      }
    }
  ]
}
