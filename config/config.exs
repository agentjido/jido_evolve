import Config

if config_env() in [:dev, :test] do
  config :git_hooks, auto_install: false
end

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :generation,
    :population_size,
    :best_score,
    :diversity,
    :evaluated_count,
    :offspring_count,
    :elite_count,
    :details
  ]
