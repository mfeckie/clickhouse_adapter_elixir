defmodule Ecto.Adapters.ClickHouse.TestSupport.Ports do
  @moduledoc false

  # Host ports published by docker-compose.yml / docker-compose.cluster.yml.
  # The defaults deliberately avoid ClickHouse's and Kafka's well-known ports
  # (9000/8123/9092) so the test stack can run alongside other local
  # containers; keep them in sync with the `${VAR:-default}` values in the
  # compose files. Read at runtime, not into module attributes, so changing
  # an env var takes effect without recompiling test/support.

  @doc false
  def clickhouse, do: env_port("CH_NATIVE_PORT", 29000)

  @doc false
  def kafka, do: env_port("KAFKA_HOST_PORT", 39092)

  @doc false
  def cluster_replica(1), do: env_port("CH_CLUSTER_PORT_1", 29001)
  def cluster_replica(2), do: env_port("CH_CLUSTER_PORT_2", 29002)

  defp env_port(var, default) do
    case System.get_env(var) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end
end
