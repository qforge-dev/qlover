defmodule Qlover.MixProject do
  use Mix.Project

  @version File.read!(Path.join(__DIR__, "VERSION")) |> String.trim()
  @source_url "https://github.com/qforge-dev/qlover"

  def project do
    [
      app: :qlover,
      version: @version,
      elixir: "~> 1.18",
      description: "Incremental line-coverage gate for stale ExUnit runs",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      # The attributed runner executes in child VMs. Parent-VM :cover cannot
      # observe those paths; real Mix-project acceptance tests gate them instead.
      test_coverage: [
        summary: [threshold: 100],
        ignore_modules: [
          ~r/^QloverFix/,
          Mix.Tasks.Qlover,
          Mix.Tasks.Test.Qlover,
          Qlover.Attribution,
          Qlover.Coverage,
          Qlover.Coverage.Evidence,
          Qlover.Coverage.Instrumenter,
          Qlover.Coverage.Runtime,
          Qlover.Native
        ]
      ],
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:crypto, :tools, :inets, :ssl]]
  end

  def cli do
    [preferred_envs: [qlover: :test, "test.qlover": :test]]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      assets: %{"docs/assets" => "docs/assets"},
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp aliases do
    []
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Michal Warda"],
      files: [
        "lib",
        "native/Cargo.toml",
        "native/Cargo.lock",
        "native/src",
        "cover.sh",
        "docs/assets",
        "VERSION",
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "mix.exs"
      ]
    ]
  end
end
