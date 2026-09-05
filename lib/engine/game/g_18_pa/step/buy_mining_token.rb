# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18PA
      module Step
        class BuyMiningToken < Engine::Step::Base
          def actions(entity)
            entity == current_entity && @game.can_buy_scranton_marker?(entity) ? %w[choose pass] : []
          end

          def description
            'Buy Scranton mining rights'
          end

          def choice_name
            'Buy mining rights'
          end

          def choices
            { 'buy' => 'Buy a +$40 mining rights token for $40' }
          end

          def process_choose(action)
            raise GameError, 'Choose the mining rights token' unless action.choice == 'buy'

            @game.buy_scranton_marker(action.entity)
            pass!
          end
        end
      end
    end
  end
end
