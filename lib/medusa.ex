defmodule Medusa do
  use Application
  require Logger
  import Supervisor.Spec, warn: false

  @available_adapters [Medusa.Adapter.PG2,
                       Medusa.Adapter.RabbitMQ]
  @default_adapter Medusa.Adapter.PG2

  @moduledoc """
  Medusa is a Pub/Sub system that leverages GenStage.

  You should declare routes in `String` like
  the following examples:

  ```
  Medusa.consume "foo.bar", &Honey.doo/1   # Matches only "foo.bar" events.
  Medusa.consume "foo.*" &Lmbd.bo/1        # Matches all "foo. ..." events
  ```

  Then, to publish something, you call:

  ```
  Medusa.publish "foo.bar", my_awesome_payload
  ```

  ## Caveats

  It can only consume functions of arity 1.

  """

  def start(_type, _args) do
    ensure_config_correct()
    {:ok, supervisor} = Supervisor.start_link([], [strategy: :one_for_one, name: Medusa.Supervisor])

    # MedusaConfig needs to be started before child_adapter is called
    {:ok, _} = Supervisor.start_child(supervisor, config_worker)
    children =
      [
        child_adapter(),
        child_queue(),
        supervisor(Task.Supervisor, [[name: Broker.Supervisor]]),
        supervisor(Medusa.ProducerConsumerSupervisor, [])
      ]
      |> List.flatten

    Enum.each children, fn (child) -> Supervisor.start_child(supervisor, child) end
    {:ok, supervisor}
  end

  def consume(route, functions, opts \\ []) do
    case validate_consume_function(functions) do
      :ok ->
        Medusa.Broker.new_route(route, functions, opts)
      {:error, reason} ->
        Logger.warn("#{inspect reason}")
        {:error, reason}
    end
  end

  def publish(event, payload, metadata \\ %{}, opts \\ []) do
    metadata =
      metadata
      |> Enum.reduce(%{}, fn{key, val}, acc ->
        Map.put(acc, to_string(key), val)
      end)
    metadata =
      %{"id" => UUID.uuid4}
      |> Map.merge(metadata)
      |> Map.put("event", event)
    opts
    |> Keyword.get(:message_validators, [])
    |> validate_message(event, payload, metadata)
    |> case do
      :ok ->
        Medusa.Broker.publish(event, payload, metadata)
      {:error, reason} ->
        Logger.warn "Message failed validation #{inspect reason}: #{event} #{inspect payload} #{inspect metadata}"
        {:error, "message is invalid"}
    end
  end

  def adapter do
    MedusaConfig.get_adapter(:medusa_config)
  end

  def config, do: Application.get_env(:medusa, Medusa)

  @doc """
  Validate message againts list of functions.
  function must be arity/3 (event, payload, metadata).
  return :ok if valid and {:error, reason} if invalid.
  validate_message always execute global_validator first if provided.
  global_validator set by

      config :medusa, Medusa,
        validate_message: &function/3
  """
  def validate_message(functions, event, payload, metadata) do
    global_validator = MedusaConfig.get_message_validator(:medusa_config)
    functions =
      cond do
        is_function(global_validator) -> [global_validator|List.wrap(functions)]
        true -> List.wrap(functions)
      end
    do_validate_message(functions, event, payload, metadata)
  end

  defp child_adapter do
    adapter
    |> worker([])
  end

  defp child_queue do
    case adapter do
      Medusa.Adapter.PG2 -> worker(Medusa.Queue, [])
      _ -> []
    end
  end

  defp config_worker do
    env = Application.get_env(:medusa, Medusa)
    worker(MedusaConfig, [%{
      adapter: env[:adapter],
      message_validator: env[:message_validator]
    }])
  end

  defp ensure_config_correct do
    app_config = Application.get_env(:medusa, Medusa, [])
    adapter = Keyword.get(app_config, :adapter)
    cond do
      adapter in @available_adapters ->
        :ok
      true ->
        new_app_config = Keyword.merge(app_config, [adapter: @default_adapter])
        Application.put_env(:medusa, Medusa, new_app_config, persistent: true)
    end
  end

  defp validate_consume_function(function) when is_function(function) do
    validate_consume_function([function])
  end

  defp validate_consume_function([]) do
    :ok
  end

  defp validate_consume_function([function|tail]) when is_function(function) do
    case :erlang.fun_info(function, :arity) do
      {:arity, 1} -> validate_consume_function(tail)
      _ -> {:error, "arity must be 1"}
    end
  end

  defp validate_consume_function(_) do
    {:error, "consume must be function"}
  end

  defp do_validate_message([], _, _, _) do
    :ok
  end

  defp do_validate_message([function|tail], event, payload, metadata)
  when is_function(function) do
    case apply(function, [event, payload, metadata]) do
      :ok -> do_validate_message(tail, event, payload, metadata)
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  end

  defp do_validate_message(_, _, _, _) do
    {:error, "validator is not a function"}
  end

end
