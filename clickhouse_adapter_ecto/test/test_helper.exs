# :cluster tests need docker-compose.cluster.yml. Run them with `mix test --only cluster`.
ExUnit.start(exclude: [:cluster])
