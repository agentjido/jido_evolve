# Jido.Evolve

[![Hex.pm](https://img.shields.io/hexpm/v/jido_evolve.svg)](https://hex.pm/packages/jido_evolve)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/jido_evolve/)
[![CI](https://github.com/agentjido/jido_evolve/actions/workflows/ci.yml/badge.svg)](https://github.com/agentjido/jido_evolve/actions/workflows/ci.yml)

Evolutionary search over Elixir data. Applications supply candidates, fitness, and
variation rules. The package provides one generational genetic algorithm with
bounded evaluation, tournament selection, elitism, and explicit results.

No language model, Jido agent, Python runtime, or numerical backend is required.
This checkout includes changes for the next release. See the
[migration notes](guides/migration.md) before replacing an existing version.

## Install

Use this checkout while testing the next release:

```elixir
{:jido_evolve, path: "../jido_evolve"}
```

## Quick start

```elixir
defmodule BitCount do
  use Jido.Evolve.Fitness

  @impl true
  def evaluate(bits, _context), do: {:ok, Enum.sum(bits)}
end

{:ok, result} = Jido.Evolve.run(
  initial_population: [[0, 0, 1], [1, 0, 0], [0, 1, 1]],
  fitness: BitCount,
  mutation: Jido.Evolve.Mutation.Binary,
  crossover: Jido.Evolve.Crossover.Uniform,
  config: [generations: 20, max_evaluations: 63, random_seed: 42]
)

IO.inspect({result.best_entity, result.best_score, result.stop_reason})
```

`run/1` returns `{:ok, %Jido.Evolve.Result{}}` or `{:error, error}`.
`evolve/1` accepts the same options and returns a lazy stream of generation states.
Generation 0 is the evaluated initial population. `generations: 20` allows up to
20 breeding transitions and 21 complete states.

## Supported data

| Data | Mutation | Crossover |
| --- | --- | --- |
| Strings | `Mutation.Text` | `Crossover.String` |
| Binary lists | `Mutation.Binary` | `Crossover.Uniform` |
| Permutations | `Mutation.Permutation` | `Crossover.PMX` |
| Parameter maps | `Mutation.HParams` with `mutation_opts: [schema: schema]` | `Crossover.MapUniform` |
| Application data | Application callback | Application callback |

All names above are under `Jido.Evolve`. Diversity measurement is optional and off
by default. Custom data needs no protocol implementation unless that measurement
or a chosen operator uses the `Evolvable` protocol.

## Scope

The core owns search, operators, evaluation records, budgets, and results.
Applications own domain validity, fixed evaluation cases, acceptance, and promotion.
Multi-objective search, native GEPA, model calls, persistent resume, and distributed
execution are deferred.

## Guides and checks

- [Getting started and callback contracts](guides/getting-started.md)
- [Migration from the previous API](guides/migration.md)
- [Contributing](CONTRIBUTING.md)

```bash
mix quality
mix test --cover
mix docs
```
