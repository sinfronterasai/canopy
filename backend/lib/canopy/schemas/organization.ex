defmodule Canopy.Schemas.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :logo_url, :string
    field :plan, :string, default: "free"
    field :settings, :map, default: %{}
    field :mission, :string
    field :description, :string
    field :issue_prefix, :string
    field :budget_monthly_cents, :integer
    field :budget_per_agent_cents, :integer
    field :budget_enforcement, :string, default: "visibility"
    field :governance, :map, default: %{}

    has_many :memberships, Canopy.Schemas.OrganizationMembership
    has_many :invitations, Canopy.Schemas.Invitation
    has_many :divisions, Canopy.Schemas.Division
    has_many :workspaces, Canopy.Schemas.Workspace

    timestamps()
  end

  def changeset(organization, attrs) do
    attrs = maybe_generate_slug(organization, attrs)

    organization
    |> cast(attrs, [
      :name,
      :slug,
      :logo_url,
      :plan,
      :settings,
      :mission,
      :description,
      :issue_prefix,
      :budget_monthly_cents,
      :budget_per_agent_cents,
      :budget_enforcement,
      :governance
    ])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/)
    |> validate_inclusion(:budget_enforcement, ~w(visibility warning stop))
    |> unique_constraint(:slug)
  end

  defp maybe_generate_slug(organization, attrs) do
    # Only append unique suffix for new organizations (where slug is nil)
    if is_nil(organization.slug) do
      case attrs do
        %{"name" => name, "slug" => slug} when is_binary(name) and (is_nil(slug) or slug == "") ->
          Map.put(attrs, "slug", append_unique_suffix(slugify(name)))

        %{"name" => name} = map when is_binary(name) ->
          Map.put_new(map, "slug", append_unique_suffix(slugify(name)))

        %{"slug" => slug} when is_binary(slug) and slug != "" ->
          Map.put(attrs, "slug", append_unique_suffix(slugify(slug)))

        %{name: name, slug: slug} when is_binary(name) and (is_nil(slug) or slug == "") ->
          Map.put(attrs, :slug, append_unique_suffix(slugify(name)))

        %{name: name} = map when is_binary(name) ->
          Map.put_new(map, :slug, append_unique_suffix(slugify(name)))

        %{slug: slug} when is_binary(slug) and slug != "" ->
          Map.put(attrs, :slug, append_unique_suffix(slugify(slug)))

        _ ->
          attrs
      end
    else
      attrs
    end
  end

  defp append_unique_suffix(slug) do
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{slug}-#{suffix}"
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
