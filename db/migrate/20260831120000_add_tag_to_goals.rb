# POC: a goal can be linked to one tag. Tagging a transaction with it is the
# attribution action itself — no separate confirm dialog. See Tagging's
# fill/unfill callbacks.
class AddTagToGoals < ActiveRecord::Migration[8.1]
  def change
    add_reference :goals, :tag, type: :uuid, foreign_key: true, null: true
  end
end
