# A deliberate "add money" / "withdraw money" gesture on a pocket — the
# explicit-transfer counterpart to tag-fill. Recorded on its own so a
# pocket's balance is never a bare number with nothing behind it: the same
# reasoning Goal's own consumed_entries exists for, on the other mechanism.
class PocketMovement < ApplicationRecord
  belongs_to :pocket

  validates :amount, numericality: { other_than: 0 }

  scope :recent_first, -> { order(created_at: :desc) }

  def withdrawal?
    amount.negative?
  end
end
