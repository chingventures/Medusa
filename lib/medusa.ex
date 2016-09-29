defmodule Medusa do
  use Application
  require Logger

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

  @misconfiguration_error """
    Oops... looks like Medusa is not configured.
    Please, check if you have a line like this in your configuration:

    config :medusa, Medusa,
            adapter: Medusa.Adapter.Local

    Medusa has support for other adapers. Check them in Hex.
    Don't worry, she will not turn you into stone... yet.
  """


  # Check if configuration exists.
  unless Application.get_env(:medusa, Medusa) do
    raise @misconfiguration_error
  end

  unless Keyword.get(Application.get_env(:medusa, Medusa), :adapter) do
    raise @misconfiguration_error
  end


  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
      worker(Medusa.Broker, []),
      supervisor(Task.Supervisor, [[name: Broker.Supervisor]]),
      supervisor(Medusa.Supervisors.Producers, []),
      supervisor(Medusa.Supervisors.Consumers, [])
    ] |> start_local_adapter_if_configured

    opts = [strategy: :one_for_one, name: Medusa.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def start_local_adapter_if_configured(children) do
    import Supervisor.Spec, warn: false

    if Keyword.get(Application.get_env(:medusa, Medusa), :adapter) == Medusa.Adapter.Local do
      [worker(Medusa.Adapter.Local, []) | children]
    end
  end

  def consume(route, function, opts \\ []) do
    # Register an route on the Broker
    Medusa.Broker.new_route(route)

    # Can't use PID here, because we need to register by name.
    producer = Medusa.Supervisors.Producers.start_child(route)
    opts = build_exit_strategy opts, producer
    Medusa.Supervisors.Consumers.start_child(function, route, opts)
  end

  def publish(event, payload, metadata \\ %{}) do
    Medusa.Broker.publish event, payload, metadata
  end

  defp build_exit_strategy(opts, producer_start_result) do
    build_exit_strategy opts[:bind_once], opts, producer_start_result
  end

  defp build_exit_strategy(true, opts, {:ok, pid}) do
    Keyword.put opts, :bind_once, :full
  end
  defp build_exit_strategy(true, opts, {:error, {:already_started, pid}}) do
    Keyword.put opts, :bind_once, :only_consumer
  end
  defp build_exit_strategy(_, opts, _) do
    opts
  end

end
