defmodule CanopyWeb.ProjectController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.{Project, Goal, Issue}
  import Ecto.Query

  def index(conn, params) do
    workspace_id = params["workspace_id"]

    base = from(p in Project, order_by: [desc: p.updated_at])

    query =
      if workspace_id,
        do: where(base, [p], p.workspace_id == ^workspace_id),
        else: base

    projects = Repo.all(query)
    project_ids = Enum.map(projects, & &1.id)

    goal_counts = goal_counts(project_ids)
    issue_counts = issue_counts_by_project(project_ids)

    json(conn, %{
      projects:
        Enum.map(projects, fn p ->
          serialize(p, Map.get(goal_counts, p.id, 0), Map.get(issue_counts, p.id, 0))
        end)
    })
  end

  def create(conn, params) do
    changeset = Project.changeset(%Project{}, params)

    case Repo.insert(changeset) do
      {:ok, project} ->
        conn |> put_status(201) |> json(%{project: serialize(project)})

      {:error, cs} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(cs)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Repo.get(Project, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      project ->
        gc = Repo.aggregate(from(g in Goal, where: g.project_id == ^id), :count)
        ic = Repo.aggregate(from(i in Issue, where: i.project_id == ^id), :count)
        json(conn, %{project: serialize(project, gc, ic)})
    end
  end

  # PATCH alias — Phoenix resources generates PUT; frontend sends PATCH
  def patch(conn, params), do: update(conn, params)

  def update(conn, %{"id" => id} = params) do
    case Repo.get(Project, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      project ->
        changeset = Project.changeset(project, params)

        case Repo.update(changeset) do
          {:ok, updated} ->
            json(conn, %{project: serialize(updated)})

          {:error, cs} ->
            conn
            |> put_status(422)
            |> json(%{error: "validation_failed", details: format_errors(cs)})
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    case Repo.get(Project, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      project ->
        Repo.delete!(project)
        json(conn, %{ok: true})
    end
  end

  def goals(conn, %{"project_id" => project_id}) do
    flat_goals = Repo.all(from(g in Goal, where: g.project_id == ^project_id, order_by: [asc: g.title]))
    goal_ids = Enum.map(flat_goals, & &1.id)

    issue_counts = issue_counts_by_goal(goal_ids)

    serialized = Enum.map(flat_goals, fn g ->
      serialize_goal(g, Map.get(issue_counts, g.id, 0))
    end)

    roots = build_tree(serialized)
    json(conn, %{goals: roots})
  end

  def workspaces(conn, %{"project_id" => _project_id}) do
    json(conn, %{workspaces: []})
  end

  # --- Private helpers ---

  defp goal_counts([]), do: %{}
  defp goal_counts(project_ids) do
    Repo.all(
      from(g in Goal,
        where: g.project_id in ^project_ids,
        group_by: g.project_id,
        select: {g.project_id, count(g.id)}
      )
    )
    |> Map.new()
  end

  defp issue_counts_by_project([]), do: %{}
  defp issue_counts_by_project(project_ids) do
    Repo.all(
      from(i in Issue,
        where: i.project_id in ^project_ids,
        group_by: i.project_id,
        select: {i.project_id, count(i.id)}
      )
    )
    |> Map.new()
  end

  defp issue_counts_by_goal([]), do: %{}
  defp issue_counts_by_goal(goal_ids) do
    Repo.all(
      from(i in Issue,
        where: i.goal_id in ^goal_ids,
        group_by: i.goal_id,
        select: {i.goal_id, count(i.id)}
      )
    )
    |> Map.new()
  end

  # Build a parent->children tree from a flat list of serialized goal maps
  defp build_tree(flat) do
    by_id = Map.new(flat, fn g -> {g.id, g} end)

    by_id =
      Enum.reduce(flat, by_id, fn g, acc ->
        parent_id = g.parent_id

        if parent_id && Map.has_key?(acc, parent_id) do
          Map.update!(acc, parent_id, fn parent ->
            %{parent | children: parent.children ++ [acc[g.id]]}
          end)
        else
          acc
        end
      end)

    flat
    |> Enum.filter(fn g -> is_nil(g.parent_id) end)
    |> Enum.map(fn g -> by_id[g.id] end)
  end

  defp serialize(project, goal_count \\ 0, issue_count \\ 0)

  defp serialize(%Project{} = p, goal_count, issue_count) do
    %{
      id: p.id,
      name: p.name,
      description: p.description,
      status: p.status,
      workspace_id: p.workspace_id,
      workspace_path: nil,
      goal_count: goal_count,
      issue_count: issue_count,
      agent_count: 0,
      created_at: p.inserted_at,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp serialize_goal(%Goal{} = g, issue_count) do
    %{
      id: g.id,
      title: g.title,
      description: g.description,
      status: g.status || "active",
      priority: "medium",
      progress: 0,
      assignee_id: nil,
      project_id: g.project_id,
      workspace_id: g.workspace_id,
      parent_id: g.parent_id,
      issue_count: issue_count,
      children: [],
      created_at: g.inserted_at,
      inserted_at: g.inserted_at,
      updated_at: g.updated_at
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
