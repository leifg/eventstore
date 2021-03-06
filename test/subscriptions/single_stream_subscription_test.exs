defmodule EventStore.Subscriptions.SingleStreamSubscriptionTest do
  use EventStore.StorageCase

  alias EventStore.{Config,EventFactory,ProcessHelper,RecordedEvent}
  alias EventStore.Storage.{Appender,CreateStream}
  alias EventStore.Subscriptions.StreamSubscription

  @subscription_name "test_subscription"

  setup do
    config = Config.parsed() |> Config.subscription_postgrex_opts()
    
    {:ok, conn} = Postgrex.start_link(config)

    on_exit fn ->
      ProcessHelper.shutdown(conn)
    end

    [
      subscription_conn: conn,
      stream_uuid: UUID.uuid4()
    ]
  end

  describe "subscribe to stream" do
    setup [:append_events_to_another_stream]

    test "create subscription to a single stream", context do
      subscription = create_subscription(context)

      assert subscription.state == :subscribe_to_events
      assert subscription.data.subscription_name == @subscription_name
      assert subscription.data.subscriber == self()
      assert subscription.data.last_seen == 0
      assert subscription.data.last_ack == 0
    end

    test "create subscription to a single stream from starting stream version", context do
      subscription = create_subscription(context, start_from_stream_version: 2)

      assert subscription.state == :subscribe_to_events
      assert subscription.data.subscription_name == @subscription_name
      assert subscription.data.subscriber == self()
      assert subscription.data.last_seen == 2
      assert subscription.data.last_ack == 2
    end

    test "create subscription to a single stream with event mapping function", context do
      mapper = fn event -> event.event_number end
      subscription = create_subscription(context, mapper: mapper)

      assert subscription.data.mapper == mapper
    end
  end

  describe "catch-up subscription on empty stream" do
    setup [:append_events_to_another_stream]

    test "should be caught up", context do
      subscription =
        create_subscription(context)
        |> StreamSubscription.subscribed()
        |> StreamSubscription.catch_up()

      assert subscription.state == :catching_up
      assert subscription.data.last_seen == 0

      assert_receive_caught_up(0)
    end
  end

  describe "catch-up subscription" do
    setup [:append_events_to_another_stream, :create_stream]

    test "unseen persisted events", %{recorded_events: recorded_events} = context do
      subscription =
        create_subscription(context)
        |> StreamSubscription.subscribed()
        |> StreamSubscription.catch_up()

      assert subscription.state == :catching_up
      assert subscription.data.last_seen == 0

      assert_receive {:events, received_events}
      subscription = ack(subscription, received_events)

      assert_receive_caught_up(3)

      expected_events = EventFactory.deserialize_events(recorded_events)

      assert pluck(received_events, :correlation_id) == pluck(expected_events, :correlation_id)
      assert pluck(received_events, :causation_id) == pluck(expected_events, :causation_id)
      assert pluck(received_events, :data) == pluck(expected_events, :data)

      assert subscription.data.last_ack == 3
    end

    test "confirm subscription caught up to persisted events", context do
      subscription =
        create_subscription(context)
        |> StreamSubscription.subscribed()
        |> StreamSubscription.catch_up()

      assert subscription.state == :catching_up
      assert subscription.data.last_seen == 0

      assert_receive {:events, received_events}
      subscription = ack(subscription, received_events)

      assert_receive_caught_up(3)

      subscription =
        subscription
        |> StreamSubscription.caught_up(3)

      assert subscription.state == :subscribed
      assert subscription.data.last_seen == 3
      assert subscription.data.last_ack == 3
    end
  end

  test "notify events", %{stream_uuid: stream_uuid} = context do
    events = EventFactory.create_recorded_events(1, stream_uuid)

    subscription =
      create_subscription(context)
      |> StreamSubscription.subscribed()
      |> StreamSubscription.catch_up()
      |> StreamSubscription.caught_up(0)
      |> StreamSubscription.notify_events(events)

    assert subscription.state == :subscribed

    assert_receive {:events, received_events}

    assert pluck(received_events, :correlation_id) == pluck(events, :correlation_id)
    assert pluck(received_events, :causation_id) == pluck(events, :causation_id)
    assert pluck(received_events, :data) == pluck(events, :data)
  end

  describe "ack events" do
    setup [:append_events_to_another_stream, :create_stream, :subscribe_to_stream]

    test "should skip events during catch up when acknowledged", %{subscription: subscription, recorded_events: events} = context do
      subscription = ack(subscription, events)

      assert subscription.state == :subscribed
      assert subscription.data.last_seen == 3
      assert subscription.data.last_ack == 3

      subscription =
        create_subscription(context)
        |> StreamSubscription.subscribed()
        |> StreamSubscription.catch_up()

      assert subscription.state == :catching_up

      # should not receive already seen events
      refute_receive {:events, _received_events}

      assert_receive_caught_up(3)
      subscription = StreamSubscription.caught_up(subscription, 3)

      assert subscription.state == :subscribed
      assert subscription.data.last_seen == 3
      assert subscription.data.last_ack == 3
    end

    test "should replay events when not acknowledged", context do
      subscription =
        create_subscription(context)
        |> StreamSubscription.subscribed()
        |> StreamSubscription.catch_up()

      assert subscription.state == :catching_up

      # should receive already seen, but not ack'd, events
      assert_receive {:events, received_events}
      assert length(received_events) == 3
      subscription = ack(subscription, received_events)

      assert_receive_caught_up(3)

      subscription = StreamSubscription.caught_up(subscription, 3)

      assert subscription.state == :subscribed
      assert subscription.data.last_seen == 3
      assert subscription.data.last_ack == 3
    end
  end

  # append events to another stream so that for single stream subscription tests the
  # event id does not match the stream version
  def append_events_to_another_stream(_context) do
    stream_uuid = UUID.uuid4()
    events = EventFactory.create_events(3)

    :ok = EventStore.append_to_stream(stream_uuid, 0, events)
  end

  defp create_stream(%{conn: conn, stream_uuid: stream_uuid}) do
    {:ok, stream_id} = CreateStream.execute(conn, stream_uuid)

    recorded_events = EventFactory.create_recorded_events(3, stream_uuid, 4)
    {:ok, [4, 5, 6]} = Appender.append(conn, stream_id, recorded_events)

    [
      recorded_events: recorded_events,
    ]
  end

  defp subscribe_to_stream(context) do
    subscription =
      create_subscription(context)
      |> StreamSubscription.subscribed()
      |> StreamSubscription.catch_up()

    assert subscription.state == :catching_up

    assert_receive {:events, received_events}
    assert length(received_events) == 3

    subscription = StreamSubscription.caught_up(subscription, 3)

    assert subscription.state == :subscribed
    assert subscription.data.last_seen == 3
    assert subscription.data.last_ack == 0

    [subscription: subscription]
  end

  test "should not notify events until ack received", %{stream_uuid: stream_uuid} = context do
    events = EventFactory.create_recorded_events(6, stream_uuid)
    initial_events = Enum.take(events, 3)
    remaining_events = Enum.drop(events, 3)

    subscription =
      create_subscription(context)
      |> StreamSubscription.subscribed()
      |> StreamSubscription.catch_up()
      |> StreamSubscription.caught_up(0)
      |> StreamSubscription.notify_events(initial_events)
      |> StreamSubscription.notify_events(remaining_events)

    assert subscription.data.last_seen == 6
    assert subscription.data.last_ack == 0

    # only receive initial events
    assert_receive {:events, received_events}
    refute_receive {:events, _received_events}

    assert length(received_events) == 3
    assert pluck(received_events, :correlation_id) == pluck(initial_events, :correlation_id)
    assert pluck(received_events, :causation_id) == pluck(initial_events, :causation_id)
    assert pluck(received_events, :data) == pluck(initial_events, :data)

    subscription = ack(subscription, received_events)

    assert subscription.state == :subscribed
    assert subscription.data.last_seen == 6
    assert subscription.data.last_ack == 3

   # now receive all remaining events
   assert_receive {:events, received_events}

   assert length(received_events) == 3
   assert pluck(received_events, :correlation_id) == pluck(remaining_events, :correlation_id)
   assert pluck(received_events, :causation_id) == pluck(remaining_events, :causation_id)
   assert pluck(received_events, :data) == pluck(remaining_events, :data)

   ack(subscription, received_events)
   refute_receive {:events, _received_events}
  end

  defp create_subscription(%{subscription_conn: conn, stream_uuid: stream_uuid}, opts \\ []) do
    StreamSubscription.new()
    |> StreamSubscription.subscribe(conn, stream_uuid, @subscription_name, self(), opts)
  end

  def ack(subscription, events) when is_list(events) do
    ack(subscription, List.last(events))
  end

  def ack(subscription, %RecordedEvent{event_number: event_number, stream_version: stream_version}) do
    StreamSubscription.ack(subscription, {event_number, stream_version})
  end

  defp assert_receive_caught_up(to) do
    assert_receive {:"$gen_cast", {:caught_up, ^to}}
  end

  defp pluck(enumerable, field) do
    Enum.map(enumerable, &Map.get(&1, field))
  end
end
