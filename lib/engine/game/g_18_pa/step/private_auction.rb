# frozen_string_literal: true

require_relative '../../../step/base'

module Engine
  module Game
    module G18PA
      module Step
        class PrivateAuction < Engine::Step::Base
          def setup
            @companies = @game.companies.dup
            @bid = nil
            @winner = nil
            @passed_bidders = []
            @consecutive_passes = 0
          end

          def description
            @winner ? 'Choose a private company' : 'Bid for the right to buy a private company'
          end

          def help
            'Bids are a premium above $110. The winner chooses a company after the auction. A $0 bid is not a pass.'
          end

          def available
            @companies
          end

          def auctioning
            :turn
          end

          def visible?
            true
          end

          def players_visible?
            true
          end

          def bids
            {}
          end

          def may_bid?(_company)
            false
          end

          def may_purchase?(_company)
            false
          end

          def may_choose?(_company)
            false
          end

          def min_increment
            5
          end

          def min_player_bid
            @bid ? @bid.price + 5 : 0
          end

          def max_player_bid(player)
            player.cash - 110
          end

          def committed_cash(player, _show_hidden = false)
            @bid&.entity == player ? 110 + @bid.price : 0
          end

          def active_entities
            @winner ? [@winner] : super
          end

          def actions(entity)
            return [] if passed? || @companies.empty? || entity != current_entity
            return ['choose'] if @winner

            max_player_bid(entity) >= min_player_bid ? %w[bid pass] : ['pass']
          end

          def choices
            @companies.to_h { |company| [company.id, company.name] }
          end

          def choice_name
            'Choose a private company for $110 plus the winning bid'
          end

          def process_bid(action)
            if action.price < min_player_bid || action.price > max_player_bid(action.entity) || (action.price % 5).positive?
              raise GameError, 'Bid must be an affordable multiple of $5 above the current bid'
            end
            raise GameError, 'Choose a company only after winning the auction' if action.company

            @bid = action
            @consecutive_passes = 0
            @log << "#{action.entity.name} bids #{@game.format_currency(action.price)} above $110"
            advance_auction
          end

          def process_pass(action)
            @log << "#{action.entity.name} passes bidding"
            if @bid
              @passed_bidders << action.entity
              advance_auction
            else
              @consecutive_passes += 1
              if @consecutive_passes == entities.size
                pass!
              else
                @round.next_entity_index!
              end
            end
          end

          def process_choose(action)
            company = @companies.find { |c| c.id == action.choice }
            raise GameError, 'Choose an available private company' unless company

            price = 110 + @bid.price
            action.entity.spend(price, @game.bank)
            company.owner = action.entity
            action.entity.companies << company
            @game.after_buy_company(action.entity, company, price)
            @log << "#{action.entity.name} buys #{company.name} for #{@game.format_currency(price)}"
            @companies.delete(company)
            @round.goto_entity!(action.entity)
            @round.next_entity_index!
            @bid = nil
            @winner = nil
            @passed_bidders.clear
            @consecutive_passes = 0
            pass! if @companies.empty?
          end

          private

          def advance_auction
            eligible = entities - @passed_bidders
            if eligible == [@bid.entity]
              @winner = @bid.entity
              @log << "#{@winner.name} wins the right to choose a private company"
              return
            end

            loop do
              @round.next_entity_index!
              break unless @passed_bidders.include?(entities[entity_index])
            end
          end
        end
      end
    end
  end
end
