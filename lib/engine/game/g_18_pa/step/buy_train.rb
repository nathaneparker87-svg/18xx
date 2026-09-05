# frozen_string_literal: true

require_relative '../../../step/buy_train'

module Engine
  module Game
    module G18PA
      module Step
        class BuyTrain < Engine::Step::BuyTrain
          def actions(entity)
            return [] if current_entity&.minor?

            super
          end

          def other_trains(entity)
            return [] if @last_share_sold_price

            super.select { |train| train.owner.corporation? && train.owner.floated? && train.name != '2R' }
          end

          def buyable_trains(entity)
            return [] unless room?(entity)

            super.reject do |train|
              (train.reserved && train.owner == @game.depot) ||
                (train.from_depot? && @last_share_sold_price &&
                 train.price <= entity.cash + entity.owner.cash - @last_share_sold_price)
            end
          end

          def spend_minmax(entity, train)
            return [train.price, train.price] if train.from_depot?
            return [1, entity.cash] if entity.cash.positive? || !must_buy_train?(entity) || @last_share_sold_price

            [1, [entity.owner.cash, train.price].min]
          end

          def process_buy_train(action)
            if action.train.from_depot? && action.price != action.train.price
              raise GameError, 'Depot trains must be bought at face value'
            end

            raise GameError, 'A company with two ordinary trains cannot buy another train' unless room?(action.entity)
            unless buyable_trains(action.entity).include?(action.train)
              raise GameError, 'This train is not available for purchase'
            end

            contributing = !action.train.from_depot? && action.price > action.entity.cash
            if contributing && (action.entity.cash.positive? || !must_buy_train?(action.entity) ||
                                action.price > action.entity.owner.cash)
              raise GameError, 'President may fund an intercompany purchase only from cash, when the treasury is empty'
            end

            super
          end

          def can_sell?(entity, bundle)
            must_buy_train?(current_entity) && @game.depot.max_depot_price > available_cash(entity) && super
          end

          def process_pass(action)
            raise GameError, 'An active public company must own a train' if must_buy_train?(action.entity)

            super
          end
        end
      end
    end
  end
end
