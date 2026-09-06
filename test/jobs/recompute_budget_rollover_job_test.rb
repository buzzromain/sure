require "test_helper"

class RecomputeBudgetRolloverJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @scheduled_at = Time.current.to_f
  end

  test "skips when family is missing" do
    Budget::RolloverCalculator.any_instance.expects(:recompute!).never

    RecomputeBudgetRolloverJob.new.perform(SecureRandom.uuid, nil, @scheduled_at)
  end

  test "skips while a provider sync is in flight" do
    coinbase_item = @family.coinbase_items.create!(
      name: "Coinbase Pro",
      api_key: "test-api-key-#{SecureRandom.hex(4)}",
      api_secret: "test-api-secret-#{SecureRandom.hex(8)}"
    )
    Sync.create!(syncable: coinbase_item, status: :syncing)

    Budget::RolloverCalculator.any_instance.expects(:recompute!).never

    RecomputeBudgetRolloverJob.new.perform(@family.id, nil, @scheduled_at)
  end

  test "recomputes the household chain when no syncs are in flight" do
    Sync.for_family(@family).incomplete.find_each(&:destroy)

    Budget::RolloverCalculator.expects(:new).with(family: @family, user: nil).returns(stub(recompute!: nil))

    RecomputeBudgetRolloverJob.new.perform(@family.id, nil, @scheduled_at)
  end

  test "recomputes a specific member's personal chain when a user_id is given" do
    Sync.for_family(@family).incomplete.find_each(&:destroy)
    user = users(:family_admin)

    Budget::RolloverCalculator.expects(:new).with(family: @family, user: user).returns(stub(recompute!: nil))

    RecomputeBudgetRolloverJob.new.perform(@family.id, user.id, @scheduled_at)
  end

  test "skips when a newer scheduled run supersedes this one" do
    # Rails.cache is NullStore in the test env (writes are no-ops), so stub
    # the read directly to simulate a newer scheduled-at landing in the
    # cache between this job being enqueued and being picked up.
    cache_key = RecomputeBudgetRolloverJob.cache_key(@family.id, nil)
    Rails.cache.stubs(:read).with(cache_key).returns(@scheduled_at + 10)

    Budget::RolloverCalculator.any_instance.expects(:recompute!).never

    assert_nil RecomputeBudgetRolloverJob.new.perform(@family.id, nil, @scheduled_at)
  end

  test "schedule_for enqueues a debounced job for the household chain by default" do
    RecomputeBudgetRolloverJob.schedule_for(family_id: @family.id)

    enqueued = enqueued_jobs.last
    assert_equal "RecomputeBudgetRolloverJob", enqueued["job_class"]
    assert_equal [ @family.id, nil ], enqueued["arguments"][0..1]
    assert_in_delta RecomputeBudgetRolloverJob::DEBOUNCE_DELAY, Time.parse(enqueued["scheduled_at"]) - Time.current, 2
  end

  test "schedule_for_account schedules both the household chain and the owner's personal chain" do
    account = accounts(:depository)
    account.update!(owner: users(:family_admin))

    RecomputeBudgetRolloverJob.schedule_for_account(account)

    scheduled = enqueued_jobs.select { |j| j["job_class"] == "RecomputeBudgetRolloverJob" }
    scheduled_args = scheduled.map { |j| j["arguments"][0..1] }

    assert_includes scheduled_args, [ account.family.id, nil ]
    assert_includes scheduled_args, [ account.family.id, account.owner.id ]
  end
end
