defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [
      app: :demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [summary: [threshold: 100]],
      elixirc_options: [tracers: tracers()],
      test_elixirc_options: [tracers: tracers()]
    ]
  end

  def application, do: []

  def cli do
    [preferred_envs: [qlover: :test, "test.qlover": :test]]
  end

  # Mirrors the labqoat convention where bare `mix test` is stale-flavored.
  # Qlover always passes explicit `--no-stale`-first argv so this alias can
  # never shrink its selection.
  defp aliases do
    [test: ["test --stale"]]
  end

  # The tracer module only exists in :test (qlover is a test-only dep),
  # so only trace there. In dev/prod the list is empty and compilation
  # is untouched.
  defp tracers do
    if Mix.env() == :test, do: [Qlover.Tracer], else: []
  end

  defp deps do
    [
      {:qlover, path: "../..", only: :test, runtime: false}
    ]
  end
end
