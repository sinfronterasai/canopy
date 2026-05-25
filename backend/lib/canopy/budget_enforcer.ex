defmodule Canopy.BudgetEnforcer do
  @moduledoc """
  GenServer that enforces budget policies across the 5-layer organizational hierarchy.

  Maintains ETS tables of accumulated costs per scope (agent/team/department/division/organization/workspace).
  On each cost event, resolves the agent's full hierarchy chain and checks all applicable policies.

  Budget cascade: Agent → Team → Department → Division → Organization
  Enforcement modes per scope: visibility (track only), warning (alert), stop (block)

  The ETS tables use `:update_counter/4` for atomic increments — safe to call from
  concurrent processes without going through this GenServer.
  """
  use GenServer
  require Logger

  alias Canopy.Repo

  alias Canopy.Schemas.{
    BudgetPolicy,
    BudgetIncident,
    CostEvent,
    Agent,
    TeamMembership,
    Team,
    Department,
    Division
  }

  import Ecto.Query

  @table :canopy_budget_accumulator
  @hierarchy_cache :canopy_hierarchy_cache

  # ── Client API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a cost event and check budget policies across the hierarchy."
  def record_cost(params) do
    GenServer.cast(__MODULE__, {:record_cost, params})
  end

  @doc "Get current accumulated cost in cents for a scope."
  def get_accumulated(scope_type, scope_id) do
    case :ets.lookup(@table, {scope_type, scope_id}) do
      [{_, cents}] -> cents
      [] -> 0
    end
  end

  @doc "Reset accumulator for a scope (e.g. on month boundary or manual override)."
  def reset(scope_type, scope_id) do
    GenServer.cast(__MODULE__, {:reset, scope_type, scope_id})
  end

  @doc "Invalidate the cached hierarchy chain for an agent (call on team membership changes)."
  def invalidate_hierarchy(agent_id) do
    :ets.delete(@hierarchy_cache, agent_id)
  end

  # ── Server Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ets.new(@hierarchy_cache, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    load_current_month_costs()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:record_cost, params}, state) do
    cost = params.cost_cents
    agent_id = params.agent_id

    # 1. Persist cost event
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %CostEvent{}
    |> CostEvent.changeset(%{
      agent_id: agent_id,
      session_id: params[:session_id],
      model: params.model,
      tokens_input: params[:tokens_input] || 0,
      tokens_output: params[:tokens_output] || 0,
      tokens_cache: params[:tokens_cache] || 0,
      cost_cents: cost,
      inserted_at: now
    })
    |> Repo.insert!()

    # 2. Resolve full hierarchy chain and increment all tiers
    chain = resolve_hierarchy(agent_id)

    increment("agent", agent_id, cost)

    if chain.workspace_id, do: increment("workspace", chain.workspace_id, cost)
    if chain.team_id, do: increment("team", chain.team_id, cost)
    if chain.department_id, do: increment("department", chain.department_id, cost)
    if chain.division_id, do: increment("division", chain.division_id, cost)
    if chain.organization_id, do: increment("organization", chain.organization_id, cost)

    # 3. Check policies bottom-up at each tier
    check_policies("agent", agent_id)

    if chain.workspace_id, do: check_policies("workspace", chain.workspace_id)
    if chain.team_id, do: check_policies("team", chain.team_id)
    if chain.department_id, do: check_policies("department", chain.department_id)
    if chain.division_id, do: check_policies("division", chain.division_id)
    if chain.organization_id, do: check_policies("organization", chain.organization_id)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:reset, scope_type, scope_id}, state) do
    :ets.insert(@table, {{scope_type, scope_id}, 0})
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  # Atomic increment — safe for concurrent callers without a GenServer roundtrip.
  defp increment(scope_type, scope_id, cost_cents) do
    key = {scope_type, scope_id}
    :ets.update_counter(@table, key, {2, cost_cents}, {key, 0})
  end

  @doc false
  defp resolve_hierarchy(agent_id) do
    case :ets.lookup(@hierarchy_cache, agent_id) do
      [{_, chain}] ->
        chain

      [] ->
        chain = build_hierarchy_chain(agent_id)
        :ets.insert(@hierarchy_cache, {agent_id, chain})
        chain
    end
  end

  defp build_hierarchy_chain(agent_id) do
    # Single query with left joins to resolve the full chain
    result =
      Repo.one(
        from a in Agent,
          left_join: tm in TeamMembership,
          on: tm.agent_id == a.id,
          left_join: t in Team,
          on: tm.team_id == t.id,
          left_join: dept in Department,
          on: t.department_id == dept.id,
          left_join: div in Division,
          on: dept.division_id == div.id,
          where: a.id == ^agent_id,
          select: %{
            workspace_id: a.workspace_id,
            team_id: tm.team_id,
            department_id: t.department_id,
            division_id: dept.division_id,
            organization_id: div.organization_id
          }
      )

    result ||
      %{
        workspace_id: nil,
        team_id: nil,
        department_id: nil,
        division_id: nil,
        organization_id: nil
      }
  end

  defp check_policies(scope_type, scope_id) do
    policies =
      Repo.all(
        from p in BudgetPolicy,
          where: p.scope_type == ^scope_type and p.scope_id == ^scope_id
      )

    for policy <- policies do
      accumulated = get_accumulated(scope_type, scope_id)

      pct =
        if policy.monthly_limit_cents > 0,
          do: div(accumulated * 100, policy.monthly_limit_cents),
          else: 0

      cond do
        pct >= 100 and policy.hard_stop ->
          handle_hard_stop(policy, scope_type, scope_id, pct)

        pct >= policy.warning_threshold_pct ->
          handle_warning(policy, scope_type, scope_id, pct)

        true ->
          :ok
      end
    end
  end

  defp handle_hard_stop(policy, scope_type, scope_id, actual_pct) do
    existing =
      Repo.one(
        from bi in BudgetIncident,
          where:
            bi.policy_id == ^policy.id and bi.scope_type == ^scope_type and
              bi.scope_id == ^scope_id and bi.incident_type == "hard_stop" and
              bi.resolved == false
      )

    unless existing do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Create incident with scope info
      incident_attrs = %{
        policy_id: policy.id,
        incident_type: "hard_stop",
        threshold_pct: 100,
        actual_pct: actual_pct,
        scope_type: scope_type,
        scope_id: scope_id,
        inserted_at: now
      }

      # Set agent_id for backwards compat when scope is agent
      incident_attrs =
        if scope_type == "agent",
          do: Map.put(incident_attrs, :agent_id, scope_id),
          else: incident_attrs

      %BudgetIncident{}
      |> BudgetIncident.changeset(incident_attrs)
      |> Repo.insert!()

      # Pause affected agents
      pause_agents_in_scope(scope_type, scope_id)

      Logger.warning(
        "[BudgetEnforcer] Hard stop: #{scope_type} #{scope_id} reached #{actual_pct}% of budget"
      )

      # Broadcast to appropriate topic
      broadcast_budget_event("budget.hard_stop", scope_type, scope_id, actual_pct, policy.id)
    end
  end

  defp handle_warning(policy, scope_type, scope_id, actual_pct) do
    recent =
      Repo.one(
        from bi in BudgetIncident,
          where:
            bi.policy_id == ^policy.id and bi.scope_type == ^scope_type and
              bi.scope_id == ^scope_id and bi.incident_type == "warning" and
              bi.resolved == false
      )

    unless recent do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      incident_attrs = %{
        policy_id: policy.id,
        incident_type: "warning",
        threshold_pct: policy.warning_threshold_pct,
        actual_pct: actual_pct,
        scope_type: scope_type,
        scope_id: scope_id,
        inserted_at: now
      }

      incident_attrs =
        if scope_type == "agent",
          do: Map.put(incident_attrs, :agent_id, scope_id),
          else: incident_attrs

      %BudgetIncident{}
      |> BudgetIncident.changeset(incident_attrs)
      |> Repo.insert!()

      Logger.info(
        "[BudgetEnforcer] Warning: #{scope_type} #{scope_id} at #{actual_pct}% of budget"
      )

      broadcast_budget_event("budget.warning", scope_type, scope_id, actual_pct, policy.id)
    end
  end

  # Pause all agents within a given scope
  defp pause_agents_in_scope("agent", agent_id) do
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent ->
        agent |> Ecto.Changeset.change(status: "paused") |> Repo.update!()

      nil ->
        :ok
    end
  end

  defp pause_agents_in_scope("team", team_id) do
    agent_ids =
      Repo.all(
        from tm in TeamMembership,
          where: tm.team_id == ^team_id,
          select: tm.agent_id
      )

    if agent_ids != [] do
      from(a in Agent, where: a.id in ^agent_ids and a.status != "paused")
      |> Repo.update_all(set: [status: "paused", updated_at: DateTime.utc_now()])
    end
  end

  defp pause_agents_in_scope("department", department_id) do
    team_ids =
      Repo.all(from t in Team, where: t.department_id == ^department_id, select: t.id)

    if team_ids != [] do
      agent_ids =
        Repo.all(from tm in TeamMembership, where: tm.team_id in ^team_ids, select: tm.agent_id)

      if agent_ids != [] do
        from(a in Agent, where: a.id in ^agent_ids and a.status != "paused")
        |> Repo.update_all(set: [status: "paused", updated_at: DateTime.utc_now()])
      end
    end
  end

  defp pause_agents_in_scope("division", division_id) do
    dept_ids =
      Repo.all(from d in Department, where: d.division_id == ^division_id, select: d.id)

    if dept_ids != [] do
      team_ids =
        Repo.all(from t in Team, where: t.department_id in ^dept_ids, select: t.id)

      if team_ids != [] do
        agent_ids =
          Repo.all(from tm in TeamMembership, where: tm.team_id in ^team_ids, select: tm.agent_id)

        if agent_ids != [] do
          from(a in Agent, where: a.id in ^agent_ids and a.status != "paused")
          |> Repo.update_all(set: [status: "paused", updated_at: DateTime.utc_now()])
        end
      end
    end
  end

  defp pause_agents_in_scope("organization", organization_id) do
    div_ids =
      Repo.all(from d in Division, where: d.organization_id == ^organization_id, select: d.id)

    if div_ids != [] do
      dept_ids =
        Repo.all(from d in Department, where: d.division_id in ^div_ids, select: d.id)

      if dept_ids != [] do
        team_ids =
          Repo.all(from t in Team, where: t.department_id in ^dept_ids, select: t.id)

        if team_ids != [] do
          agent_ids =
            Repo.all(
              from tm in TeamMembership, where: tm.team_id in ^team_ids, select: tm.agent_id
            )

          if agent_ids != [] do
            from(a in Agent, where: a.id in ^agent_ids and a.status != "paused")
            |> Repo.update_all(set: [status: "paused", updated_at: DateTime.utc_now()])
          end
        end
      end
    end
  end

  defp pause_agents_in_scope("workspace", workspace_id) do
    from(a in Agent, where: a.workspace_id == ^workspace_id and a.status != "paused")
    |> Repo.update_all(set: [status: "paused", updated_at: DateTime.utc_now()])
  end

  defp pause_agents_in_scope(_scope_type, _scope_id), do: :ok

  defp broadcast_budget_event(event, "agent", agent_id, actual_pct, policy_id) do
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent ->
        Canopy.EventBus.broadcast(
          Canopy.EventBus.workspace_topic(agent.workspace_id),
          %{
            event: event,
            scope_type: "agent",
            scope_id: agent_id,
            agent_name: agent.name,
            actual_pct: actual_pct,
            policy_id: policy_id
          }
        )

      nil ->
        :ok
    end
  end

  defp broadcast_budget_event(event, scope_type, scope_id, actual_pct, policy_id) do
    Canopy.EventBus.broadcast(
      Canopy.EventBus.activity_topic(),
      %{
        event: event,
        scope_type: scope_type,
        scope_id: scope_id,
        actual_pct: actual_pct,
        policy_id: policy_id
      }
    )
  end

  defp load_current_month_costs do
    try do
      today = Date.utc_today()
      month_start = DateTime.new!(Date.new!(today.year, today.month, 1), ~T[00:00:00], "Etc/UTC")

      # Load agent-level costs
      Repo.all(
        from ce in CostEvent,
          where: ce.inserted_at >= ^month_start,
          group_by: ce.agent_id,
          select: {ce.agent_id, sum(ce.cost_cents)}
      )
      |> Enum.each(fn {agent_id, total} ->
        :ets.insert(@table, {{"agent", agent_id}, total})
      end)

      # Load workspace-level costs (aggregate via agents)
      Repo.all(
        from ce in CostEvent,
          join: a in Agent,
          on: ce.agent_id == a.id,
          where: ce.inserted_at >= ^month_start and not is_nil(a.workspace_id),
          group_by: a.workspace_id,
          select: {a.workspace_id, sum(ce.cost_cents)}
      )
      |> Enum.each(fn {workspace_id, total} ->
        :ets.insert(@table, {{"workspace", workspace_id}, total})
      end)

      # Load team-level costs (aggregate via team_memberships)
      Repo.all(
        from ce in CostEvent,
          join: tm in TeamMembership,
          on: ce.agent_id == tm.agent_id,
          where: ce.inserted_at >= ^month_start,
          group_by: tm.team_id,
          select: {tm.team_id, sum(ce.cost_cents)}
      )
      |> Enum.each(fn {team_id, total} ->
        :ets.insert(@table, {{"team", team_id}, total})
      end)

      # Load department-level costs
      Repo.all(
        from ce in CostEvent,
          join: tm in TeamMembership,
          on: ce.agent_id == tm.agent_id,
          join: t in Team,
          on: tm.team_id == t.id,
          where: ce.inserted_at >= ^month_start,
          group_by: t.department_id,
          select: {t.department_id, sum(ce.cost_cents)}
      )
      |> Enum.each(fn {dept_id, total} ->
        :ets.insert(@table, {{"department", dept_id}, total})
      end)

      # Load division-level costs
      Repo.all(
        from ce in CostEvent,
          join: tm in TeamMembership,
          on: ce.agent_id == tm.agent_id,
          join: t in Team,
          on: tm.team_id == t.id,
          join: d in Department,
          on: t.department_id == d.id,
          where: ce.inserted_at >= ^month_start,
          group_by: d.division_id,
          select: {d.division_id, sum(ce.cost_cents)}
      )
      |> Enum.each(fn {div_id, total} ->
        :ets.insert(@table, {{"division", div_id}, total})
      end)

      # Load organization-level costs
      Repo.all(
        from ce in CostEvent,
          join: tm in TeamMembership,
          on: ce.agent_id == tm.agent_id,
          join: t in Team,
          on: tm.team_id == t.id,
          join: d in Department,
          on: t.department_id == d.id,
          join: div in Division,
          on: d.division_id == div.id,
          where: ce.inserted_at >= ^month_start,
          group_by: div.organization_id,
          select: {div.organization_id, sum(ce.cost_cents)}
      )
      |> Enum.each(fn {org_id, total} ->
        :ets.insert(@table, {{"organization", org_id}, total})
      end)
    rescue
      error ->
        Logger.error("[BudgetEnforcer] Failed to load current month costs from database on boot: #{inspect(error)}")
        :ok
    end
  end
end
