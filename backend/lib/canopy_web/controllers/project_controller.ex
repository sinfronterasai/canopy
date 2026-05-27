defmodule CanopyWeb.ProjectController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.{Project, Goal}
  import Ecto.Query

  def index(conn, params) do
    workspace_id = params["workspace_id"]

    query = from p in Project, order_by: [desc: p.updated_at]

    query =
      if workspace_id,
        do: where(query, [p], p.workspace_id == ^workspace_id),
        else: query

    projects = Repo.all(query)

    # Fetch counts for all projects in one query each
    project_ids = Enum.map(projects, & &1.id)

    goal_counts =
      if project_ids == [],
        do: %{},
        else:
          Repo.all(
            from g in Canopy.Schemas.Goal,
              where: g.project_id in ^project_ids,
              group_by: g.project_id,
              select: {g.project_id, count(g.id)}
          )
          |> Map.new()

    issue_counts =
      if project_ids == [],
        do: %{},
        else:
          Repo.all(
            from i in Canopy.Schemas.Issue,
              where: i.project_id in ^project_ids,
              group_by: i.project_id,
              select: {i.project_id, count(i.id)}
          )
          |> Map.new()

    json(conn, %{
      projects:
        Enum.map(projects, fn p ->
          serialize(p,
            goal_count: Map.get(goal_counts, p.id, 0),
            issue_count: Map.get(issue_counts, p.id, 0)
          )
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
        goal_count = Repo.aggregate(from(g in Canopy.Schemas.Goal, where: g.project_id == ^id), :count)
        issue_count = Repo.aggregate(from(i in Canopy.Schemas.Issue, where: i.project_id == ^id), :count)

        json(conn, %{
          project: serialize(project, goal_count: goal_count, issue_count: issue_count)
        })
    end
  end

  # PATCH is sent by the frontend; forward to update/2
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
    goals =
      Repo.all(
        from g in Goal,
          where: g.project_id == ^project_id,
          order_by: [asc: g.title]
      )

    # Build issue counts per goal
    goal_ids = Enum.map(goals, & &1.id)

    issue_counts =
      if goal_ids == [] do
        %{}
      else
        Canopy.Repo.all(
          from i in Canopy.Schemas.Issue,
            where: i.goal_id in ^goal_ids,
            group_by: i.goal_id,
            select: {i.goal_id, count(i.id)}
        )
        |> Map.new()
      end

    serialized = Enum.map(goals, &serialize_goal(&1, Map.get(issue_counts, &1.id, 0)))

    # Assemble flat list into parent→children tree
    by_id = Map.new(serialized, fn g -> {g.id, Map.put(g, :children, [])} end)

    tree =
      Enum.reduce(serialized, by_id, fn g, acc ->
        if g.parent_id && Map.has_key?(acc, g.parent_id) do
          Map.update!(acc, g.parent_id, fn parent ->
            Map.update(parent, :children, [acc[g.id]], fn ch -> ch ++ [acc[g.id]] end)
          end)
        else
          acc
        end
      end)

    roots =
      serialized
      |> Enum.filter(fn g -> is_nil(g.parent_id) end)
      |> Enum.map(fn g -> tree[g.id] end)

    json(conn, %{goals: roots})
  end

  def workspaces(conn, %{"project_id" => _project_id}) do
    # Projects are workspace-scoped; the parent workspace is accessible via the project record
    json(conn, %{workspaces: []})
  end

  # --- Private helpers ---

  defp serialize(%Project{} = p, opts \\ []) do
    %{
      id: p.id,
      name: p.name,
      description: p.description,
      status: p.status,
      workspace_id: p.workspace_id,
      workspace_path: nil,
      goal_count: Keyword.get(opts, :goal_count, 0),
      issue_count: Keyword.get(opts, :issue_count, 0),
      agent_count: 0,
      created_at: p.inserted_at,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp serialize_goal(%Goal{} = g, issue_count \\ 0) do
    %{
      id: g.id,
      title: g.title,
      description: g.description,
      status: g.status,
      priority: Map.get(g, :priority, "medium"),
      progress: Map.get(g, :progress, 0),
      assignee_id: Map.get(g, :assignee_id, nil),
      project_id: g.project_id,
      workspace_id: Map.get(g, :workspace_id, nil),
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
