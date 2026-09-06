# Étape 4: recompute the rollover chain after a transaction retroactively
# changes what a budget category's actual_spending was for a past period.
# actual_spending itself is always live (IncomeStatement-derived, never
# cached), but rolled_over_amount/adjustments_balance ARE materialized once
# by Budget::RolloverCalculator and stored -- so without this, recategorizing,
# editing, deleting, splitting, or bulk-importing transactions leaves those
# columns silently stale until someone happens to revisit that exact budget
# page again.
#
# Same debounce shape as IdentifyRecurringTransactionsJob, for the same
# reason: a single sync/import/bulk-edit can touch hundreds of entries in
# seconds, and only the last one needs to actually trigger the recompute.
class RecomputeBudgetRolloverJob < ApplicationJob
  queue_as :default

  DEBOUNCE_DELAY = 30.seconds

  def perform(family_id, user_id, scheduled_at)
    family = Family.find_by(id: family_id)
    return unless family

    latest_scheduled = Rails.cache.read(self.class.cache_key(family_id, user_id))
    return if latest_scheduled && latest_scheduled > scheduled_at

    # A sync in progress will keep writing entries for a while yet; let its
    # own trailing call (or the next one) be the one that actually runs.
    return if Sync.any_incomplete_for?(family)

    user = user_id ? User.find_by(id: user_id) : nil
    Budget::RolloverCalculator.new(family: family, user: user).recompute!
  end

  # IDs, not objects: this is called from Entry/Transaction after_commit
  # hooks on every relevant save, and `family:`/`user:` objects would each
  # cost a real association load there for no benefit -- perform (run once,
  # 30 seconds later, off the request path) re-derives the real records from
  # these same IDs anyway.
  def self.schedule_for(family_id:, user_id: nil)
    scheduled_at = Time.current.to_f

    Rails.cache.write(cache_key(family_id, user_id), scheduled_at, expires_in: DEBOUNCE_DELAY + 10.seconds)
    set(wait: DEBOUNCE_DELAY).perform_later(family_id, user_id, scheduled_at)
  end

  # A transaction's account has exactly one family but, on a family with
  # personal budgets on, may also feed one member's own chain alongside the
  # shared household one -- both get a (cheap-if-irrelevant) recompute rather
  # than working out which one actually applies. `if account.owner_id` is a
  # defensive guard, not a real branch: Account#assign_default_owner backfills
  # one on every save, so an owner-less account shouldn't actually occur.
  # `_id` reads throughout: `account` is already loaded, so these are plain
  # attribute reads, not the association-loading queries `account.family`/
  # `account.owner` would each be.
  def self.schedule_for_account(account)
    schedule_for(family_id: account.family_id)
    schedule_for(family_id: account.family_id, user_id: account.owner_id) if account.owner_id
  end

  def self.cache_key(family_id, user_id)
    "budget_rollover_recompute:#{family_id}:#{user_id}"
  end
end
