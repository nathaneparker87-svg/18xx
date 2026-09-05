# frozen_string_literal: true

require_relative '../../../step/buy_sell_par_shares'

module Engine
  module Game
    module G18PA
      module Step
        class BuySellParShares < Engine::Step::BuySellParShares
          def actions(entity)
            actions = super.dup
            if entity == current_entity && entity.debt.positive? && entity.cash.positive?
              actions |= %w[payoff_player_debt payoff_player_debt_partial]
              actions |= ['pass'] unless must_sell?(entity)
            end
            actions
          end

          def can_buy?(entity, bundle)
            entity.debt.zero? && super
          end

          def can_buy_shares?(entity, shares)
            entity.debt.zero? && super
          end

          def can_buy_company?(player, company)
            !bought? && player.debt.zero? && @game.num_certs(player) < @game.cert_limit(player) && super
          end

          def process_buy_company(action)
            unless can_buy_company?(action.entity, action.company) && action.price == 110
              raise GameError, 'An available private company costs $110 and counts as the stock purchase'
            end

            super
            @round.last_to_act = action.entity
          end

          def allow_president_change?(corporation)
            corporation != @game.nyc || corporation.floatable
          end

          def process_buy_shares(action)
            super
            if action.bundle.corporation == @game.nyc && @game.nyc_formed
              @game.activate_nyc(action.entity)
            end
          end

          def process_payoff_player_debt(action)
            @game.payoff_player_loan(action.entity)
            @round.current_actions << action
            @round.last_to_act = action.entity
          end

          def process_payoff_player_debt_partial(action)
            unless action.amount.positive? && action.amount <= [action.entity.cash, action.entity.debt].min
              raise GameError, 'Repayment must be positive and cannot exceed cash or outstanding debt'
            end

            @game.payoff_player_loan(action.entity, payoff_amount: action.amount)
            @round.current_actions << action
            @round.last_to_act = action.entity
          end
        end
      end
    end
  end
end
