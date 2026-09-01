class AddPocketToGoals < ActiveRecord::Migration[8.1]
  def change
    add_reference :goals, :pocket, type: :uuid, foreign_key: true, null: true
  end
end
