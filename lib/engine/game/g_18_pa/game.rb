# frozen_string_literal: true

require_relative 'entities'
require_relative 'map'
require_relative 'meta'
require_relative '../base'
require_relative '../cities_plus_towns_route_distance_str'

module Engine
  module Game
    module G18PA
      class Game < Game::Base
        include_meta(G18PA::Meta)
        include Entities
        include Map
        include CitiesPlusTownsRouteDistanceStr

        attr_reader :nyc_formed, :destination_tokens
        attr_accessor :nyc_formation_purchase

        TRACK_RESTRICTION = :semi_restrictive
        SELL_BUY_ORDER = :sell_buy
        TILE_RESERVATION_BLOCKS_OTHERS = :always
        CURRENCY_FORMAT_STR = '$%s'
        CAPITALIZATION = :full
        HOME_TOKEN_TIMING = :manual
        MUST_BUY_TRAIN = :always
        EBUY_DEPOT_TRAIN_MUST_BE_CHEAPEST = false
        EBUY_FROM_OTHERS = :value
        EBUY_CAN_TAKE_PLAYER_LOAN = true
        PLAYER_LOAN_INTEREST_RATE = 50
        SELL_AFTER = :operate
        MUST_SELL_IN_BLOCKS = true
        SOLD_SHARES_DESTINATION = :corporation
        MARKET_SHARE_LIMIT = 100
        MIN_BID_INCREMENT = 5
        MUST_BID_INCREMENT_MULTIPLE = true
        GAME_END_CHECK = { bank: :full_or }.freeze
        BANK_CASH = 8_000

        CERT_LIMIT = {
          3 => { 7 => 17, 6 => 16, 5 => 15, 4 => 14, 3 => 13, 2 => 12, 1 => 11, 0 => 11 },
          4 => { 7 => 14, 6 => 13, 5 => 12, 4 => 11, 3 => 10, 2 => 9, 1 => 8, 0 => 8 },
          5 => { 7 => 12, 6 => 11, 5 => 10, 4 => 9, 3 => 8, 2 => 7, 1 => 6, 0 => 6 },
        }.freeze
        STARTING_CASH = { 3 => 500, 4 => 400, 5 => 350 }.freeze
        MARKET = [
          %w[90 100 110 125 140 160 180 200 225 250 275 300],
          %w[80 90 100 110p 125 140 160 180 200 225 250 275],
          %w[70 80 90p 100p 110 125 140 160 180 200],
          %w[60 70p 80p 90 100 110 125],
          %w[50 60 70 80 90],
        ].freeze

        PHASES = [
          { name: '2', train_limit: 2, tiles: [:yellow], operating_rounds: 2 },
          { name: '3', on: '3', train_limit: 2, tiles: %i[yellow green], operating_rounds: 2 },
          { name: '4', on: '4', train_limit: 2, tiles: %i[yellow green], operating_rounds: 2 },
          { name: '5', on: '5', train_limit: 2, tiles: %i[yellow green brown], operating_rounds: 2 },
          { name: '3D', on: '3D', train_limit: 2, tiles: %i[yellow green brown gray], operating_rounds: 2 },
        ].freeze
        TRAINS = [
          { name: '2', distance: 2, price: 100, num: 14, rusts_on: '4' },
          { name: '3', distance: 3, price: 200, num: 5, rusts_on: '3D' },
          { name: '4', distance: 4, price: 400, num: 3, events: [{ 'type' => 'nyc_forms' }] },
          { name: '5', distance: 5, price: 500, num: 'unlimited', events: [{ 'type' => 'regional_trains' }] },
          { name: '3D', distance: 3, price: 600, num: 'unlimited', available_on: '5' },
          { name: '2R', distance: 2, price: 0, num: 6, reserved: true },
        ].map do |train|
          cities = train[:distance]
          diesel = train[:name] == '3D'
          train.merge(distance: [
            { 'nodes' => %w[city offboard], 'pay' => cities, 'visit' => cities, 'multiplier' => diesel ? 2 : 1 },
            { 'nodes' => ['town'], 'pay' => 99, 'visit' => 99, 'multiplier' => diesel ? 0 : 1 },
          ])
        end.freeze

        EVENTS_TEXT = Base::EVENTS_TEXT.merge(
          'nyc_forms' => ['NYC forms',
                          'After this company finishes its turn, form the NYC; conversion and acquisition are allowed'],
          'regional_trains' => ['Regional trains and ferry closure',
                                'Acquired locals become 2R trains; the Fall River ferry closes'],
        ).freeze
        DESTINATIONS = { 'B&O' => 'K2', 'B&A' => 'D17', 'ERIE' => 'C2', 'PRR' => 'I2' }.freeze
        FERRY_HEXES = %w[H23 H25 G26].freeze
        SCRANTON_HEX = 'G12'
        SCRANTON_MARKER_COST = 40

        def new_auction_round
          Engine::Round::Auction.new(self, [G18PA::Step::PrivateAuction])
        end

        def stock_round
          G18PA::Round::Stock.new(self, [G18PA::Step::BuySellParShares])
        end

        def operating_round(round_num)
          Engine::Round::Operating.new(self, [
            G18PA::Step::Track,
            G18PA::Step::Convert,
            G18PA::Step::Acquire,
            G18PA::Step::BuyMiningToken,
            Engine::Step::Token,
            Engine::Step::Route,
            G18PA::Step::Dividend,
            G18PA::Step::BuyTrain,
          ], round_num: round_num)
        end

        def setup
          @nyc_formed = false
          @nyc_pending = false
          @nyc_formation_purchase = false
          @destination_tokens = {}
          @mining_token_owners = []
          @acquired_locals = Hash.new { |h, k| h[k] = [] }
          @nyc_exchange_shares = shares_for_corporation(nyc)[1, 3]
          @nyc_exchange_shares.each { |s| s.buyable = false }
          nyc.presidents_share.buyable = false
          nyc.ipoed = true
          @stock_market.set_par(nyc, @stock_market.par_prices.find { |p| p.price == 110 })

          built_in_trains = @depot.trains.select { |t| t.name == '2' }.take(9)
          @minors.each_with_index do |minor, index|
            train = built_in_trains[index]
            train.reserved = true
            train.buyable = false
            buy_train(minor, train, :free)
          end
          @nyc_train = @depot.trains.reverse.find { |t| t.name == '3' }
          @nyc_train.reserved = true
          @nyc_train.buyable = false
          buy_train(nyc, @nyc_train, :free)

          (@minors + @corporations.reject { |c| c == nyc }).each do |entity|
            city = hex_by_id(entity.coordinates).tile.cities[entity.city || 0]
            city.place_token(entity, entity.tokens.first, free: true)
          end
          DESTINATIONS.each do |id, hex_id|
            corporation = corporation_by_id(id)
            token = Token.new(corporation, type: :destination)
            token.status = :flipped
            corporation.tokens << token
            hex_by_id(hex_id).tile.cities.first.place_token(corporation, token, free: true)
            @destination_tokens[corporation] = token
          end
          @ferry_tile = hex_by_id('H23').tile
          @graph.clear
        end

        def nyc
          @nyc ||= corporation_by_id('NYC')
        end

        def minor_for(company)
          minor_by_id(company.id.delete_prefix('P'))
        end

        def after_buy_company(player, company, _price)
          minor = minor_for(company)
          minor.owner = player
          minor.float!
        end

        def buyable_bank_owned_companies
          @companies.select { |c| !c.closed? && !c.owner }
        end

        def unowned_purchasable_companies(_entity)
          buyable_bank_owned_companies
        end

        def operating_order
          @minors.select(&:floated?).sort_by { |m| m.id.to_i } + @corporations.select(&:floated?).sort
        end

        def reorder_players(order = nil, **kwargs)
          super(@round.auction? ? :most_cash : order, **kwargs)
        end

        def cert_limit(_player = nil)
          self.class::CERT_LIMIT[@players.size][@corporations.count { |c| c.type == :ten_share }]
        end

        def train_limit(entity)
          entity.minor? ? 1 : 2
        end

        def num_corp_trains(entity)
          entity.trains.count { |t| t.name != '2R' }
        end

        def can_par?(corporation, entity)
          corporation != nyc && super
        end

        def float_corporation(corporation)
          return super unless corporation == nyc

          @log << 'NYC is now active'
        end

        def event_nyc_forms!
          @nyc_pending = true
        end

        def after_end_of_operating_turn(operator)
          return unless @nyc_pending

          form_nyc(operator.owner)
          @round.entities.insert(@round.entity_index + 1, nyc) if nyc.floated?
        end

        def form_nyc(triggering_player)
          @nyc_pending = false
          @nyc_formed = true
          @log << '-- New York Central System forms --'
          owners = %w[P1 P2 P3].map { |id| company_by_id(id).owner }
          %w[P1 P2 P3].each_with_index do |id, index|
            company = company_by_id(id)
            share = @nyc_exchange_shares[index]
            share.buyable = true
            @share_pool.buy_shares(company.owner, share, exchange: company, allow_president_change: false) if company.owner
            minor = minor_for(company)
            minor.tokens.first.swap!(nyc.tokens[index], check_tokenable: false)
            minor.close!
            company.close!
          end
          nyc.presidents_share.buyable = true
          @bank.spend(770, nyc)
          order = @players.rotate(@players.index(triggering_player))
          candidates = @players.select { |p| p.percent_of(nyc) >= 20 }
          president = candidates.min_by { |p| [-p.percent_of(nyc), owners.index(p) || 3, order.index(p)] }
          activate_nyc(president) if president
          @nyc_formation_purchase = nyc.floated?
          @graph.clear
          check_destinations!
        end

        def activate_nyc(player)
          return if nyc.floatable
          return unless player.percent_of(nyc) >= 20

          @share_pool.change_president(nyc.presidents_share, nyc, player, nyc) unless nyc.presidents_share.owner == player
          nyc.owner = player
          nyc.floatable = true
          nyc.floated = true
          @nyc_train.buyable = true
          @log << "#{player.name} becomes president of NYC; NYC is active"
        end

        def convert(corporation)
          if !@phase.available?('4') || corporation.type != :five_share
            raise GameError, 'Conversion requires phase 4 and a 5-share public company'
          end

          shares = shares_for_corporation(corporation)
          corporation.share_holders.clear
          shares.each do |share|
            share.percent /= 2
            corporation.share_holders[share.owner] += share.percent
          end
          5.times do |i|
            share = Share.new(corporation, percent: 10, index: i + 4)
            corporation.share_holders[corporation] += share.percent
            corporation.shares_by_corporation[corporation] << share
            @_shares[share.id] = share
          end
          corporation.type = :ten_share
          corporation.tokens.concat(Array.new(2) { Token.new(corporation, price: 100) })
          update_holding_limit(corporation)
          funding = corporation.share_price.price * 5
          @bank.spend(funding, corporation)
          @log << "#{corporation.name} converts to 10 shares and receives #{format_currency(funding)}"
        end

        def available_conversion_shares(corporation)
          corporation.ipo_shares.select { |s| s.buyable && !s.president }
        end

        def buy_conversion_shares(player, corporation, count)
          shares = available_conversion_shares(corporation)
          if player.debt.positive? || !count.between?(0, shares.size) || count * corporation.share_price.price > player.cash
            raise GameError, 'Cannot afford this share purchase'
          end

          shares.take(count).each { |share| @share_pool.buy_shares(player, share) }
        end

        def connected_to_local?(corporation, minor)
          return true if corporation.tokens.any? { |t| t.used && t.status != :flipped && t.hex == minor.tokens.first.hex }

          major_paths = @graph.connected_paths(corporation)
          @graph.connected_paths(minor).keys.any? { |path| major_paths[path] }
        end

        def acquirable_companies(corporation)
          return [] if !corporation.corporation? || !@phase.available?('4') || corporation.cash < 220
          return [] unless corporation.next_token

          @companies.select do |company|
            !company.closed? && company.id.delete_prefix('P').to_i >= 4 &&
              !company.owner&.corporation? && connected_to_local?(corporation, minor_for(company))
          end
        end

        def acquire(corporation, company)
          raise GameError, 'Cannot acquire this local company' unless acquirable_companies(corporation).include?(company)

          owner = company.owner
          corporation.spend(110, owner || @bank)
          corporation.spend(110, @bank)
          owner&.companies&.delete(company)
          company.owner = corporation
          corporation.companies << company
          minor = minor_for(company)
          minor.tokens.first.swap!(corporation.next_token, check_tokenable: false)
          minor.close!
          @acquired_locals[corporation] << company
          update_holding_limit(corporation)
          remove_duplicate_tokens!
          create_regional_train(corporation) if @phase.available?('5')
          @graph.clear
          check_destinations!
          @log << "#{corporation.name} acquires #{company.name} for $220 ($110 to #{owner ? owner.name : 'the bank'})"
        end

        def update_holding_limit(corporation)
          corporation.max_ownership_percent = [60 + (@acquired_locals[corporation].size * corporation.share_percent), 100].min
        end

        def create_regional_train(corporation)
          train = @depot.trains.find { |t| t.name == '2R' && t.owner == @depot }
          buy_train(corporation, train, :free)
          @log << "#{corporation.name} receives a permanent 2R train (does not count toward the train limit)"
        end

        def event_regional_trains!
          @acquired_locals.each { |corp, companies| companies.size.times { create_regional_train(corp) } }
          hex = hex_by_id('H23')
          if hex.tile != @ferry_tile
            @tiles << hex.tile unless hex.tile.unlimited
            hex.lay(@ferry_tile)
          end
          @graph.clear_graph_for_all
          @log << '-- The Fall River ferry closes --'
        end

        def ferry_open?
          !@phase.available?('5') && hex_by_id('H23').tile.name == '9'
        end

        def graph_skip_paths(_entity)
          return {} if ferry_open?

          FERRY_HEXES.flat_map { |id| hex_by_id(id).tile.paths }.to_h { |path| [path, true] }
        end

        def city_tokened_by?(city, entity)
          return false unless city.city?

          city.tokens.any? { |token| token&.corporation == entity && token.status != :flipped }
        end

        def check_destinations!
          @destination_tokens.each do |corporation, token|
            next unless token.status == :flipped

            home = corporation.tokens.first.city
            next unless @graph.connected_nodes_by_token(corporation, home)[token.city]

            token.status = nil
            @log << "#{corporation.name} connects its home to #{token.hex.location_name} and activates its doubling token"
            @graph.clear
          end
        end

        def remove_duplicate_tokens!
          @hexes.each do |hex|
            hex.tile.cities.each do |city|
              city.tokens.compact.group_by(&:corporation).each_value do |tokens|
                tokens.sort_by! { |token| token == token.corporation.tokens.first || token.type == :destination ? 0 : 1 }
                tokens.drop(1).each(&:remove!)
              end
            end
          end
        end

        def action_processed(action)
          track_and_tokens_changed! if action.type == 'place_token'
        end

        def track_and_tokens_changed!
          remove_duplicate_tokens!
          @graph.clear
          check_destinations!
        end

        def scranton_marker?(entity)
          @mining_token_owners.include?(entity)
        end

        def can_buy_scranton_marker?(entity)
          entity.corporation? && @mining_token_owners.size < 2 && !scranton_marker?(entity) &&
            entity.cash >= SCRANTON_MARKER_COST && @graph.reachable_hexes(entity)[hex_by_id(SCRANTON_HEX)]
        end

        def buy_scranton_marker(entity)
          raise GameError, 'Cannot buy a mining rights token' unless can_buy_scranton_marker?(entity)

          entity.spend(SCRANTON_MARKER_COST, @bank)
          @mining_token_owners << entity
          icons = hex_by_id(SCRANTON_HEX).tile.icons
          icons.delete_at(icons.index { |icon| icon.name == 'mine' })
          entity.add_ability(Ability::Description.new(type: 'description', description: 'Scranton +$40 (once per OR; no 3D)'))
          @log << "#{entity.name} buys mining rights for $40"
        end

        def station_bonus
          { '2' => 0, '3' => 10, '4' => 10, '5' => 20, '3D' => 30 }[@phase.name]
        end

        def revenue_for(route, stops)
          revenue = super
          corporation = route.corporation
          token = @destination_tokens[corporation]
          if token && token.status != :flipped && stops.include?(token.city)
            revenue += token.city.route_revenue(route.phase, route.train)
          end
          revenue += stops.count { |stop| stop.city? && city_tokened_by?(stop, corporation) } * station_bonus
          revenue += @phase.name == '2' ? 20 : 10 if ferry_route?(route)
          revenue
        end

        def extra_revenue(entity, routes)
          return 0 unless scranton_marker?(entity)

          routes.any? { |r| r.train.name != '3D' && r.visited_stops.any? { |s| s.hex.id == SCRANTON_HEX } } ? 40 : 0
        end

        def submit_revenue_str(routes, show_subsidy)
          bonus = routes.empty? ? 0 : extra_revenue(routes.first.corporation, routes)
          return super unless bonus.positive?

          revenue = routes_revenue(routes)
          "#{format_currency(revenue + bonus)} (#{format_currency(revenue)} routes + #{format_currency(bonus)} Scranton)"
        end

        def ferry_route?(route)
          route.hexes.any? { |hex| hex.id == 'H25' }
        end

        def check_other(route)
          super
          cities = route.visited_stops.reject(&:town?).map(&:hex)
          raise GameError, 'A route may not visit two cities on the same hex' if cities.uniq.size != cities.size
          return unless ferry_route?(route)

          raise GameError, 'The Fall River ferry is closed' unless ferry_open?

          stop_hexes = route.visited_stops.map { |stop| stop.hex.id }
          return if stop_hexes.include?('H21') && stop_hexes.include?('F27')

          raise GameError, 'A ferry route must include Islip and Providence'
        end

        def end_game!(game_end_reason)
          add_interest_player_loans! unless @finished
          super
        end
      end
    end
  end
end
