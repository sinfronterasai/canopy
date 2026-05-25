defmodule Canopy.Schemas.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :slug, :string
    field :name, :string
    field :role, :string
    field :adapter, :string
    field :model, :string
    field :temperature, :float, default: 0.3
    field :max_concurrent_runs, :integer, default: 1
    field :status, :string, default: "sleeping"
    field :config, :map, default: %{}
    field :system_prompt, :string
    field :avatar_emoji, :string, default: "🤖"
    field :last_session_summary, :string
    field :session_continuity, :map, default: %{}

    belongs_to :workspace, Canopy.Schemas.Workspace
    belongs_to :reports_to_agent, Canopy.Schemas.Agent, foreign_key: :reports_to
    belongs_to :team, Canopy.Schemas.Team
    has_many :sessions, Canopy.Schemas.Session
    has_many :schedules, Canopy.Schemas.Schedule
    has_many :app_permissions, Canopy.Schemas.AppPermission
    has_many :tool_permissions, Canopy.Schemas.ToolPermission
    has_many :agent_apps, Canopy.Schemas.AgentApp
    many_to_many :skills, Canopy.Schemas.Skill, join_through: "agent_skills"

    timestamps()
  end

  def changeset(agent, attrs) do
    attrs = maybe_generate_slug(attrs)

    agent
    |> cast(attrs, [
      :id,
      :slug,
      :name,
      :role,
      :adapter,
      :model,
      :temperature,
      :max_concurrent_runs,
      :status,
      :config,
      :system_prompt,
      :workspace_id,
      :reports_to,
      :avatar_emoji,
      :team_id,
      :last_session_summary,
      :session_continuity
    ])
    |> validate_required([:slug, :name, :role, :adapter, :model, :workspace_id])
    |> validate_inclusion(:status, ~w(active idle working running sleeping error paused))
    |> validate_inclusion(
      :adapter,
      ~w(osa claude-code codex bash http openclaw cursor gemini aider jido-claw windsurf)
    )
    |> unique_constraint([:workspace_id, :slug])
  end

  defp maybe_generate_slug(attrs) do
    case attrs do
      %{"name" => name, "slug" => slug} when is_binary(name) and (is_nil(slug) or slug == "") ->
        Map.put(attrs, "slug", slugify(name))

      %{"name" => name} = map when is_binary(name) ->
        Map.put_new(map, "slug", slugify(name))

      %{name: name, slug: slug} when is_binary(name) and (is_nil(slug) or slug == "") ->
        Map.put(attrs, :slug, slugify(name))

      %{name: name} = map when is_binary(name) ->
        Map.put_new(map, :slug, slugify(name))

      _ ->
        attrs
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
