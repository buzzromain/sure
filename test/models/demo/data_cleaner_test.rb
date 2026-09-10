require "test_helper"

class Demo::DataCleanerTest < ActiveSupport::TestCase
  # A demo family carries a fake stripe_id ("sub_demo_123", see
  # Demo::Generator#create_family_and_users!). Family::Subscribeable's
  # before_destroy tries to cancel it through the real Stripe provider,
  # fails, and throws :abort -- which silently no-ops the whole
  # Family.destroy_all cascade below it (accounts/entries/trades survive)
  # instead of raising, only surfacing later as a NOT NULL crash in
  # Security.destroy_all. Isolated here at the Family#destroy level rather
  # than through the full destroy_everything! -- that method also wipes
  # every fixture family in the test DB, some of which carry PlaidItems
  # whose own before_destroy calls the real Plaid API (a separate, unrelated
  # concern VCR blocks outside a cassette).
  test "a family with an uncancellable demo subscription can't be destroyed until its Subscription row is cleared first" do
    family = Family.create!(name: "Demo Family")
    family.start_subscription!("sub_demo_123")

    assert_not family.destroy, "sanity check: the real bug -- Stripe cancellation fails and silently aborts the destroy"
    assert Family.exists?(family.id)

    Subscription.delete_all

    assert family.reload.destroy, "Demo::DataCleaner's fix: clearing Subscription rows first bypasses the Stripe call entirely"
    assert_not Family.exists?(family.id)
  end
end
