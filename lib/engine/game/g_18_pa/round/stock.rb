# frozen_string_literal: true

require_relative '../../../round/stock'

module Engine
  module Game
    module G18PA
      module Round
        class Stock < Engine::Round::Stock
          def finish_round
            super
            @game.add_interest_player_loans!
          end
        end
      end
    end
  end
end
