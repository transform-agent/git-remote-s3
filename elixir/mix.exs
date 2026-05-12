defmodule GitRemoteS3.MixProject do
  use Mix.Project

  @version "0.3.2"

  def project do
    [
      app: :git_remote_s3,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      description: "A git remote helper for Amazon S3",
      package: package(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Primary escript entry – git-remote-s3 / git-remote-s3+zip both call Remote.main/1
  defp escript do
    [
      main_module: GitRemoteS3.Remote,
      name: "git-remote-s3",
      comment: "Git remote helper for Amazon S3"
    ]
  end

  defp deps do
    [
      # AWS SDK
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      # HTTP adapter required by ExAws
      {:hackney, "~> 1.20"},
      # JSON
      {:jason, "~> 1.4"},
      # Config providers (for ~/.aws/credentials profile parsing)
      {:configparser_ex, "~> 4.0"},
      # Dev / test only
      {:mox, "~> 1.1", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/awslabs/git-remote-s3"},
      maintainers: ["Amazon.com, Inc. or its affiliates"]
    ]
  end

  defp aliases do
    [
      test: ["test --no-start"]
    ]
  end
end
