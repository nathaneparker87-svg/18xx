# frozen_string_literal: true

require_relative '../../../step/track'

module Engine
  module Game
    module G18PA
      module Step
        class Track < Engine::Step::Track
          def potential_tile_colors(entity, hex)
            return super unless entity.minor?

            @game.phase.tiles & %i[yellow green]
          end

          def available_hex(entity, hex)
            return nil if hex.id == 'H23' && (entity.id != '5' || @game.phase.available?('5'))
            return nil if entity.minor? && hex.tile.upgrades.any? { |u| u.cost.positive? }

            super
          end

          def pay_tile_cost!(entity, tile, rotation, hex, spender, cost, extra_cost)
            raise GameError, 'Private companies may only build track without a cost' if entity.minor? && cost.positive?

            super
          end

          def process_lay_tile(action)
            if action.entity.minor? && !potential_tile_colors(action.entity, action.hex).include?(action.tile.color)
              raise GameError, 'Private companies may only lay yellow or upgrade to green'
            end
            if action.hex.id == 'H23' && (action.entity.id != '5' || action.tile.name != '9' || @game.phase.available?('5'))
              raise GameError, 'Only private company 5 may open the ferry by laying tile 9 in H23 before phase 5'
            end

            super
            @game.track_and_tokens_changed!
          end
        end
      end
    end
  end
end
