defmodule EventStore.Subscriptions.Supervisor do
  @moduledoc """
  Supervise zero, one or more subscriptions to an event stream.
  """

  use Supervisor

  alias EventStore.Subscriptions.Subscription

  def start_link(postgrex_config) do
    Supervisor.start_link(__MODULE__, postgrex_config, name: __MODULE__)
  end

  def subscribe_to_stream(stream_uuid, subscription_name, subscriber, subscription_opts) do
    name = {:via, Registry, registry_name(stream_uuid, subscription_name)}

    Supervisor.start_child(__MODULE__, [stream_uuid, subscription_name, subscriber, subscription_opts, [name: name]])
  end

  def unsubscribe_from_stream(stream_uuid, subscription_name) do
    name = registry_name(stream_uuid, subscription_name)

    case Registry.whereis_name(name) do
      :undefined -> :ok
      subscription ->
        :ok = Subscription.unsubscribe(subscription)
        :ok = Supervisor.terminate_child(__MODULE__, subscription)
    end
  end

  def init(postgrex_config) do
    children = [
      worker(Subscription, [postgrex_config], restart: :temporary),
    ]

    supervise(children, strategy: :simple_one_for_one)
  end

  defp registry_name(stream_uuid, subscription_name) do
    {Subscription, {stream_uuid, subscription_name}}
  end
end
