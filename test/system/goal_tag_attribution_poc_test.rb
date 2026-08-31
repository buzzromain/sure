require "application_system_test_case"

class GoalTagAttributionPocTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(
      preferences: (@user.preferences || {}).merge("preview_features_enabled" => true),
      show_ai_sidebar: false
    )
    sign_in @user
  end

  test "poc: clean tag-driven attribution journey, auto-generated tag" do
    family = @user.family
    checking = family.accounts.create!(accountable: Depository.new, name: "Compte courant",
                                       currency: family.currency, balance: 3_200)
    savings = family.accounts.create!(accountable: Depository.new, name: "Livret Vacances",
                                      currency: family.currency, balance: 800)

    # 1 — création : pas de sélecteur de tag, juste une note disant qu'il sera
    # créé automatiquement.
    visit new_goal_path
    sleep 0.3
    fill_in I18n.t("goals.form.fields.name"), with: "Vacances d'été"
    find("input[name='goal[target_amount]']").fill_in(with: "1500")
    check "goal_account_ids_#{savings.id}"
    check "goal_account_ids_#{checking.id}"
    page.save_screenshot("/workspace/tmp/screenshots/tagpoc2_1_creation.png")

    click_on I18n.t("goals.form.create")
    sleep 0.6
    goal = Goal.find_by(name: "Vacances d'été")
    tag = goal.tag
    puts "tag auto-créé : #{tag&.name.inspect}"

    # 2 — la page de l'objectif, juste créé, rien dépensé encore. Le badge du
    # tag est déjà là.
    visit goal_path(goal)
    sleep 0.4
    page.save_screenshot("/workspace/tmp/screenshots/tagpoc2_2_objectif_vide.png")

    # 3 — modifier l'objectif : le tag est affiché, pas modifiable.
    visit edit_goal_path(goal)
    sleep 0.3
    page.save_screenshot("/workspace/tmp/screenshots/tagpoc2_3_edition_tag_lecture_seule.png")

    # 4 — une dépense arrive sur le compte courant, comme n'importe quelle
    # transaction normale.
    spend = checking.entries.create!(
      date: Date.current, name: "Billets d'avion Nice", amount: 420,
      currency: family.currency, entryable: Transaction.new
    )
    visit transactions_path
    sleep 0.4

    # 5 — on la tague : c'est ça, l'attribution. Pas de dialogue à part.
    click_on "Billets d'avion Nice"
    all("summary", text: /details/i, wait: 8).first.click
    sleep 0.3
    find("[data-tag-select-target='button']").click
    sleep 0.3
    page.save_screenshot("/workspace/tmp/screenshots/tagpoc2_4_tag_menu_ouvert.png")

    find("button[data-tag-id='#{tag.id}']").click
    sleep 0.5
    page.save_screenshot("/workspace/tmp/screenshots/tagpoc2_5_transaction_taguee.png")

    goal.reload
    puts "consumed_amount après tag : #{goal.consumed_amount}"

    # 6 — retour sur l'objectif : la dépense apparaît automatiquement.
    visit goal_path(goal)
    sleep 0.4
    page.save_screenshot("/workspace/tmp/screenshots/tagpoc2_6_objectif_avec_depense.png")

    # 7 — annuler : on enlève le tag, l'attribution disparaît toute seule.
    visit transactions_path
    sleep 0.3
    click_on "Billets d'avion Nice"
    all("summary", text: /details/i, wait: 8).first.click
    sleep 0.3
    find("[data-tag-select-target='button']").click
    sleep 0.3
    find("button[data-tag-id='#{tag.id}']").click
    sleep 0.5
    goal.reload
    puts "consumed_amount après retrait du tag : #{goal.consumed_amount}"

    # 8 — renommer l'objectif : le tag suit.
    visit edit_goal_path(goal)
    sleep 0.3
    fill_in I18n.t("goals.form.fields.name"), with: "Voyage Nice"
    click_on I18n.t("goals.form.save")
    sleep 0.5
    goal.reload
    puts "tag après renommage : #{goal.tag.name.inspect}"
  end
end
