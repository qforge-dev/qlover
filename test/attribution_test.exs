defmodule Qlover.AttributionTest do
  @moduledoc """
  Pure per-test-file attribution helpers: reference decoding, change
  detection, transitive affected-module closure, expansion selection,
  snapshot merging, and gate planning.
  """

  use ExUnit.Case, async: true

  alias Qlover.Attribution

  test "record filenames are stable content hashes" do
    assert Attribution.record_filename("t/a_test.exs") ==
             Attribution.record_filename("t/a_test.exs")

    assert Attribution.record_filename("t/a_test.exs") !=
             Attribution.record_filename("t/b_test.exs")

    assert String.ends_with?(Attribution.record_filename("t/a_test.exs"), ".term")
  end

  test "decode_record accepts full records and ignores extra keys" do
    record = %{path: "t/a.exs", sha: "abc", modules: ["Elixir.Foo"], defined: ["Elixir.ATest"]}
    assert {:ok, ^record} = Attribution.decode_record(:erlang.term_to_binary(record))

    extended = Map.put(record, :future, 1)
    assert {:ok, ^record} = Attribution.decode_record(:erlang.term_to_binary(extended))

    nil_sha = %{record | sha: nil}
    assert {:ok, ^nil_sha} = Attribution.decode_record(:erlang.term_to_binary(nil_sha))
  end

  test "decode_record rejects malformed records" do
    assert :error = Attribution.decode_record("garbage")

    for bad <- [
          %{path: "t/a.exs", sha: "abc", modules: ["Elixir.Foo"]},
          %{path: "t/a.exs", sha: 123, modules: [], defined: []},
          %{path: :atom, sha: "abc", modules: [], defined: []},
          %{path: "t/a.exs", sha: "abc", modules: ["Elixir.Foo", 42], defined: []},
          %{path: "t/a.exs", sha: "abc", modules: [], defined: [:atom]},
          %{path: "t/a.exs", sha: "abc", modules: "nope", defined: []},
          ["just", "a", "list"],
          42
        ] do
      assert :error = Attribution.decode_record(:erlang.term_to_binary(bad))
    end
  end

  test "code_file? matches Elixir sources only" do
    assert Attribution.code_file?("t/a_test.exs")
    assert Attribution.code_file?("test/support/case.ex")
    refute Attribution.code_file?("t/fixtures/data.json")
    refute Attribution.code_file?("t/README.md")
    refute Attribution.code_file?("t/app.beam")
    refute Attribution.code_file?("exs")
  end

  test "beam and module names round-trip" do
    assert Attribution.beam_module_string("Elixir.Foo.Bar.beam") == "Elixir.Foo.Bar"
    assert Attribution.beam_module_string("lists.beam") == "lists"
    assert Attribution.beam_filename("Elixir.Foo.Bar") == "Elixir.Foo.Bar.beam"
    assert Attribution.beam_filename("lists") == "lists.beam"

    for mod <- ["Elixir.Foo", "lists"] do
      assert mod |> Attribution.beam_filename() |> Attribution.beam_module_string() == mod
    end
  end

  test "diff_tests classifies added, removed, modified, and unchanged files" do
    baseline = %{
      "same.exs" => %{sha: "1", modules: []},
      "changed.exs" => %{sha: "1", modules: []},
      "gone.exs" => %{sha: "1", modules: []}
    }

    current = %{"same.exs" => "1", "changed.exs" => "2", "new.exs" => "3"}

    assert Attribution.diff_tests(baseline, current) == %{
             added: ["new.exs"],
             removed: ["gone.exs"],
             modified: ["changed.exs"]
           }

    assert Attribution.diff_tests(%{}, %{}) == %{added: [], removed: [], modified: []}
  end

  test "closure follows transitive edges and survives cycles" do
    edges = %{"A" => ["B"], "B" => ["C"], "C" => []}
    assert Attribution.closure(["A"], edges) == ["A", "B", "C"]

    cyclic = %{"A" => ["B"], "B" => ["A", "C"], "C" => ["C"]}
    assert Attribution.closure(["A"], cyclic) == ["A", "B", "C"]

    assert Attribution.closure([], edges) == []
    assert Attribution.closure(["Z"], edges) == ["Z"]
    assert Attribution.closure(["A", "A", "B"], edges) == ["A", "B", "C"]
  end

  test "affected_modules unions seed closures" do
    edges = %{"H" => ["Elixir.M"], "Elixir.M" => []}

    assert Attribution.affected_modules([["Elixir.H"], ["Elixir.M"]], edges) == [
             "Elixir.H",
             "Elixir.M"
           ]

    assert Attribution.affected_modules([[], []], edges) == []
  end

  test "runnable_files excludes compiled support files" do
    files = [
      "test/a_test.exs",
      "test/support/help.ex",
      "test/support/nested/deep.ex",
      "test/other_test.exs"
    ]

    compiled = ["/repo/test/support"]

    assert Attribution.runnable_files(files, compiled, "/repo") == [
             "test/a_test.exs",
             "test/other_test.exs"
           ]

    # Sibling-prefix trap: /repo/test/supportx is NOT under /repo/test/support.
    assert Attribution.runnable_files(["test/supportx/y.exs"], compiled, "/repo") == [
             "test/supportx/y.exs"
           ]

    # Absolute relpaths resolve directly; empty dirs keep everything.
    assert Attribution.runnable_files(["/repo/test/a_test.exs"], compiled, "/elsewhere") == [
             "/repo/test/a_test.exs"
           ]

    assert Attribution.runnable_files(files, [], "/repo") == files
    assert Attribution.runnable_files([], compiled, "/repo") == []
  end

  test "plan excludes compiled files from the expansion run" do
    assert Attribution.plan(%{
             beam_changed: [],
             current_beams: %{"Elixir.H.beam" => "1", "Elixir.M.beam" => "1"},
             baseline_tests: %{
               "test/a_test.exs" => %{sha: "1", modules: ["Elixir.H"]},
               "test/support/help.ex" => %{sha: "1", modules: ["Elixir.H"]}
             },
             current_tests: %{
               "test/a_test.exs" => "2",
               "test/support/help.ex" => "1"
             },
             union_refs: %{
               "test/a_test.exs" => ["Elixir.H"],
               "test/support/help.ex" => ["Elixir.H"]
             },
             lib_edges: %{"Elixir.H" => ["Elixir.M"]},
             fresh_lib_edges: %{},
             compiled_dirs: ["/repo/test/support"],
             project_root: "/repo"
           }) ==
             {:incremental,
              %{
                prove: ["Elixir.H.beam", "Elixir.M.beam"],
                run: ["test/a_test.exs"],
                test_changed: true
              }}
  end

  test "plan ignores tracer noise when selecting the expansion" do
    # Every file references ExUnit/Kernel noise; only the beamed module
    # may widen the run.
    assert Attribution.plan(%{
             beam_changed: [],
             current_beams: %{"Elixir.H.beam" => "1"},
             baseline_tests: %{
               "test/a_test.exs" => %{
                 sha: "1",
                 modules: ["Elixir.H", "Elixir.ExUnit.Case", "elixir_def"]
               },
               "test/b_test.exs" => %{
                 sha: "1",
                 modules: ["Elixir.M", "Elixir.ExUnit.Case", "elixir_def"]
               }
             },
             current_tests: %{"test/a_test.exs" => "2", "test/b_test.exs" => "1"},
             union_refs: %{
               "test/a_test.exs" => ["Elixir.H", "Elixir.ExUnit.Case"],
               "test/b_test.exs" => ["Elixir.M", "Elixir.ExUnit.Case"]
             },
             lib_edges: %{},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) ==
             {:incremental,
              %{prove: ["Elixir.H.beam"], run: ["test/a_test.exs"], test_changed: true}}
  end

  test "plan skips expansion for pure lib changes" do
    # The stale subset already covers every referencer (soundness
    # contract), so a beam-only change needs proof but no second run.
    assert Attribution.plan(%{
             beam_changed: ["Elixir.H.beam"],
             current_beams: %{"Elixir.H.beam" => "1", "Elixir.M.beam" => "1"},
             baseline_tests: %{
               "test/a_test.exs" => %{sha: "1", modules: ["Elixir.H"]},
               "test/b_test.exs" => %{sha: "1", modules: ["Elixir.M"]}
             },
             current_tests: %{"test/a_test.exs" => "1", "test/b_test.exs" => "1"},
             union_refs: %{"test/a_test.exs" => ["Elixir.H"], "test/b_test.exs" => ["Elixir.M"]},
             lib_edges: %{},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) == {:incremental, %{prove: ["Elixir.H.beam"], run: [], test_changed: false}}
  end

  test "plan expands surviving referencers of deleted modules" do
    # The deleted beam needs no proof, but a test that still names it
    # must run to surface the breakage.
    assert Attribution.plan(%{
             beam_changed: [],
             beam_deleted: ["Elixir.Gone"],
             current_beams: %{},
             baseline_tests: %{
               "test/a_test.exs" => %{sha: "1", modules: ["Elixir.Gone"]},
               "test/gone_test.exs" => %{sha: "1", modules: ["Elixir.Gone"]}
             },
             current_tests: %{"test/a_test.exs" => "1"},
             union_refs: %{"test/a_test.exs" => ["Elixir.Gone"]},
             lib_edges: %{},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) == {:incremental, %{prove: [], run: ["test/a_test.exs"], test_changed: false}}
  end

  test "referencing_files inverts the reference graph" do
    refs = %{
      "t1.exs" => ["Elixir.A"],
      "t2.exs" => ["Elixir.B"],
      "t3.exs" => ["Elixir.A", "Elixir.B"]
    }

    assert Attribution.referencing_files(["Elixir.A"], refs) == ["t1.exs", "t3.exs"]
    assert Attribution.referencing_files(["Elixir.Nope"], refs) == []
    assert Attribution.referencing_files([], refs) == []
    assert Attribution.referencing_files(["Elixir.A"], %{}) == []
  end

  test "group_by_defined unions modules across records" do
    records = [
      %{path: "a.ex", sha: "1", modules: ["Elixir.M", "Elixir.N"], defined: ["Elixir.H"]},
      %{path: "b.ex", sha: "1", modules: ["Elixir.O"], defined: ["Elixir.H", "Elixir.P"]},
      %{path: "t/x.exs", sha: "1", modules: ["Elixir.H"], defined: []}
    ]

    assert Attribution.group_by_defined(records) == %{
             "Elixir.H" => ["Elixir.M", "Elixir.N", "Elixir.O"],
             "Elixir.P" => ["Elixir.O"]
           }

    assert Attribution.group_by_defined([]) == %{}
  end

  test "filter_lib_edges keeps only modules with current beams" do
    grouped = %{"Elixir.Kept" => ["Elixir.X"], "Elixir.Gone" => ["Elixir.Y"]}
    beams = %{"Elixir.Kept.beam" => "sha"}

    assert Attribution.filter_lib_edges(grouped, beams) == %{"Elixir.Kept" => ["Elixir.X"]}
    assert Attribution.filter_lib_edges(grouped, %{}) == %{}
  end

  test "union_refs prefers fresh records over baseline snapshots" do
    baseline = %{
      "same.exs" => %{sha: "1", modules: ["Elixir.Old"]},
      "carried.exs" => %{sha: "1", modules: nil}
    }

    fresh = %{"same.exs" => %{path: "same.exs", sha: "1", modules: ["Elixir.New"], defined: []}}
    current = %{"same.exs" => "1", "carried.exs" => "1", "unknown.exs" => "9"}

    assert Attribution.union_refs(baseline, fresh, current) == %{
             "same.exs" => ["Elixir.New"],
             "carried.exs" => [],
             "unknown.exs" => []
           }
  end

  test "snapshot_tests merges fresh, carried, and unknown entries" do
    baseline = %{
      "same.exs" => %{sha: "1", modules: ["Elixir.Old"]},
      "gone.exs" => %{sha: "1", modules: ["Elixir.Gone"]},
      "stale.exs" => %{sha: "1", modules: ["Elixir.Stale"]}
    }

    fresh = %{
      "same.exs" => %{path: "same.exs", sha: "1", modules: ["Elixir.Old"], defined: []},
      "changed.exs" => %{path: "changed.exs", sha: "2", modules: ["Elixir.New"], defined: []},
      "other.exs" => %{path: "other.exs", sha: "9", modules: ["Elixir.Other"], defined: []}
    }

    current = %{
      "same.exs" => "1",
      "changed.exs" => "2",
      "untraced.exs" => "3",
      "data.json" => "4"
    }

    assert Attribution.snapshot_tests(current, baseline, fresh) == %{
             "same.exs" => %{sha: "1", modules: ["Elixir.Old"]},
             "changed.exs" => %{sha: "2", modules: ["Elixir.New"]},
             "untraced.exs" => %{sha: "3", modules: nil},
             "data.json" => %{sha: "4", modules: []}
           }
  end

  test "snapshot_librefs refreshes changed modules and carries the rest" do
    baseline = %{"Elixir.H" => ["Elixir.Old"], "Elixir.Kept" => ["Elixir.K"]}
    fresh = %{"Elixir.H" => ["Elixir.New"], "Elixir.Unchanged" => ["Elixir.U"]}

    assert Attribution.snapshot_librefs(baseline, fresh, ["Elixir.H"]) == %{
             "Elixir.H" => ["Elixir.New", "Elixir.Old"],
             "Elixir.Kept" => ["Elixir.K"]
           }

    assert Attribution.snapshot_librefs(baseline, fresh, []) == baseline
    assert Attribution.snapshot_librefs(%{}, %{}, ["Elixir.H"]) == %{}
  end

  test "unknown_files lists snapshot entries without references" do
    snapshot = %{
      "a.exs" => %{sha: "1", modules: nil},
      "b.exs" => %{sha: "1", modules: []},
      "c.exs" => %{sha: "1", modules: ["Elixir.X"]}
    }

    assert Attribution.unknown_files(snapshot) == ["a.exs"]
    assert Attribution.unknown_files(%{}) == []
  end

  test "prune_records drops stale, corrupt, and foreign records" do
    entries = [
      {"keep_test.term", {:ok, %{path: "t/a.exs", sha: "1", modules: [], defined: []}}},
      {"keep_lib.term", {:ok, %{path: "lib/h.ex", sha: "1", modules: [], defined: ["Elixir.H"]}}},
      {"stale.term", {:ok, %{path: "t/gone.exs", sha: "1", modules: [], defined: []}}},
      {"dead_lib.term",
       {:ok, %{path: "lib/gone.ex", sha: "1", modules: [], defined: ["Elixir.Gone"]}}},
      {"garbage.term", :error}
    ]

    current_files = MapSet.new(["t/a.exs"])
    beamed = MapSet.new(["Elixir.H"])

    assert Attribution.prune_records(entries, current_files, beamed) == [
             "dead_lib.term",
             "garbage.term",
             "stale.term"
           ]

    assert Attribution.prune_records([], current_files, beamed) == []
  end

  test "valid_tests? accepts snapshots and rejects malformed maps" do
    assert Attribution.valid_tests?(%{})
    assert Attribution.valid_tests?(%{"t/a.exs" => %{sha: "1", modules: ["Elixir.X"]}})
    assert Attribution.valid_tests?(%{"t/a.exs" => %{sha: "1", modules: nil}})
    assert Attribution.valid_tests?(%{"t/a.exs" => %{sha: "1", modules: []}})

    refute Attribution.valid_tests?([])
    refute Attribution.valid_tests?(%{"t/a.exs" => %{sha: "1"}})
    refute Attribution.valid_tests?(%{"t/a.exs" => %{sha: 1, modules: []}})
    refute Attribution.valid_tests?(%{atom: %{sha: "1", modules: []}})
    refute Attribution.valid_tests?(%{"t/a.exs" => %{sha: "1", modules: ["Elixir.X", 42]}})
    refute Attribution.valid_tests?(%{"t/a.exs" => %{sha: "1", modules: "nope"}})
  end

  test "valid_librefs? accepts edge maps and rejects malformed maps" do
    assert Attribution.valid_librefs?(%{})
    assert Attribution.valid_librefs?(%{"Elixir.H" => ["Elixir.M"]})

    refute Attribution.valid_librefs?([])
    refute Attribution.valid_librefs?(%{"Elixir.H" => ["Elixir.M", 42]})
    refute Attribution.valid_librefs?(%{atom: []})
    refute Attribution.valid_librefs?(%{"Elixir.H" => "nope"})
  end

  test "plan passes through when nothing changed" do
    assert Attribution.plan(%{
             beam_changed: [],
             current_beams: %{"Elixir.A.beam" => "1"},
             baseline_tests: %{"t/a.exs" => %{sha: "1", modules: ["Elixir.A"]}},
             current_tests: %{"t/a.exs" => "1"},
             union_refs: %{"t/a.exs" => ["Elixir.A"]},
             lib_edges: %{},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) == {:incremental, %{prove: [], run: [], test_changed: false}}
  end

  test "plan proves changed beams without running tests" do
    assert Attribution.plan(%{
             beam_changed: ["Elixir.B.beam"],
             current_beams: %{"Elixir.A.beam" => "1", "Elixir.B.beam" => "2"},
             baseline_tests: %{},
             current_tests: %{},
             union_refs: %{},
             lib_edges: %{},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) == {:incremental, %{prove: ["Elixir.B.beam"], run: [], test_changed: false}}
  end

  test "plan proves transitively affected modules and expands the run" do
    assert Attribution.plan(%{
             beam_changed: [],
             current_beams: %{"Elixir.H.beam" => "1", "Elixir.M.beam" => "1"},
             baseline_tests: %{
               "t/a.exs" => %{sha: "1", modules: ["Elixir.H"]},
               "t/b.exs" => %{sha: "1", modules: ["Elixir.M"]}
             },
             current_tests: %{"t/a.exs" => "2", "t/b.exs" => "1"},
             union_refs: %{"t/a.exs" => ["Elixir.H"], "t/b.exs" => ["Elixir.M"]},
             lib_edges: %{"Elixir.H" => ["Elixir.M"]},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) ==
             {:incremental,
              %{
                prove: ["Elixir.H.beam", "Elixir.M.beam"],
                run: ["t/a.exs", "t/b.exs"],
                test_changed: true
              }}
  end

  test "plan drops references without current beams" do
    assert Attribution.plan(%{
             beam_changed: [],
             current_beams: %{},
             baseline_tests: %{"t/a.exs" => %{sha: "1", modules: ["Elixir.Gone", "ExUnit.Case"]}},
             current_tests: %{"t/a.exs" => "2"},
             union_refs: %{"t/a.exs" => ["Elixir.Gone", "ExUnit.Case"]},
             lib_edges: %{},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) == {:incremental, %{prove: [], run: ["t/a.exs"], test_changed: true}}
  end

  test "plan treats new test files as additions needing no proof" do
    assert Attribution.plan(%{
             beam_changed: [],
             current_beams: %{"Elixir.A.beam" => "1"},
             baseline_tests: %{"t/a.exs" => %{sha: "1", modules: ["Elixir.A"]}},
             current_tests: %{"t/a.exs" => "1", "t/new.exs" => "2"},
             union_refs: %{"t/a.exs" => ["Elixir.A"], "t/new.exs" => []},
             lib_edges: %{},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) == {:incremental, %{prove: [], run: ["t/new.exs"], test_changed: true}}
  end

  test "plan falls back on fixture changes" do
    # Added, removed, and modified non-code files all force a full run.
    cases = [
      {%{}, %{"t/a.exs" => "1", "t/data.json" => "2"}},
      {%{"t/gone.json" => %{sha: "1", modules: []}}, %{"t/a.exs" => "1"}},
      {%{"t/data.json" => %{sha: "1", modules: []}}, %{"t/a.exs" => "1", "t/data.json" => "2"}}
    ]

    for {baseline_tests, current_tests} <- cases do
      assert Attribution.plan(%{
               beam_changed: [],
               current_beams: %{},
               baseline_tests: baseline_tests,
               current_tests: current_tests,
               union_refs: %{},
               lib_edges: %{},
               fresh_lib_edges: %{},
               compiled_dirs: [],
               project_root: "/repo"
             }) == {:full, :test_fixtures}
    end
  end

  test "plan falls back when changed tests lack references" do
    baseline_tests = %{"t/a.exs" => %{sha: "1", modules: nil}}

    assert Attribution.plan(%{
             beam_changed: [],
             current_beams: %{},
             baseline_tests: baseline_tests,
             current_tests: %{"t/a.exs" => "2"},
             union_refs: %{},
             lib_edges: %{},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) == {:full, :unattributed}
  end

  test "plan closes over fresh lib edges for changed beams" do
    assert Attribution.plan(%{
             beam_changed: ["Elixir.H.beam"],
             current_beams: %{"Elixir.H.beam" => "1", "Elixir.M2.beam" => "1"},
             baseline_tests: %{},
             current_tests: %{},
             union_refs: %{},
             lib_edges: %{},
             fresh_lib_edges: %{"Elixir.H" => ["Elixir.M2"]},
             compiled_dirs: [],
             project_root: "/repo"
           }) ==
             {:incremental,
              %{prove: ["Elixir.H.beam", "Elixir.M2.beam"], run: [], test_changed: false}}

    # Without fresh edges the changed beam alone is proven (legacy behavior).
    assert Attribution.plan(%{
             beam_changed: ["Elixir.H.beam"],
             current_beams: %{"Elixir.H.beam" => "1", "Elixir.M2.beam" => "1"},
             baseline_tests: %{},
             current_tests: %{},
             union_refs: %{},
             lib_edges: %{},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) == {:incremental, %{prove: ["Elixir.H.beam"], run: [], test_changed: false}}
  end

  test "plan combines beam changes with test attribution" do
    assert Attribution.plan(%{
             beam_changed: ["Elixir.C.beam"],
             current_beams: %{
               "Elixir.C.beam" => "2",
               "Elixir.H.beam" => "1",
               "Elixir.M.beam" => "1"
             },
             baseline_tests: %{
               "t/a.exs" => %{sha: "1", modules: ["Elixir.H"]},
               "t/c.exs" => %{sha: "1", modules: ["Elixir.C"]}
             },
             current_tests: %{"t/a.exs" => "2", "t/c.exs" => "1"},
             union_refs: %{"t/a.exs" => ["Elixir.H"], "t/c.exs" => ["Elixir.C"]},
             lib_edges: %{"Elixir.H" => ["Elixir.M"]},
             fresh_lib_edges: %{},
             compiled_dirs: [],
             project_root: "/repo"
           }) ==
             {:incremental,
              %{
                prove: ["Elixir.C.beam", "Elixir.H.beam", "Elixir.M.beam"],
                run: ["t/a.exs", "t/c.exs"],
                test_changed: true
              }}
  end
end
