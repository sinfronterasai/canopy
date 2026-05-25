defmodule Canopy.Workflows.Scheduler do
  @moduledoc """
  Scheduled workflow trigger.

  On startup, loads all workflows with `trigger_type: "schedule"` and
  `status: "active"` and registers them as Quantum jobs, reusing the same
  Quantum dependency that the heartbeat `Canopy.Scheduler` uses.

  Cron expression is read from `workflow.trigger_config["cron"]`.
  Timezone is read from `workflow.trigger_config["timezone"]` (defaults to "UTC").
  If no cron is given, falls back to `trigger_config["interval_seconds"]` as a
  simple `:timer.send_interval` ticker (stored per workflow in the GenServer state).

  ## PubSub Events
    - `"workflow.scheduled_run"` on `"workflow:<id>"` topic whenever a run is triggered.
  """

  use GenServer
  require Logger

  alias Canopy.Repo
  alias Canopy.Schemas.Workflow
  alias Canopy.EventBus
  import Ecto.Query

  defstruct interval_timers: %{}

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Reload all scheduled workflows from DB (call after create/update/delete)."
  def reload do
    GenServer.cast(__MODULE__, :reload)
  end

  @doc "Register a single workflow for scheduling."
  def register(workflow_id) do
    GenServer.cast(__MODULE__, {:register, workflow_id})
  end

  @doc "Deregister a workflow (e.g., when archived or set to non-schedule trigger)."
  def deregister(workflow_id) do
    GenServer.cast(__MODULE__, {:deregister, workflow_id})
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Delay initial load until after the DB is available (post-start via send_after)
    Process.send_after(self(), :load_schedules, 2_000)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:load_schedules, state) do
    new_state = load_all_schedules(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:interval_trigger, workflow_id}, state) do
    trigger_workflow(workflow_id, "schedule")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reload, state) do
    # Cancel all existing interval timers before reloading
    Enum.each(state.interval_timers, fn {_, ref} -> :timer.cancel(ref) end)
    Canopy.Scheduler.jobs() |> Enum.each(fn {name, _} -> Canopy.Scheduler.delete_job(name) end)
    new_state = load_all_schedules(%__MODULE__{})
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:register, workflow_id}, state) do
    case Repo.get(Workflow, workflow_id) do
      nil ->
        Logger.warning(
          "[Workflows.Scheduler] Workflow #{workflow_id} not found — skipping register"
        )

        {:noreply, state}

      workflow ->
        new_state = schedule_workflow(workflow, state)
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:deregister, workflow_id}, state) do
    # Cancel interval timer if present
    {ref, new_timers} = Map.pop(state.interval_timers, workflow_id)
    if ref, do: :timer.cancel(ref)

    # Remove Quantum job if present
    Canopy.Scheduler.delete_job(workflow_job_name(workflow_id))

    {:noreply, %{state | interval_timers: new_timers}}
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp load_all_schedules(state) do
    try do
      workflows =
        Repo.all(
          from w in Workflow,
            where: w.trigger_type == "schedule" and w.status == "active"
        )

      Logger.info("[Workflows.Scheduler] Loading #{length(workflows)} scheduled workflows")

      Enum.reduce(workflows, state, &schedule_workflow/2)
    rescue
      error ->
        Logger.error("[Workflows.Scheduler] Failed to load scheduled workflows from database: #{inspect(error)}")
        state
    end
  end

  defp schedule_workflow(%Workflow{} = workflow, state) do
    cron_expr = get_in(workflow.trigger_config, ["cron"])
    interval_seconds = get_in(workflow.trigger_config, ["interval_seconds"])
    timezone = get_in(workflow.trigger_config, ["timezone"]) || "UTC"

    cond do
      is_binary(cron_expr) and cron_expr != "" ->
        schedule_cron(workflow, cron_expr, timezone, state)

      is_integer(interval_seconds) and interval_seconds > 0 ->
        schedule_interval(workflow, interval_seconds, state)

      true ->
        Logger.warning(
          "[Workflows.Scheduler] Workflow #{workflow.id} has no valid cron or interval — skipping"
        )

        state
    end
  end

  defp schedule_cron(%Workflow{} = workflow, cron_expr, timezone, state) do
    job_name = workflow_job_name(workflow.id)

    case Crontab.CronExpression.Parser.parse(cron_expr) do
      {:ok, cron} ->
        job =
          Canopy.Scheduler.new_job()
          |> Quantum.Job.set_name(job_name)
          |> Quantum.Job.set_schedule(cron)
          |> Quantum.Job.set_timezone(timezone)
          |> Quantum.Job.set_task(fn -> trigger_workflow(workflow.id, "schedule") end)

        Canopy.Scheduler.delete_job(job_name)
        Canopy.Scheduler.add_job(job)

        Logger.debug(
          "[Workflows.Scheduler] Registered cron job #{job_name} (#{cron_expr}, tz=#{timezone})"
        )

        state

      {:error, reason} ->
        Logger.error(
          "[Workflows.Scheduler] Invalid cron '#{cron_expr}' for workflow #{workflow.id}: #{inspect(reason)}"
        )

        state
    end
  end

  defp schedule_interval(%Workflow{} = workflow, interval_seconds, state) do
    # Cancel any existing timer for this workflow first
    case Map.get(state.interval_timers, workflow.id) do
      nil -> :ok
      ref -> :timer.cancel(ref)
    end

    {:ok, ref} =
      :timer.send_interval(interval_seconds * 1_000, self(), {:interval_trigger, workflow.id})

    Logger.debug(
      "[Workflows.Scheduler] Registered interval job for workflow #{workflow.id} (every #{interval_seconds}s)"
    )

    %{state | interval_timers: Map.put(state.interval_timers, workflow.id, ref)}
  end

  defp trigger_workflow(workflow_id, trigger_event) do
    Logger.info("[Workflows.Scheduler] Triggering scheduled run for workflow #{workflow_id}")

    case Canopy.Workflows.Engine.start_run(workflow_id, %{
           "trigger_event" => trigger_event,
           "input" => %{}
         }) do
      {:ok, run} ->
        EventBus.broadcast("workflow:#{workflow_id}", %{
          event: "workflow.scheduled_run",
          workflow_id: workflow_id,
          run_id: run.id,
          trigger_event: trigger_event
        })

      {:error, reason} ->
        Logger.error(
          "[Workflows.Scheduler] Failed to trigger run for workflow #{workflow_id}: #{inspect(reason)}"
        )
    end
  end

  defp workflow_job_name(workflow_id), do: String.to_atom("workflow_#{workflow_id}")
end
