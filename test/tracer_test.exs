defmodule Qlover.TracerTest do
  @moduledoc """
  Compiler tracer unit behavior plus an integration compile proving
  records hit the disk with the modules the file references.
  """

  use ExUnit.Case, async: false

  alias Qlover.Attribution
  alias Qlover.Tracer

  defmodule CompletionTracer do
    def trace(:start, env) do
      owner = Application.fetch_env!(:qlover, :test_trace_owner)
      send(owner, {:lexical_tracker, env.lexical_tracker})
      :ok
    end

    def trace(_event, _env), do: :ok
  end

  @moduletag :tmp_dir

  test "records remote calls with file and defining module", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      Tracer.trace({:remote_function, [], Enum, :map, 2}, env("t/a_test.exs", ATest))
      Tracer.trace({:remote_macro, [], ExUnit.Assertions, :assert, 2}, env("t/a_test.exs", ATest))
      Tracer.trace(:stop, env("t/a_test.exs", ATest))

      record = read_record!(refs, "t/a_test.exs")
      assert record.path == "t/a_test.exs"
      # Module names keep their full dotted form, matching beam filenames.
      assert "Elixir.Enum" in record.modules
      assert record.modules == ["Elixir.Enum", "Elixir.ExUnit.Assertions"]
      assert record.defined == [mod_name(ATest)]
      assert record.defined == [mod_name(ATest)]
    end)
  end

  test "records imports, aliases, and struct expansions", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      Tracer.trace({:imported_function, [], String, :trim, 1}, env("t/b_test.exs", BTest))
      Tracer.trace({:imported_macro, [], ExUnit.DocTest, :doctest, 1}, env("t/b_test.exs", BTest))
      Tracer.trace({:alias_reference, [], MyApp.Repo}, env("t/b_test.exs", BTest))
      Tracer.trace({:struct_expansion, [], MyApp.User, [:name]}, env("t/b_test.exs", BTest))
      Tracer.trace(:stop, env("t/b_test.exs", BTest))

      record = read_record!(refs, "t/b_test.exs")

      assert record.modules == [
               "Elixir.ExUnit.DocTest",
               "Elixir.MyApp.Repo",
               "Elixir.MyApp.User",
               "Elixir.String"
             ]

      assert record.defined == [mod_name(BTest)]
    end)
  end

  test "ignores unknown events and non-module references", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      assert :ok = Tracer.trace({:require, [], Kernel, []}, env("t/c_test.exs", CTest))

      assert :ok =
               Tracer.trace({:alias_reference, [], "not-a-module"}, env("t/c_test.exs", CTest))

      assert :ok = Tracer.trace({:remote_function, [], :lists, :map, 2}, env("t/c_test.exs", nil))
      assert :ok = Tracer.trace(:start, env("t/c_test.exs", nil))
      assert :ok = Tracer.trace(:stop, env("t/c_test.exs", nil))

      record = read_record!(refs, "t/c_test.exs")
      assert record.modules == ["lists"]
      assert record.defined == []
    end)
  end

  test "skips events without a file", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      assert :ok = Tracer.trace({:remote_function, [], Enum, :map, 2}, env(nil, NoFile))
      assert :ok = Tracer.trace(:start, env(nil, nil))
      assert :ok = Tracer.trace(:stop, env(nil, nil))
      refute File.exists?(Path.join(refs, Attribution.record_filename("t/c_test.exs")))
    end)
  end

  test "ignores non-atom defining modules", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      Tracer.trace({:remote_function, [], Enum, :map, 2}, env("t/n_test.exs", "not-a-module"))
      Tracer.trace(:stop, env("t/n_test.exs", "not-a-module"))

      record = read_record!(refs, "t/n_test.exs")
      assert record.modules == ["Elixir.Enum"]
      assert record.defined == []
    end)
  end

  test "stop without state never clobbers a good record", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      Tracer.trace({:remote_function, [], Enum, :map, 2}, env("t/d_test.exs", DTest))
      Tracer.trace(:stop, env("t/d_test.exs", DTest))
      before = read_record!(refs, "t/d_test.exs")

      # Nested/duplicate stops for the same file must not wipe the record.
      assert :ok = Tracer.trace(:stop, env("t/d_test.exs", DTest))
      assert read_record!(refs, "t/d_test.exs") == before
    end)
  end

  test "nested stops merge through the record file", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      Tracer.trace(:start, env("t/e_test.exs", ETest))
      Tracer.trace({:remote_function, [], Enum, :map, 2}, env("t/e_test.exs", ETest))
      # Inner context stop flushes early...
      Tracer.trace(:stop, env("t/e_test.exs", ETest))
      # ...later events re-accumulate and the outer stop unions.
      Tracer.trace({:remote_function, [], String, :trim, 1}, env("t/e_test.exs", ETest))
      Tracer.trace(:stop, env("t/e_test.exs", ETest))

      record = read_record!(refs, "t/e_test.exs")
      assert record.modules == ["Elixir.Enum", "Elixir.String"] |> Enum.sort()
      assert record.defined == [mod_name(ETest)]
    end)
  end

  test "tracks files independently in one process", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      Tracer.trace(:start, env("t/f_test.exs", FTest))
      Tracer.trace({:remote_function, [], Enum, :map, 2}, env("t/f_test.exs", FTest))
      Tracer.trace(:start, env("t/g_test.exs", GTest))
      Tracer.trace({:remote_function, [], String, :trim, 1}, env("t/g_test.exs", GTest))
      Tracer.trace(:stop, env("t/f_test.exs", FTest))
      Tracer.trace(:stop, env("t/g_test.exs", GTest))

      assert read_record!(refs, "t/f_test.exs").modules == ["Elixir.Enum"]
      assert read_record!(refs, "t/g_test.exs").modules == ["Elixir.String"]
      assert read_record!(refs, "t/f_test.exs").defined == [mod_name(FTest)]
      assert read_record!(refs, "t/g_test.exs").defined == [mod_name(GTest)]
    end)
  end

  test "start is idempotent within one file context", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      Tracer.trace(:start, env("t/h_test.exs", HTest))
      Tracer.trace({:remote_function, [], Enum, :map, 2}, env("t/h_test.exs", HTest))
      Tracer.trace(:start, env("t/h_test.exs", HTest))
      Tracer.trace(:stop, env("t/h_test.exs", HTest))

      assert read_record!(refs, "t/h_test.exs").modules == ["Elixir.Enum"]
      assert read_record!(refs, "t/h_test.exs").defined == [mod_name(HTest)]
    end)
  end

  test "never raises when the refs dir is unusable", %{tmp_dir: dir} do
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "in the way")

    with_refs_env_in(dir, blocker, fn ->
      Tracer.trace({:remote_function, [], Enum, :map, 2}, env("t/i_test.exs", ITest))
      assert :ok = Tracer.trace(:stop, env("t/i_test.exs", ITest))
    end)
  end

  test "records a nil sha when the source vanishes mid-compile", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      Tracer.trace({:remote_function, [], Enum, :map, 2}, env("t/gone_test.exs", GoneTest))
      assert :ok = Tracer.trace(:stop, env("t/gone_test.exs", GoneTest))

      record = read_record!(refs, "t/gone_test.exs")
      assert record.sha == nil
      assert record.modules == ["Elixir.Enum"]
      assert record.defined == [mod_name(GoneTest)]
    end)
  end

  test "corrupt and foreign records are replaced, not merged", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      corrupt = Path.join(refs, Attribution.record_filename("t/j_test.exs"))
      File.mkdir_p!(refs)
      File.write!(corrupt, "garbage-bytes")

      Tracer.trace({:remote_function, [], Enum, :map, 2}, env("t/j_test.exs", JTest))
      Tracer.trace(:stop, env("t/j_test.exs", JTest))

      record = read_record!(refs, "t/j_test.exs")
      assert record.modules == ["Elixir.Enum"]
      assert record.path == "t/j_test.exs"

      foreign = Path.join(refs, Attribution.record_filename("t/k_test.exs"))

      File.write!(
        foreign,
        :erlang.term_to_binary(%{
          path: "t/other.exs",
          sha: "x",
          modules: ["Elixir.Stale"],
          defined: []
        })
      )

      Tracer.trace({:remote_function, [], String, :trim, 1}, env("t/k_test.exs", KTest))
      Tracer.trace(:stop, env("t/k_test.exs", KTest))

      fresh = read_record!(refs, "t/k_test.exs")
      assert fresh.modules == ["Elixir.String"]
      assert fresh.path == "t/k_test.exs"
    end)
  end

  test "resolves default dirs from the working directory" do
    old_refs = Application.get_env(:qlover, :refs_dir)
    old_root = Application.get_env(:qlover, :project_root)
    Application.delete_env(:qlover, :refs_dir)
    Application.delete_env(:qlover, :project_root)

    try do
      assert Tracer.default_dir() == Path.join(File.cwd!(), "cover/.qlover_refs")
      assert Tracer.project_root() == File.cwd!()
      assert Tracer.refs_dir() == Tracer.default_dir()
    after
      restore_env(:refs_dir, old_refs)
      restore_env(:project_root, old_root)
    end
  end

  test "integration: compiling with the tracer writes records", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      {test_mod, _beam} =
        compile_traced!(dir, "AttrLib", "  def a, do: :ok\n  def b, do: :ok\n", "AttrTest", """
          alias Elixir.QloverFixAttrLib, as: Lib
          def t, do: [Lib.a(), Lib.b()]
        """)

      lib_record = read_record!(refs, "AttrLib.ex")
      assert "Elixir.QloverFixAttrLib" in lib_record.defined

      test_record = read_record!(refs, "t/attr_test.exs")
      assert "Elixir.QloverFixAttrLib" in test_record.modules
      assert Atom.to_string(test_mod) in test_record.defined
      assert test_record.sha == sha_of(Path.join(dir, "t/attr_test.exs"))
    end)
  end

  test "integration: recompiling after an edit refreshes the record", %{tmp_dir: dir} do
    with_refs_env(dir, fn refs ->
      compile_traced!(
        dir,
        "RefreshLib",
        "  def a, do: :ok\n",
        "RefreshTest",
        "  def t, do: Elixir.QloverFixRefreshLib.a()\n"
      )

      before = read_record!(refs, "t/refresh_test.exs")
      assert "Elixir.QloverFixRefreshLib" in before.modules

      compile_traced!(
        dir,
        "RefreshLib",
        "  def a, do: :ok\n",
        "RefreshTest",
        "  def t, do: :nothing_remote\n"
      )

      after_record = read_record!(refs, "t/refresh_test.exs")
      assert after_record.sha != before.sha
      refute "Elixir.QloverFixRefreshLib" in after_record.modules
    end)
  end

  defp mod_name(atom), do: Atom.to_string(atom)

  defp env(file, module), do: struct(Macro.Env, file: file, module: module)

  defp with_refs_env(dir, fun) do
    refs = Path.join(dir, "refs")
    with_refs_env_in(dir, refs, fn -> fun.(refs) end)
  end

  defp with_refs_env_in(dir, refs, fun) do
    old_refs = Application.get_env(:qlover, :refs_dir)
    old_root = Application.get_env(:qlover, :project_root)
    Application.put_env(:qlover, :refs_dir, refs)
    Application.put_env(:qlover, :project_root, dir)

    try do
      fun.()
    after
      restore_env(:refs_dir, old_refs)
      restore_env(:project_root, old_root)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:qlover, key)
  defp restore_env(key, value), do: Application.put_env(:qlover, key, value)

  defp read_record!(refs, rel) do
    refs
    |> Path.join(Attribution.record_filename(rel))
    |> File.read!()
    |> :erlang.binary_to_term()
  end

  defp sha_of(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp with_tracers(fun) do
    prev = Code.get_compiler_option(:tracers)
    old_owner = Application.get_env(:qlover, :test_trace_owner)
    Application.put_env(:qlover, :test_trace_owner, self())
    Code.put_compiler_option(:tracers, [Tracer, CompletionTracer])

    try do
      fun.()
    after
      try do
        await_tracers()
      after
        Code.put_compiler_option(:tracers, prev)
        restore_env(:test_trace_owner, old_owner)
      end
    end
  end

  defp await_tracers do
    # ParallelCompiler acknowledges a file before its final :stop traces
    # finish. The lexical tracker exits after those callbacks, so monitor
    # it before reading records, editing sources, or restoring global env.
    receive do
      {:lexical_tracker, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> flunk("compiler tracer did not finish")
        end

        await_tracers()
    after
      0 -> :ok
    end
  end

  defp compile_traced!(dir, lib_tag, lib_body, test_tag, test_body) do
    test_mod = String.to_atom("Elixir.QloverFix#{test_tag}")
    File.mkdir_p!(Path.join(dir, "t"))
    File.mkdir_p!(Path.join(dir, "ebin"))

    lib_source = Path.join(dir, "#{lib_tag}.ex")
    test_source = Path.join(dir, "t/#{Macro.underscore(test_tag)}.exs")
    lib_module = String.to_atom("Elixir.QloverFix#{lib_tag}")
    File.write!(lib_source, "defmodule #{lib_module} do\n#{lib_body}end\n")
    File.write!(test_source, "defmodule #{test_mod} do\n#{test_body}end\n")

    previous = Code.compiler_options(debug_info: true, docs: false)

    try do
      with_tracers(fn ->
        {:ok, _mods, _diagnostics} =
          Kernel.ParallelCompiler.compile_to_path(
            [lib_source, test_source],
            Path.join(dir, "ebin"),
            return_diagnostics: true
          )
      end)

      {test_mod, Path.join(dir, "ebin/#{test_mod}.beam")}
    after
      Code.compiler_options(previous)
    end
  end
end
