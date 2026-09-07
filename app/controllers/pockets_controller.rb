class PocketsController < ApplicationController
  before_action :set_account
  before_action :require_depository_account
  before_action :require_manage_account, only: %i[new create edit update destroy move create_movement
                                                    convert_to_envelope create_envelope_conversion]
  before_action :set_pocket, only: %i[edit update destroy move create_movement
                                       convert_to_envelope create_envelope_conversion]

  def index
    redirect_to account_path(@account, tab: :pockets)
  end

  def new
    @pocket = @account.pockets.new(currency: @account.currency, color: Pocket::COLORS.first)
  end

  def create
    @pocket = @account.pockets.new(pocket_params)
    @pocket.currency = @account.currency
    target_amount = pocket_target_amount_param

    ActiveRecord::Base.transaction do
      @pocket.save!

      # No kind picker here on purpose -- kept to the simplest shape
      # (one_off, no target_date). A maintained/months-of-expenses goal, or
      # adding a target later, still goes through the full "Ajouter un
      # objectif" flow (PocketGoalsController), unchanged.
      if target_amount&.positive?
        @goal = @pocket.build_goal(name: @pocket.name, target_amount: target_amount,
                                    currency: @account.currency, family: Current.family, kind: "one_off")
        @goal.save!
      end
    end

    respond_to do |format|
      format.turbo_stream { render_pocket_streams(t("pockets.create.success")) }
      format.html { redirect_to account_path(@account, tab: :pockets), notice: t("pockets.create.success") }
    end
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  end

  def edit
  end

  def update
    if @pocket.update(pocket_params)
      respond_to do |format|
        format.turbo_stream { render_pocket_streams(t("pockets.update.success")) }
        format.html { redirect_to account_path(@account, tab: :pockets), notice: t("pockets.update.success") }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @pocket.destroy

    respond_to do |format|
      format.turbo_stream { render_pocket_streams(t("pockets.destroy.success")) }
      format.html { redirect_to account_path(@account, tab: :pockets), notice: t("pockets.destroy.success") }
    end
  end

  # Renders the dialog. The write lives in its own action below, same split
  # Goal's own (now-removed) consume dialog used.
  def move
    @direction = params[:direction] == "withdraw" ? "withdraw" : "add"
  end

  def create_movement
    amount = params.dig(:pocket_movement, :amount).to_d
    note = params.dig(:pocket_movement, :note).presence
    direction = params[:direction] == "withdraw" ? "withdraw" : "add"

    if direction == "withdraw"
      @pocket.withdraw_money!(amount, note: note)
      notice = t("pockets.move.withdraw_success", amount: Money.new(amount, @pocket.currency).format)
    else
      @pocket.add_money!(amount, note: note)
      notice = t("pockets.move.add_success", amount: Money.new(amount, @pocket.currency).format)
    end

    respond_to do |format|
      format.turbo_stream { render_pocket_streams(notice) }
      format.html { redirect_to account_path(@account, tab: :pockets), notice: notice }
    end
  rescue Pocket::MovementRefused => e
    redirect_to account_path(@account, tab: :pockets), alert: t("pockets.move.errors.#{e.reason}")
  end

  # Renders the dialog. The write lives in its own action below, same split
  # move/create_movement above uses.
  def convert_to_envelope
    @selectable_categories = selectable_categories
  end

  def create_envelope_conversion
    category = Current.family.categories.find(params[:category_id])
    pocket_name = @pocket.name
    @pocket.convert_to_envelope!(category: category)
    Budget::RolloverCalculator.new(family: Current.family, user: nil).recompute!

    notice = t("pockets.convert_to_envelope.success", name: pocket_name, category: category.display_name)
    respond_to do |format|
      format.turbo_stream { render_pocket_streams(notice) }
      format.html { redirect_to account_path(@account, tab: :pockets), notice: notice }
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to account_path(@account, tab: :pockets), alert: t("pockets.convert_to_envelope.errors.category_required")
  # RecordNotUnique alongside RecordInvalid: same funding_category_id race
  # BudgetCategoryGoalsController#create guards against -- two concurrent
  # conversions (or a conversion racing a new envelope goal) onto the same
  # category can both pass validation before either commits.
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    @selectable_categories = selectable_categories
    flash.now[:alert] = t("pockets.convert_to_envelope.errors.category_taken")
    render :convert_to_envelope, status: :unprocessable_entity
  rescue Pocket::ConversionRefused => e
    redirect_to account_path(@account, tab: :pockets), alert: t("pockets.convert_to_envelope.errors.#{e.reason}")
  end

  private

    def render_pocket_streams(notice)
      flash.now[:notice] = notice
      render turbo_stream: [
        turbo_stream.replace("modal", view_context.turbo_frame_tag("modal")),
        turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@account, :pockets_content),
          partial: "accounts/pockets/index",
          locals: { account: @account }
        ),
        *flash_notification_stream_items
      ]
    end

    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
    end

    def require_depository_account
      redirect_to account_path(@account), status: :see_other unless @account.depository?
    end

    def require_manage_account
      permission = @account.permission_for(Current.user)
      unless permission.in?([ :owner, :full_control ])
        redirect_to account_path(@account), alert: t("accounts.not_authorized")
      end
    end

    def set_pocket
      @pocket = @account.pockets.find(params[:id])
    end

    # Mirrors BudgetCategoryGoalsController#selectable_categories exactly --
    # no pre-filtering of categories already backing another envelope goal,
    # the RecordInvalid/RecordNotUnique rescue above handles that race.
    def selectable_categories
      Current.family.categories.includes(:subcategories).roots.alphabetically.flat_map do |root|
        [ root ] + root.subcategories.sort_by(&:name)
      end
    end

    # Not a Pocket attribute -- read separately and never merged into
    # pocket_params, so it can't be mass-assigned to Pocket by accident.
    def pocket_target_amount_param
      params.dig(:pocket, :target_amount).presence&.to_d
    end

    def pocket_params
      permitted = params.require(:pocket).permit(:name, :description, :allocated_amount, :fill_direction,
                                                   :color, :icon, :link_new_tag)
      permitted[:link_new_tag] = ActiveModel::Type::Boolean.new.cast(permitted[:link_new_tag])

      # When a tag drives auto-fill, the amount is computed from transactions
      # — ignore any manual input for it, same reasoning as Goal's own form.
      if permitted[:link_new_tag] || @pocket&.tag_id.present?
        permitted.except(:allocated_amount)
      else
        permitted
      end
    end
end
