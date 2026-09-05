# frozen_string_literal: true

require_relative '../../../step/dividend'
require_relative '../../../step/minor_half_pay'

module Engine
  module Game
    module G18PA
      module Step
        class Dividend < Engine::Step::Dividend
          include Engine::Step::MinorHalfPay

          def payout(entity, revenue)
            return super unless entity.minor?

            amount = revenue / 2
            { corporation: 0, per_share: amount }
          end

          def share_price_change(entity, revenue = 0)
            return {} if entity.minor?

            super
          end

          def payout_shares(entity, revenue)
            return super unless entity.minor?

            amount = revenue / 2
            @log << "#{entity.owner.name} receives #{@game.format_currency(amount)} (half of #{entity.name}'s earnings)"
            @game.bank.spend(amount, entity.owner) if amount.positive?
          end

          def corporation_dividends(_entity, _per_share)
            0
          end

          def dividends_for_entity(entity, holder, per_share)
            holder.player? ? super : 0
          end
        end
      end
    end
  end
end
