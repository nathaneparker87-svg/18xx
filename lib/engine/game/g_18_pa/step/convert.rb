# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18PA
      module Step
        class Convert < Engine::Step::Base
          def setup
            @buying = false
          end

          def corporation
            entities[entity_index]
          end

          def buying?
            @buying || (corporation == @game.nyc && @game.nyc_formation_purchase)
          end

          def active_entities
            buying? ? [corporation.owner] : super
          end

          def actions(entity)
            return [] if entity != current_entity || corporation.minor?
            return ['choose'] if buying?
            return %w[convert pass] if corporation.type == :five_share && @game.phase.available?('4')

            []
          end

          def description
            buying? ? 'Buy shares after conversion' : 'Convert to a 10-share company'
          end

          def choice_name
            'Buy additional shares at market value (holding limits do not apply)'
          end

          def process_convert(action)
            @game.convert(action.entity)
            @buying = true
          end

          def choices
            player = corporation.owner
            max = if player.debt.positive?
                    0
                  else
                    [player.cash.div(corporation.share_price.price), @game.available_conversion_shares(corporation).size].min
                  end
            (0..max).to_h do |count|
              [count.to_s, count.zero? ? 'Buy no shares' : "Buy #{count} shares for $#{count * corporation.share_price.price}"]
            end
          end

          def process_choose(action)
            raise GameError, 'Choose an offered share purchase' unless choices.key?(action.choice)

            count = action.choice.to_i
            @game.buy_conversion_shares(action.entity, corporation, count) if count.positive?
            @buying = false
            @game.nyc_formation_purchase = false if corporation == @game.nyc
            pass!
          end
        end
      end
    end
  end
end
