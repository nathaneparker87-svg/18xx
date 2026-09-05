# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18PA
      module Step
        class Acquire < Engine::Step::Base
          def setup
            @offer = nil
            @seller = nil
            @buy_share = false
            @declined = []
          end

          def corporation
            entities[entity_index]
          end

          def active_entities
            @seller ? [@seller] : super
          end

          def actions(entity)
            return [] if entity != current_entity || corporation.minor?
            return ['choose'] if @seller
            return %w[choose pass] unless candidates.empty?

            []
          end

          def candidates
            @game.acquirable_companies(corporation) - @declined
          end

          def description
            'Acquire local companies'
          end

          def choice_name
            return 'Buy one share in the acquiring company (holding limits do not apply)' if @buy_share
            return "Sell #{@offer.name} to #{corporation.name} for $110?" if @seller

            'Choose a local company to acquire for $220'
          end

          def choices
            if @buy_share
              choices = { 'pass' => 'Do not buy a share' }
              if @seller.debt.zero? && @seller.cash >= corporation.share_price.price &&
                  !@game.available_conversion_shares(corporation).empty?
                choices['buy'] = "Buy one share for $#{corporation.share_price.price}"
              end
              choices
            elsif @seller
              { 'accept' => 'Accept the acquisition', 'decline' => 'Decline the acquisition' }
            else
              candidates.to_h { |company| [company.id, "#{company.name} ($220)"] }
            end
          end

          def process_choose(action)
            raise GameError, 'Choose an offered acquisition action' unless choices.key?(action.choice)

            if @buy_share
              @game.buy_conversion_shares(@seller, corporation, 1) if action.choice == 'buy'
              clear_offer
            elsif @seller
              if action.choice == 'accept'
                complete_acquisition
              else
                @declined << @offer
                @log << "#{@seller.name} declines to sell #{@offer.name}"
                clear_offer
              end
            else
              @offer = candidates.find { |c| c.id == action.choice }
              @seller = @offer.owner
              if !@seller || @seller == corporation.owner
                complete_acquisition
              else
                @log << "#{corporation.name} offers to acquire #{@offer.name} from #{@seller.name}"
              end
            end
          end

          private

          def complete_acquisition
            @game.acquire(corporation, @offer)
            if @seller
              @buy_share = true
            else
              clear_offer
            end
          end

          def clear_offer
            @offer = nil
            @seller = nil
            @buy_share = false
          end
        end
      end
    end
  end
end
