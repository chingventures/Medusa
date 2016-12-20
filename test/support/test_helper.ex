defmodule Medusa.TestHelper do
  @moduledoc false

  def restart_app do
    Application.stop(:medusa)
    Application.ensure_all_started(:medusa)
  end

  def put_adapter_config(adapter) do
    import Supervisor.Spec, warn: false
    opts = [
      adapter: adapter,
      group: "test-rabbitmq",
      retry_publish_backoff: 500,
      retry_publish_max: 1,
      retry_consume_pow_base: 0,
    ]
    Application.put_env(:medusa, Medusa, opts, persistent: true)
    restart_app()
    opts
  end

  def put_rabbitmq_adapter_config do
    import Supervisor.Spec, warn: false
    opts = [
      adapter: Medusa.Adapter.RabbitMQ,
      group: "test-rabbitmq",
      retry_publish_backoff: 500,
      retry_publish_max: 1,
      retry_consume_pow_base: 0,
      RabbitMQ: %{
	connection: [
	  host: System.get_env("RABBITMQ_HOST") || "127.0.0.1",
	  username: System.get_env("RABBITMQ_USERNAME") || "guest",
	  password: System.get_env("RABBITMQ_PASSWORD") || "guest",
	]
      }

    ]
    Application.put_env(:medusa, Medusa, opts, persistent: true)
    restart_app()
    opts
  end

  def consumer_children do
    Supervisor.which_children(Medusa.ConsumerSupervisor)
  end

  def producer_children do
    Supervisor.which_children(Medusa.ProducerSupervisor)
  end

end

defmodule MyModule do
  alias Medusa.Message

  def echo(message) do
    :self |> Process.whereis |> send(message)
    :ok
  end

  def error(_) do
    :error
  end

  def reverse(%Message{body: body} = message) do
    %{message | body: String.reverse(body)}
  end

  def state(%{metadata: %{"agent" => agent, "times" => times} = metadata} = message) do
    val = agent |> String.to_atom |> Agent.get_and_update(&({&1, &1+1}))
    cond do
      metadata["bad_return"] ->
        :bad_return
      val == times && metadata["middleware"] ->
        message
      val == times ->
        :self |> Process.whereis |> send(message)
        :ok
      metadata["raise"] ->
        raise "Boom!"
      metadata["throw"] ->
        throw "Bamm!"
      metadata["http_error"] ->
        :gen_tcp.connect('bogus url', 80, [])
      true ->
        {:error, val}
    end
  end
end
