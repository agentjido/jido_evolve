# Jido.Evolve

[![Hex.pm](https://img.shields.io/hexpm/v/jido_evolve.svg)](https://hex.pm/packages/jido_evolve)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_evolve/)
[![CI](https://github.com/agentjido/jido_evolve/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_evolve/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/jido_evolve.svg)](https://github.com/agentjido/jido_evolve/blob/main/LICENSE)
[![Website](https://img.shields.io/badge/website-jido.run-0f172a.svg)](https://jido.run)
[![Ecosystem](https://img.shields.io/badge/ecosystem-jido.run-0ea5e9.svg)](https://jido.run/ecosystem)
[![Discord](https://img.shields.io/badge/discord-join-5865F2.svg?logo=discord&logoColor=white)](https://jido.run/discord)

Evolutionary algorithms for Elixir.

`Jido.Evolve.evolve/1` is the canonical public API for running stream-based evolutionary search with pluggable fitness, mutation, selection, and crossover strategies.

## Install

```elixir
def deps do
  [
    {:jido_evolve, "~> 0.2.0"}
  ]
end
```

## Installation via Igniter

```bash
mix igniter.install jido_evolve
```

## Quick Start

```elixir
defmodule MyFitness do
  use Jido.Evolve.Fitness

  def evaluate(entity, _ctx), do: {:ok, String.length(entity)}
end

stream =
  Jido.Evolve.evolve(
    initial_population: ["random", "strings", "here"],
    fitness: MyFitness
  )

final_state = Enum.reduce(stream, fn state, _acc -> state end)
IO.puts("Best: #{final_state.best_entity} (#{final_state.best_score})")
```

## API

### `Jido.Evolve.evolve/1`

Required options:

- `:initial_population` - non-empty list of entities
- `:fitness` - module implementing `evaluate/2`

Optional options:

- `:config` - `%Jido.Evolve.Config{}` or config map/keyword
- `:context` - map passed to fitness evaluation
- `:mutation` - mutation module override
- `:selection` - selection module override
- `:crossover` - crossover module override

Returns a lazy `Stream` of `Jido.Evolve.State` values (one per generation).

## Configure

```elixir
config =
  Jido.Evolve.Config.new!(
    population_size: 100,
    generations: 500,
    mutation_rate: 0.1,
    crossover_rate: 0.7,
    elitism_rate: 0.05,
    selection_strategy: Jido.Evolve.Selection.Tournament,
    mutation_strategy: Jido.Evolve.Mutation.Text,
    crossover_strategy: Jido.Evolve.Crossover.String,
    random_seed: 1234,
    max_concurrency: System.schedulers_online()
  )
```

Pass config into `evolve/1`:

```elixir
Jido.Evolve.evolve(
  initial_population: ["a", "bb", "ccc"],
  fitness: MyFitness,
  config: config
)
```

## Extension Points

- `Jido.Evolve.Fitness` - score entities
- `Jido.Evolve.Mutation` - mutate entities
- `Jido.Evolve.Selection` - select parents
- `Jido.Evolve.Crossover` - combine parents
- `Jido.Evolve.Evolvable` - representation and similarity protocol

## Quality

```bash
mix quality
mix test
mix docs
```

## v0.2.0 Migration Notes (Breaking)

- `Jido.Evolve.evolve/1` no longer accepts `:evolvable`.
- Public strategy override keys are now `:mutation`, `:selection`, and `:crossover`.
- Config/state internals are validated via Zoi.
- Error handling is centralized under `Jido.Evolve.Error`.

## Docs and Guides

- [Getting Started](guides/getting-started.md)
- [CHANGELOG](CHANGELOG.md)
- [CONTRIBUTING](CONTRIBUTING.md)
