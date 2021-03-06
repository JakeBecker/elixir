Code.require_file "../test_helper.exs", __DIR__

defmodule Mix.UmbrellaTest do
  use MixTest.Case

  @moduletag apps: [:foo, :bar]

  test "apps_paths" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      assert Mix.Project.apps_paths == nil
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        assert Mix.Project.apps_paths ==
               %{bar: "apps/bar", foo: "apps/foo"}
      end)
    end
  end

  test "apps_paths with selection" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", [apps: [:foo, :bar]], fn _ ->
        File.mkdir_p! "apps/errors"
        File.write! "apps/errors/mix.exs", "raise :oops"
        assert Mix.Project.apps_paths ==
               %{bar: "apps/bar", foo: "apps/foo"}
      end)
    end
  end

  test "compiles umbrella" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        Mix.Task.run "deps"
        assert_received {:mix_shell, :info, ["* bar (apps/bar) (mix)"]}
        assert_received {:mix_shell, :info, ["* foo (apps/foo) (mix)"]}

        # Ensure we can compile and run checks
        Mix.Task.run "deps.compile"
        Mix.Task.run "deps.loadpaths"
        Mix.Task.run "compile", ["--verbose"]

        assert_received {:mix_shell, :info, ["==> bar"]}
        assert_received {:mix_shell, :info, ["Generated bar app"]}
        assert File.regular?("_build/dev/lib/bar/ebin/Elixir.Bar.beam")
        assert_received {:mix_shell, :info, ["==> foo"]}
        assert_received {:mix_shell, :info, ["Generated foo app"]}
        assert File.regular?("_build/dev/lib/foo/ebin/Elixir.Foo.beam")

        # Ensure foo was loaded and in the same env as Mix.env
        assert_received {:mix_shell, :info, [":foo env is dev"]}
        assert_received {:mix_shell, :info, [":bar env is dev"]}

        Mix.Task.clear
        Mix.Task.run "app.start", ["--no-compile"]
      end)
    end
  end

  test "compiles umbrella with protocol consolidation (via build embedded)" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", [build_embedded: true], fn _ ->
        assert_raise Mix.Error, ~r"Cannot execute task because the project was not yet compiled", fn ->
          Mix.Tasks.App.Start.run []
        end

        Mix.Task.run "compile", ["--verbose"]

        assert_received {:mix_shell, :info, ["Generated bar app"]}
        assert_received {:mix_shell, :info, ["Generated foo app"]}
        assert File.regular? "_build/dev/consolidated/Elixir.Enumerable.beam"
        purge [Enumerable]

        assert Mix.Tasks.App.Start.run []
        assert Protocol.consolidated?(Enumerable)
      end)
    end
  end

  test "recursive compiles umbrella with protocol consolidation" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", [build_embedded: true], fn _ ->
        defmodule Elixir.Mix.Tasks.Umbrella.Recur do
          use Mix.Task
          @recursive true
          def run(_), do: Mix.Task.run "compile", ["--verbose"]
        end

        Mix.Task.run "umbrella.recur"
        assert_received {:mix_shell, :info, ["Generated bar app"]}
        assert_received {:mix_shell, :info, ["Generated foo app"]}
        assert File.regular? "_build/dev/consolidated/Elixir.Enumerable.beam"
        purge [Enumerable]

        assert Mix.Tasks.App.Start.run []
        assert Protocol.consolidated?(Enumerable)
      end)
    end
  end

  defmodule UmbrellaDeps do
    def project do
      [apps_path: "apps",
       deps: [{:some_dep, path: "deps/some_dep"}]]
    end
  end

  test "loads umbrella dependencies" do
    Mix.Project.push UmbrellaDeps

    in_fixture "umbrella_dep/deps/umbrella", fn ->
      File.mkdir_p!("deps/some_dep/ebin")
      File.mkdir_p!("_build/dev/lib/some_dep/ebin")
      File.mkdir_p!("_build/dev/lib/foo/ebin")
      File.mkdir_p!("_build/dev/lib/bar/ebin")

      Mix.Task.run "loadpaths", ["--no-deps-check", "--no-elixir-version-check"]
      assert to_charlist(Path.expand("_build/dev/lib/some_dep/ebin")) in :code.get_path
      assert to_charlist(Path.expand("_build/dev/lib/foo/ebin")) in :code.get_path
      assert to_charlist(Path.expand("_build/dev/lib/bar/ebin")) in :code.get_path
    end
  end

  test "loads umbrella child dependencies in all environments" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project :umbrella, ".", fn _ ->
        File.write! "apps/bar/mix.exs", """
        defmodule Bar.Mixfile do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             deps: [{:git_repo, git: MixTest.Case.fixture_path("git_repo"), only: :other}]]
          end
        end
        """

        # Does not fetch when filtered
        Mix.Tasks.Deps.Get.run ["--only", "dev"]
        refute_received {:mix_shell, :info, ["* Getting git_repo" <> _]}

        # But works across all environments
        Mix.Tasks.Deps.Get.run []
        assert_received {:mix_shell, :info, ["* Getting git_repo" <> _]}

        # Does not show by default
        Mix.Tasks.Deps.run []
        refute_received {:mix_shell, :info, ["* git_repo" <> _]}

        # But shows on proper environment
        Mix.env(:other)
        Mix.Tasks.Deps.run []
        assert_received {:mix_shell, :info, ["* git_repo " <> _]}
      end
    end
  after
    Mix.env(:test)
  end

  test "loads umbrella sibling dependencies with :in_umbrella" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project :umbrella, ".", fn _ ->
        File.write! "apps/bar/mix.exs", """
        defmodule Bar.Mixfile do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             deps: [{:foo, in_umbrella: true}]]
          end
        end
        """

        # Running from umbrella should not cause conflicts
        Mix.Tasks.Deps.Get.run []
        Mix.Tasks.Run.run []
      end
    end
  end

  test "finds umbrella sibling dependencies conflicts with :in_umbrella" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project :umbrella, ".", fn _ ->
        File.write! "apps/bar/mix.exs", """
        defmodule Bar.Mixfile do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             deps: [{:foo, in_umbrella: true, env: :unknown}]]
          end
        end
        """

        assert_raise Mix.Error, fn ->
          Mix.Tasks.Deps.Get.run []
        end

        assert_received {:mix_shell, :error, ["Dependencies have diverged:"]}
        assert_received {:mix_shell, :error, ["  the dependency foo in mix.exs is overriding a child dependency" <> _]}
      end
    end
  end

  ## Umbrellas as a dependency

  test "list deps for umbrella as dependency" do
    in_fixture("umbrella_dep", fn ->
      Mix.Project.in_project(:umbrella_dep, ".", fn _ ->
        Mix.Task.run "deps"
        assert_received {:mix_shell, :info, ["* umbrella (deps/umbrella) (mix)"]}
        assert_received {:mix_shell, :info, ["* foo (apps/foo) (mix)"]}
      end)
    end)
  end

  test "compile for umbrella as dependency" do
    in_fixture "umbrella_dep", fn ->
      Mix.Project.in_project(:umbrella_dep, ".", fn _ ->
        Mix.Task.run "deps.compile"
        assert Bar.bar == "hello world"
      end)
    end
  end

  defmodule CycleDeps do
    def project do
      [app: :umbrella_dep,
       deps: [
         {:bar, path: "deps/umbrella/apps/bar"},
         {:umbrella, path: "deps/umbrella"}
       ]]
    end
  end

  test "handles dependencies with cycles" do
    Mix.Project.push CycleDeps

    in_fixture "umbrella_dep", fn ->
      assert Enum.map(Mix.Dep.loaded([]), & &1.app) == [:foo, :bar, :umbrella]
    end
  end

  test "handles dependencies with cycles and overridden deps" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project :umbrella, ".", fn _ ->
        File.write! "apps/foo/mix.exs", """
        defmodule Foo.Mixfile do
          use Mix.Project

          def project do
            # Ensure we have the proper environment
            :dev = Mix.env

            [app: :foo,
             version: "0.1.0",
             deps: [{:bar, in_umbrella: true}]]
          end
        end
        """

        File.write! "apps/bar/mix.exs", """
        defmodule Bar.Mixfile do
          use Mix.Project

          def project do
            # Ensure we have the proper environment
            :dev = Mix.env

            [app: :bar,
             version: "0.1.0",
             deps: [{:a, path: "deps/a"},
                    {:b, path: "deps/b"}]]
          end
        end
        """

        assert Enum.map(Mix.Dep.loaded([]), & &1.app) == [:a, :b, :bar, :foo]
      end
    end
  end

  test "uses dependency aliases" do
    in_fixture "umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project :umbrella, ".", fn _ ->
        File.write! "apps/bar/mix.exs", """
        defmodule Bar.Mixfile do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             aliases: ["compile.all": fn _ -> Mix.shell.info "no compile bar" end]]
          end
        end
        """

        Mix.Task.run "compile", ["--verbose"]
        assert_receive {:mix_shell, :info, ["no compile bar"]}
        refute_receive {:mix_shell, :info, ["Compiled lib/bar.ex"]}
      end
    end
  end

  test "recompiles after path dependency changes" do
    in_fixture("umbrella_dep/deps/umbrella/apps", fn ->
      Mix.Project.in_project(:bar, "bar", fn _ ->
        Mix.Task.run "compile", ["--verbose"]
        assert_received {:mix_shell, :info, ["Generated foo app"]}
        assert_received {:mix_shell, :info, ["Generated bar app"]}
        assert File.regular?("_build/dev/lib/foo/ebin/Elixir.Foo.beam")
        assert File.regular?("_build/dev/lib/bar/ebin/Elixir.Bar.beam")

        # Noop by default
        assert Mix.Tasks.Compile.Elixir.run(["--verbose"]) == :noop

        # Noop when there is no runtime dependency
        ensure_touched("_build/dev/lib/foo/ebin/Elixir.Foo.beam",
                       File.stat!("_build/dev/lib/bar/.compile.elixir").mtime)
        ensure_touched("_build/dev/lib/foo/.compile.elixir",
                       File.stat!("_build/dev/lib/bar/.compile.elixir").mtime)
        assert Mix.Tasks.Compile.Elixir.run(["--verbose"]) == :noop

        # Add runtime dependency
        File.write!("lib/bar.ex", """
        defmodule Bar do
          def bar, do: Foo.foo
        end
        """)
        assert Mix.Tasks.Compile.Elixir.run(["--verbose"]) == :ok
        assert_receive {:mix_shell, :info, ["Compiled lib/bar.ex"]}

        # Noop for runtime dependencies
        ensure_touched("_build/dev/lib/foo/ebin/Elixir.Foo.beam",
                       File.stat!("_build/dev/lib/bar/.compile.elixir").mtime)
        ensure_touched("_build/dev/lib/foo/.compile.elixir",
                       File.stat!("_build/dev/lib/bar/.compile.elixir").mtime)
        assert Mix.Tasks.Compile.Elixir.run(["--verbose"]) == :noop

        # Add compile time dependency
        File.write!("lib/bar.ex", "defmodule Bar, do: Foo.foo")
        assert Mix.Tasks.Compile.Elixir.run(["--verbose"]) == :ok
        assert_receive {:mix_shell, :info, ["Compiled lib/bar.ex"]}

        # Recompiles for compile time dependencies
        ensure_touched("_build/dev/lib/foo/ebin/Elixir.Foo.beam",
                       File.stat!("_build/dev/lib/bar/.compile.elixir").mtime)
        ensure_touched("_build/dev/lib/foo/.compile.elixir",
                       File.stat!("_build/dev/lib/bar/.compile.elixir").mtime)
        assert Mix.Tasks.Compile.Elixir.run(["--verbose"]) == :ok
        assert_receive {:mix_shell, :info, ["Compiled lib/bar.ex"]}
      end)
    end)
  end

  test "reconsolidates after path dependency changes" do
    in_fixture("umbrella_dep/deps/umbrella/apps", fn ->
      Mix.Project.in_project(:bar, "bar", fn _ ->
        # Add a protocol dependency
        File.write!("../foo/lib/foo.ex", """
        defprotocol Foo do
          def foo(arg)
        end
        defimpl Foo, for: List do
          def foo(list), do: list
        end
        """)
        Mix.Task.run("compile")
        assert File.regular?("_build/dev/consolidated/Elixir.Foo.beam")
        assert Mix.Tasks.Compile.Protocols.run([]) == :noop

        # Mark protocol as outdated
        File.touch!("_build/dev/consolidated/Elixir.Foo.beam",
                    {{2010, 1, 1}, {0, 0, 0}})

        ensure_touched("_build/dev/lib/foo/ebin/Elixir.Foo.beam",
                       File.stat!("_build/dev/consolidated/.compile.protocols").mtime)
        assert Mix.Tasks.Compile.Protocols.run([]) == :ok

        # Check new timestamp
        assert File.stat!("_build/dev/consolidated/Elixir.Foo.beam").mtime >
                         {{2010, 1, 1}, {0, 0, 0}}
      end)
    end)
  end

  test "reconsolidates using umbrella parent information on shared _build" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      File.write!("apps/bar/lib/bar.ex", """
      defprotocol Bar do
        def bar(arg)
      end
      defimpl Bar, for: List do
        def bar(list), do: list
      end
      """)

      Mix.Project.in_project(:foo, "apps/foo", [build_path: "../../_build"], fn _ ->
        Mix.Task.run("compile.protocols")
        refute Code.ensure_loaded?(Bar)
      end)

      Mix.Project.in_project(:umbrella, ".", fn _ ->
        Mix.Task.run("compile.protocols")
        Mix.Task.run("app.start")
        assert Protocol.consolidated?(Bar)
      end)
    end)
  end

  test "reconsolidates using umbrella child information on shared _build" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      File.write!("apps/bar/lib/bar.ex", """
      defprotocol Bar do
        def foo(arg)
      end
      defimpl Bar, for: List do
        def foo(list), do: list
      end
      """)

      Mix.Project.in_project(:umbrella, ".", fn _ ->
        Mix.Task.run("compile.protocols")
      end)

      # Emulate the dependency being removed
      Mix.Project.in_project(:foo, "apps/foo", [build_path: "../../_build", deps: []], fn _ ->
        File.rm_rf "../../_build/dev/lib/bar"
        Mix.Task.run("compile.protocols")
      end)
    end)
  end

  test "apps cannot refer to themselves as a dep" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project :umbrella, ".", fn _ ->
        File.write! "apps/bar/mix.exs", """
        defmodule Bar.Mixfile do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             deps: [{:bar, in_umbrella: true}]]
          end
        end
        """

        assert_raise Mix.Error, "App bar lists itself as a dependency", fn ->
          Mix.Task.run("deps.get", ["--verbose"]) == [:ok, :ok]
        end
      end
    end)
  end
end
