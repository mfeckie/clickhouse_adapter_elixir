defmodule Stress.Repo do
  @moduledoc """
  The `Ecto.Repo` the load-generation harness (`mix stress.load`) drives
  queries through -- see that task's moduledoc for pool-sizing rationale
  and start options. Not started as part of the `:stress` application's
  supervision tree (there is no default `application` list entry for it):
  `mix stress.load` starts it itself with a pool sized for the specific
  concurrency levels that run asks for, same reasoning
  `clickhouse_adapter_ecto`'s own integration tests have for starting
  their `TestRepo`s ad hoc (see `repo_test.exs`) rather than via
  `config.exs`.
  """

  use Ecto.Repo, otp_app: :stress, adapter: Ecto.Adapters.ClickHouse
end

defmodule Stress.PageView do
  @moduledoc """
  Ecto schema for the `page_views` fact table seeded by `mix stress.seed`
  -- see `Stress`'s moduledoc for the full column list/engine definition.
  `@primary_key false` matches this repo's convention for ClickHouse
  schemas (see `clickhouse_adapter_ecto/test/integration/repo_test.exs`):
  ClickHouse's `MergeTree` family has no auto-incrementing/generated
  primary key for Ecto to manage.
  """

  use Ecto.Schema

  @primary_key false
  schema "page_views" do
    field(:id, :integer)
    field(:viewed_at, :naive_datetime)
    field(:user_id, :integer)
    field(:product_id, :integer)
    field(:region, :string)
    field(:device, :string)
    field(:session_duration_ms, :integer)
    field(:revenue_cents, :integer)
  end
end

defmodule Stress.Product do
  @moduledoc "Ecto schema for the `products` dimension table seeded by `mix stress.seed`."

  use Ecto.Schema

  @primary_key false
  schema "products" do
    field(:product_id, :integer)
    field(:category, :string)
    field(:price_cents, :integer)
  end
end

defmodule Stress.User do
  @moduledoc "Ecto schema for the `users` dimension table seeded by `mix stress.seed`."

  use Ecto.Schema

  @primary_key false
  schema "users" do
    field(:user_id, :integer)
    field(:signup_date, :date)
    field(:plan_tier, :string)
  end
end
