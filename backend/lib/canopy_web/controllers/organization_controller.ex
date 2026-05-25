defmodule CanopyWeb.OrganizationController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.{Organization, OrganizationMembership}
  import Ecto.Query

  def index(conn, params) do
    user_id = params["user_id"] || (conn.assigns[:current_user] && conn.assigns[:current_user].id)

    query =
      if user_id do
        from o in Organization,
          join: m in OrganizationMembership,
          on: m.organization_id == o.id and m.user_id == ^user_id,
          order_by: [asc: o.name]
      else
        from o in Organization, order_by: [asc: o.name]
      end

    orgs = Repo.all(query)
    json(conn, %{organizations: Enum.map(orgs, &serialize/1)})
  end

  def create(conn, params) do
    user_id = params["created_by"] || (conn.assigns[:current_user] && conn.assigns[:current_user].id)
    changeset = Organization.changeset(%Organization{}, params)

    case Repo.insert(changeset) do
      {:ok, org} ->
        # Auto-add creator as admin member
        if user_id do
          %OrganizationMembership{}
          |> OrganizationMembership.changeset(%{
            "organization_id" => org.id,
            "user_id" => user_id,
            "role" => "admin"
          })
          |> Repo.insert()
        end

        conn |> put_status(201) |> json(%{organization: serialize(org)})

      {:error, cs} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(cs)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Repo.get(Organization, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      org ->
        member_count =
          Repo.aggregate(
            from(m in OrganizationMembership, where: m.organization_id == ^id),
            :count
          )

        json(conn, %{organization: serialize(org) |> Map.put(:member_count, member_count)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Repo.get(Organization, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      org ->
        changeset = Organization.changeset(org, params)

        case Repo.update(changeset) do
          {:ok, updated} ->
            json(conn, %{organization: serialize(updated)})

          {:error, cs} ->
            conn
            |> put_status(422)
            |> json(%{error: "validation_failed", details: format_errors(cs)})
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    case Repo.get(Organization, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      org ->
        Repo.delete!(org)
        json(conn, %{ok: true})
    end
  end

  def members(conn, %{"organization_id" => id}) do
    case Repo.get(Organization, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      _org ->
        memberships =
          Repo.all(
            from m in OrganizationMembership,
              where: m.organization_id == ^id,
              order_by: [asc: m.inserted_at]
          )

        json(conn, %{members: Enum.map(memberships, &serialize_member/1)})
    end
  end

  # --- Private helpers ---

  defp serialize(%Organization{} = o) do
    %{
      id: o.id,
      name: o.name,
      slug: o.slug,
      logo_url: o.logo_url,
      plan: o.plan,
      settings: o.settings,
      mission: o.mission,
      description: o.description,
      issue_prefix: o.issue_prefix,
      budget_monthly_cents: o.budget_monthly_cents,
      budget_per_agent_cents: o.budget_per_agent_cents,
      budget_enforcement: o.budget_enforcement,
      governance: o.governance,
      created_at: o.inserted_at,
      inserted_at: o.inserted_at,
      updated_at: o.updated_at
    }
  end

  defp serialize_member(%OrganizationMembership{} = m) do
    %{
      id: m.id,
      organization_id: m.organization_id,
      user_id: m.user_id,
      role: m.role,
      inserted_at: m.inserted_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
