defmodule Qlover.CacheTest do
  @moduledoc """
  Shared content-addressed cache: write-through on snapshots, read-through
  on local misses, and ref merging across directories.
  """

  use ExUnit.Case, async: false

  alias Elixir.Qlover.Attribution, as: Attribution
  alias Mix.Tasks.Qlover

  @moduletag :tmp_dir

  test "cache keys are deterministic and sensitive to every input" do
    base = %{beams: %{"a.beam" => "1"}, gate: "g", tests: %{"t/a.exs" => "s1"}}

    assert Attribution.cache_key(base) == Attribution.cache_key(base)

    assert Attribution.cache_key(%{base | gate: "other"}) != Attribution.cache_key(base)

    assert Attribution.cache_key(%{base | beams: %{"a.beam" => "2"}}) !=
             Attribution.cache_key(base)

    assert Attribution.cache_key(%{base | tests: %{"t/a.exs" => "s2"}}) !=
             Attribution.cache_key(base)

    # Entry shape (plain sha vs snapshot entry) does not affect the key.
    assert Attribution.cache_key(%{base | tests: %{"t/a.exs" => %{sha: "s1", modules: []}}}) ==
             Attribution.cache_key(base)
  end

  test "merge_records prefers sha-matching records, then local ones" do
    current = %{"t/a.exs" => "new", "t/b.exs" => "same"}

    local = [
      {"aa.term", {:ok, %{path: "t/a.exs", sha: "old", modules: ["Elixir.Old"], defined: []}}},
      {"bb.term", {:ok, %{path: "t/b.exs", sha: "same", modules: ["Elixir.B"], defined: []}}},
      {"bad.term", :error}
    ]

    cache = [
      {"aa.term", {:ok, %{path: "t/a.exs", sha: "new", modules: ["Elixir.New"], defined: []}}},
      {"cc.term", {:ok, %{path: "t/c.exs", sha: "x", modules: ["Elixir.C"], defined: []}}}
    ]

    merged = Attribution.merge_records(local, cache, current)
    by_path = Map.new(merged, &{&1.path, &1})

    # Cache wins when it alone matches the current file version.
    assert by_path["t/a.exs"].modules == ["Elixir.New"]
    # Local wins on ties; cache-only records fill gaps; errors drop out.
    assert by_path["t/b.exs"].modules == ["Elixir.B"]
    assert by_path["t/c.exs"].modules == ["Elixir.C"]
    assert map_size(by_path) == 3
  end

  test "merge_records handles empty inputs" do
    assert Attribution.merge_records([], [], %{}) == []
    assert Attribution.merge_records([{"a.term", :error}], [], %{}) == []
  end

  test "a baseline written in one directory gates another", %{tmp_dir: dir} do
    {opts_a, opts_b} = mirror_opts(dir)
    settings_a = Qlover.settings(opts_a, [])

    assert :ok = Qlover.run(["--write-baseline"], opts_a)

    key = Qlover.cache_key(settings_a)
    assert File.regular?(Qlover.cache_baseline_path(opts_a[:cache_dir], key))

    # Side B never ran anything: no local baseline, no refs, yet the gate
    # passes purely from the shared cache and materializes the baseline.
    refute File.exists?(opts_b[:baseline])
    assert :ok = Qlover.run([], opts_b)
    assert File.regular?(opts_b[:baseline])
  end

  test "divergent content misses the cache", %{tmp_dir: dir} do
    {opts_a, opts_b} = mirror_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts_a)

    # Same layout, different lib body: different beams, different key.
    File.write!(
      Path.join([dir, "b", "M.ex"]),
      "defmodule Elixir.QloverFixShared do\n  def a, do: :different\nend\n"
    )

    recompile!(Path.join(dir, "b"))

    assert_raise Mix.Error, ~r/missing/, fn -> Qlover.run([], opts_b) end
    refute File.exists?(opts_b[:baseline])
  end

  test "corrupt cache blobs are ignored", %{tmp_dir: dir} do
    {opts_a, opts_b} = mirror_opts(dir)
    settings_b = Qlover.settings(opts_b, [])

    assert :ok = Qlover.run(["--write-baseline"], opts_a)

    key = Qlover.cache_key(settings_b)
    path = Qlover.cache_baseline_path(opts_b[:cache_dir], key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "garbage-bytes")

    assert :error = Qlover.load_baseline(settings_b)
    assert_raise Mix.Error, ~r/missing/, fn -> Qlover.run([], opts_b) end
  end

  test "an invalid local baseline heals from the cache", %{tmp_dir: dir} do
    {opts_a, opts_b} = mirror_opts(dir)

    assert :ok = Qlover.run(["--write-baseline"], opts_a)
    File.write!(opts_b[:baseline], "garbage")

    assert :ok = Qlover.run([], opts_b)
    assert %{vsn: 4} = :erlang.binary_to_term(File.read!(opts_b[:baseline]))
  end

  test "a disabled cache performs no cache IO", %{tmp_dir: dir} do
    beams = Path.join(dir, "ebin")
    File.mkdir_p!(beams)
    File.mkdir_p!(Path.join(dir, "t"))

    opts = [
      baseline: Path.join(dir, "baseline"),
      export_path: Path.join(dir, "fresh.coverdata"),
      expansion_export_path: Path.join(dir, "expansion.coverdata"),
      compile_path: beams,
      gate_paths: [Path.join(dir, "gate")],
      test_paths: ["t"],
      project_root: dir,
      refs_dir: Path.join(dir, "refs"),
      cache_dir: nil,
      output: Path.join(dir, "html")
    ]

    settings = Qlover.settings(opts, [])
    assert settings.cache_dir == nil
    assert :error = Qlover.load_baseline(settings)
    assert_raise Mix.Error, ~r/missing/, fn -> Qlover.run([], opts) end
    refute File.exists?(Path.join(dir, "cache"))
    refute File.exists?(opts[:baseline])
  end

  test "load_baseline uses the local file without touching the cache", %{tmp_dir: dir} do
    {opts_a, _opts_b} = mirror_opts(dir)
    settings_a = Qlover.settings(opts_a, [])

    assert :ok = Qlover.run(["--write-baseline"], opts_a)
    cache = Path.join(dir, "cache")
    File.rm_rf!(cache)

    assert {:ok, %{vsn: 4}} = Qlover.load_baseline(settings_a)
    refute File.exists?(cache)
  end

  test "records from the cache fill snapshot gaps", %{tmp_dir: dir} do
    {_opts_a, opts_b} = mirror_opts(dir)
    settings_b = Qlover.settings(opts_b, [])
    rel = "t/shared_test.exs"
    sha = file_sha!(dir, "b", rel)

    refs = Qlover.cache_refs_dir(opts_b[:cache_dir])
    File.mkdir_p!(refs)

    record = %{path: rel, sha: sha, modules: ["Elixir.QloverFixShared"], defined: []}
    File.write!(Path.join(refs, Attribution.record_filename(rel)), :erlang.term_to_binary(record))

    assert :ok = Qlover.run(["--write-baseline"], opts_b)

    snapshot = :erlang.binary_to_term(File.read!(opts_b[:baseline]))
    assert snapshot.tests[rel] == %{sha: sha, modules: ["Elixir.QloverFixShared"]}
    assert is_binary(Qlover.cache_key(settings_b))
  end

  test "snapshots work with the cache disabled", %{tmp_dir: dir} do
    {opts_a, _opts_b} = mirror_opts(dir)
    opts = Keyword.put(opts_a, :cache_dir, nil)

    assert :ok = Qlover.run(["--write-baseline"], opts)
    assert %{vsn: 4} = :erlang.binary_to_term(File.read!(opts[:baseline]))
    assert :ok = Qlover.run([], opts)
  end

  test "unwritable cache locations degrade silently", %{tmp_dir: dir} do
    {opts_a, _opts_b} = mirror_opts(dir)
    blocker = Path.join(dir, "blocker")
    File.write!(blocker, "in the way")

    # A file where the cache dir should be: every cache write rescues.
    opts = Keyword.put(opts_a, :cache_dir, blocker)
    assert :ok = Qlover.run(["--write-baseline"], opts)
    assert File.regular?(opts[:baseline])

    # A file where the refs sync dir should be: sync rescues.
    File.rm!(blocker)
    File.mkdir_p!(blocker)
    File.write!(Path.join(blocker, "refs"), "in the way")
    assert :ok = Qlover.run(["--write-baseline"], opts)
  end

  test "missing home degrades to a disabled cache" do
    assert Qlover.default_cache_home(nil, nil) == nil
    assert Qlover.default_cache_home("/tmp/xdg", nil) == "/tmp/xdg/qlover"
    assert Qlover.default_cache_home(nil, "/home/u") == "/home/u/.cache/qlover"
    assert Qlover.default_cache_home("/tmp/xdg", "/home/u") == "/tmp/xdg/qlover"
  end

  test "write-through stores blobs under content keys", %{tmp_dir: dir} do
    {opts_a, _opts_b} = mirror_opts(dir)
    settings_a = Qlover.settings(opts_a, [])

    assert :ok = Qlover.run(["--write-baseline"], opts_a)

    key = Qlover.cache_key(settings_a)
    blob = :erlang.binary_to_term(File.read!(Qlover.cache_baseline_path(opts_a[:cache_dir], key)))
    local = :erlang.binary_to_term(File.read!(opts_a[:baseline]))

    assert blob == local
    assert Qlover.cache_refs_dir(opts_a[:cache_dir]) |> File.ls!() == []
  end

  defp mirror_opts(dir) do
    body = "defmodule Elixir.QloverFixShared do\n  def a, do: :ok\nend\n"
    test_body = "# shared test\n"
    gate_body = "v1"

    for side <- ["a", "b"] do
      root = Path.join(dir, side)
      File.mkdir_p!(Path.join(root, "ebin"))
      File.mkdir_p!(Path.join(root, "t"))
      File.mkdir_p!(Path.join(root, "gate"))
      File.write!(Path.join(root, "M.ex"), body)
      File.write!(Path.join(root, "t/shared_test.exs"), test_body)
      File.write!(Path.join(root, "gate/input.txt"), gate_body)
      compile!(root)

      [
        baseline: Path.join(root, "baseline"),
        export_path: Path.join(root, "fresh.coverdata"),
        expansion_export_path: Path.join(root, "expansion.coverdata"),
        compile_path: Path.join(root, "ebin"),
        gate_paths: [Path.join(root, "gate")],
        test_paths: ["t"],
        project_root: root,
        refs_dir: Path.join(root, "refs"),
        cache_dir: Path.join(dir, "cache"),
        output: Path.join(root, "html")
      ]
    end
    |> List.to_tuple()
  end

  defp compile!(root) do
    previous = Code.compiler_options(debug_info: true, docs: false)

    try do
      {:ok, _, _} =
        Kernel.ParallelCompiler.compile_to_path(
          [Path.join(root, "M.ex")],
          Path.join(root, "ebin"),
          return_diagnostics: true
        )

      :ok
    after
      Code.compiler_options(previous)
    end
  end

  defp recompile!(root) do
    previous = Code.compiler_options(debug_info: true, docs: false)

    try do
      {:ok, _, _} =
        Kernel.ParallelCompiler.compile_to_path(
          [Path.join(root, "M.ex")],
          Path.join(root, "ebin"),
          return_diagnostics: true
        )

      :ok
    after
      Code.compiler_options(previous)
    end
  end

  defp file_sha!(dir, side, rel) do
    :crypto.hash(:sha256, File.read!(Path.join([dir, side, rel]))) |> Base.encode16(case: :lower)
  end
end
