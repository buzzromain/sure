class CreatePocketMovements < ActiveRecord::Migration[8.1]
  def change
    # An explicit "add/withdraw" gesture, distinct from tag-fill: a deliberate
    # move of money into or out of a pocket, not tied to any specific
    # transaction. Closer to how a neobank Vault/Pot/Space actually works —
    # you move money in, you don't retroactively tag something that already
    # happened. Amount is signed: positive adds, negative withdraws.
    create_table :pocket_movements, id: :uuid do |t|
      t.references :pocket, null: false, foreign_key: true, type: :uuid
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :note

      t.timestamps
    end

    add_check_constraint :pocket_movements, "amount <> 0", name: "chk_pocket_movements_amount_not_zero"
  end
end
