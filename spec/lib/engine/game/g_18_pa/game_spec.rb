# frozen_string_literal: true

require 'spec_helper'

module Engine
  describe Game::G18PA::Game do
    let(:game) { described_class.new(%w[A B C], id: 1) }
    let(:alice) { game.players[0] }
    let(:bob) { game.players[1] }
    let(:carol) { game.players[2] }

    def act(type, entity = game.current_entity, **args)
      game.process_action(type.new(entity, **args)).maybe_raise!
    end

    def skip_auction
      3.times { act(Action::Pass) }
    end

    def own_private(id, player)
      company = game.company_by_id(id)
      company.owner = player
      player.companies << company
      game.after_buy_company(player, company, 110)
      company
    end

    def start_corporation(id = 'PRR', player = alice, par = 100)
      corporation = game.corporation_by_id(id)
      game.stock_market.set_par(corporation, game.stock_market.par_prices.find { |p| p.price == par })
      game.share_pool.buy_shares(player, corporation.presidents_share)
      corporation
    end

    def advance_to_phase(name)
      game.phase.next! until game.phase.name == name
    end

    def begin_operations
      skip_auction
      act(Action::Pass) while game.round.stock?
      expect(game.round).to be_operating
    end

    describe 'setup and initial auction' do
      it 'reserves the private and NYC trains without duplicate train IDs' do
        expect(game.trains.map(&:id).uniq.size).to eq(game.trains.size)
        expect(game.minors.map { |m| m.trains.map(&:name) }).to eq(Array.new(9) { ['2'] })
        expect(game.nyc.trains.map(&:name)).to eq(['3'])
        expect(game.depot.upcoming.count { |t| t.name == '2' }).to eq(5)
        expect(game.depot.upcoming.count { |t| t.name == '3' }).to eq(4)
        expect(game.depot.available(alice).map(&:name)).to eq(['2'])
      end

      it 'auctions the right to choose, including a zero-dollar premium' do
        act(Action::Bid, alice, price: 0)
        act(Action::Pass, bob)
        act(Action::Pass, carol)
        expect(game.round.active_step.choices.size).to eq(9)
        act(Action::Choose, alice, choice: 'P5')
        expect(game.company_by_id('P5').owner).to eq(alice)
        expect(game.minor_by_id('5').owner).to eq(alice)
        expect(alice.cash).to eq(390)
        expect(game.current_entity).to eq(bob)
      end

      it 'allows an initial passer back in but removes a bidder who passes after bidding starts' do
        act(Action::Pass, alice)
        act(Action::Bid, bob, price: 5)
        act(Action::Pass, carol)
        act(Action::Bid, alice, price: 10)
        act(Action::Pass, bob)
        act(Action::Choose, alice, choice: 'P1')
        expect(alice.cash).to eq(380)
      end

      it 'ends on consecutive passes and sells unsold privates for $110 during the stock round' do
        skip_auction
        expect(game.round).to be_a(Game::G18PA::Round::Stock)
        act(Action::BuyCompany, alice, company: game.company_by_id('P9'), price: 110)
        expect(alice.cash).to eq(390)
        expect(game.current_entity).to eq(bob)
        expect(game.round.active_step.actions(alice)).to be_empty
      end

      it 'reorders by remaining cash after the auction, preserving ties' do
        first, second, third = game.players.dup
        act(Action::Bid, first, price: 0)
        act(Action::Pass, second)
        act(Action::Pass, third)
        act(Action::Choose, first, choice: 'P1')
        3.times { act(Action::Pass) }
        expect(game.players).to eq([second, third, first])
      end
    end

    describe 'public capitalization and conversion' do
      it 'floats on the president certificate and fully capitalizes five shares' do
        corporation = start_corporation
        expect(corporation).to be_floated
        expect(corporation.cash).to eq(500)
        expect(alice.percent_of(corporation)).to eq(40)
        expect(alice.cash).to eq(300)
      end

      it 'halves existing percentages and issues five more shares, capital and two tokens' do
        corporation = start_corporation
        advance_to_phase('4')
        game.convert(corporation)
        expect(alice.percent_of(corporation)).to eq(20)
        expect(game.shares_for_corporation(corporation).map(&:percent)).to eq([20] + ([10] * 8))
        expect(corporation.cash).to eq(1000)
        expect(corporation.tokens.count { |t| t.type == :normal }).to eq(4)
        expect(game.cert_limit).to eq(12)
        game.buy_conversion_shares(alice, corporation, 3)
        expect(alice.percent_of(corporation)).to eq(50)
      end

      it 'pays half of private revenue to its owner and none to its treasury' do
        own_private('P1', alice)
        minor = game.minor_by_id('1')
        step = Game::G18PA::Step::Dividend.new(game, game.round)
        expect(step.payout(minor, 70)).to eq(corporation: 0, per_share: 35)
        expect { step.payout_shares(minor, 70) }.to change(alice, :cash).by(35)
        expect(minor.cash).to eq(0)
      end
    end

    describe 'NYC formation' do
      it 'sells nonreserved shares before formation without a presidency or flotation' do
        skip_auction
        2.times do
          share = game.nyc.ipo_shares.find { |s| s.buyable && !s.president }
          act(Action::BuyShares, alice, shares: [share])
          act(Action::Pass, bob)
          act(Action::Pass, carol)
        end
        expect(alice.percent_of(game.nyc)).to eq(20)
        expect(game.nyc).not_to be_floated
        expect(game.nyc.owner).not_to eq(alice)
        expect(game.nyc.cash).to eq(0)
      end

      it 'exchanges the three privates and awards ties to the lowest-numbered private owner' do
        own_private('P1', bob)
        own_private('P2', alice)
        own_private('P3', carol)
        [alice, bob].each do |player|
          game.share_pool.buy_shares(player, game.nyc.ipo_shares.find(&:buyable), allow_president_change: false)
        end
        game.form_nyc(alice)
        expect(game.nyc.owner).to eq(bob)
        expect(game.nyc).to be_floated
        expect(game.nyc.cash).to eq(770)
        expect(game.nyc.tokens.take(3).map { |t| t.hex.id }).to eq(%w[D17 B5 C2])
        expect(%w[P1 P2 P3].map { |id| game.company_by_id(id) }).to all(be_closed)
        expect(game.nyc.presidents_share.owner).to eq(bob)
      end

      it 'holds the NYC inactive until someone acquires 20 percent' do
        game.form_nyc(alice)
        expect(game.nyc).not_to be_floated
        expect(game.nyc.cash).to eq(770)
        skip_auction
        act(Action::BuyShares, alice, shares: [game.nyc.presidents_share])
        expect(game.nyc).to be_floated
        expect(game.nyc.owner).to eq(alice)
        expect(game.nyc.cash).to eq(770)
      end
    end

    describe 'local companies' do
      it 'waits for the owner to consent, then offers that owner one share' do
        corporation = start_corporation('B&A')
        own_private('P6', bob)
        advance_to_phase('4')
        begin_operations
        act(Action::Pass) # Old Colony track
        act(Action::RunRoutes, routes: []) if game.round.active_step.is_a?(Step::Route)
        act(Action::Pass) # B&A track
        act(Action::Pass) # B&A conversion
        expect(game.round.active_step).to be_a(Game::G18PA::Step::Acquire)
        act(Action::Choose, corporation, choice: 'P6')
        expect(game.current_entity).to eq(bob)
        expect(game.company_by_id('P6').owner).to eq(bob)
        act(Action::Choose, bob, choice: 'accept')
        expect(game.company_by_id('P6').owner).to eq(corporation)
        expect(bob.cash).to eq(610)
        act(Action::Choose, bob, choice: 'buy')
        expect(bob.percent_of(corporation)).to eq(20)
        expect(bob.cash).to eq(510)
        expect(game.current_entity).to eq(corporation)
      end

      it 'acquires a bank-owned local on another city of the same tile and later receives a 2R' do
        corporation = start_corporation('B&A')
        advance_to_phase('4')
        local = game.company_by_id('P6')
        expect(game.acquirable_companies(corporation)).to include(local)
        game.acquire(corporation, local)
        expect(corporation.cash).to eq(280)
        expect(local.owner).to eq(corporation)
        expect(corporation.max_ownership_percent).to eq(80)
        expect(corporation.tokens.count(&:used)).to eq(3)
        expect(corporation.trains).to be_empty
        advance_to_phase('5')
        game.event_regional_trains!
        expect(corporation.trains.map(&:name)).to eq(['2R'])
        expect(game.num_corp_trains(corporation)).to eq(0)
        expect(game.must_buy_train?(corporation)).to be(false)
      end
    end

    describe 'destinations and train revenue' do
      it 'activates PRR at the instant its home connects to Pittsburgh' do
        corporation = start_corporation
        %w[I6 I4].each do |hex|
          tile = game.tiles.find { |t| t.name == '9' }
          tile.rotate!(1)
          game.update_tile_lists(tile, game.hex_by_id(hex).tile)
          game.hex_by_id(hex).lay(tile)
        end
        game.track_and_tokens_changed!
        token = game.destination_tokens[corporation]
        expect(token.status).to be_nil
        expect(game.city_tokened_by?(token.city, corporation)).to be(true)
        # Once activated, it remains active even if the home connection is blocked later.
        game.hex_by_id('I6').lay(Tile.from_code('blocked', :white, ''))
        game.track_and_tokens_changed!
        expect(token.status).to be_nil
      end

      it 'returns a duplicate acquired station on a brown city merger, retaining the home station' do
        corporation = start_corporation('B&A')
        advance_to_phase('4')
        game.acquire(corporation, game.company_by_id('P6'))
        acquired_token = corporation.tokens.find { |t| t.used && t.city == game.hex_by_id('D27').tile.cities[2] }
        city = game.hex_by_id('D27')
        brown = game.tiles.find { |t| t.name == 'X23' }
        city.lay(brown)
        game.track_and_tokens_changed!
        expect(corporation.tokens.first.used).to be(true)
        expect(acquired_token.used).to be(false)
        expect(acquired_token.price).to eq(40)
        expect(corporation.max_ownership_percent).to eq(80)
      end

      it 'does not treat destination blockers or towns as stations' do
        corporation = game.corporation_by_id('PRR')
        destination = game.destination_tokens[corporation]
        expect(game.city_tokened_by?(destination.city, corporation)).to be(false)
        expect(game.city_tokened_by?(game.hex_by_id('G12').tile.towns.first, corporation)).to be(false)
        expect(game.city_tokened_by?(corporation.tokens.first.city, corporation)).to be(true)
      end

      it 'doubles an active destination again on a 3D without multiplying the station bonus' do
        advance_to_phase('3D')
        corporation = game.corporation_by_id('PRR')
        token = game.destination_tokens[corporation]
        token.status = nil
        train = game.trains.find { |t| t.name == '3D' }
        train.owner = corporation
        route = Route.new(game, game.phase, train)
        expect(game.revenue_for(route, [token.city])).to eq((4 * 60) + 30)
      end
    end

    describe 'Fall River ferry' do
      it 'opens through private 5 construction, scores both shores, and closes on the first 5' do
        own_private('P5', alice)
        begin_operations
        minor = game.minor_by_id('5')
        providence = game.hex_by_id('F27').tile.cities.first
        expect(game.graph.connected_nodes(minor)).not_to have_key(providence)
        act(Action::LayTile, minor, hex: game.hex_by_id('H21'), tile: game.tiles.find { |t| t.name == '4' }, rotation: 1)
        act(Action::RunRoutes, minor, routes: [])
        act(Action::LayTile, minor, hex: game.hex_by_id('H23'), tile: game.tiles.find { |t| t.name == '9' }, rotation: 1)
        expect(game).to be_ferry_open
        expect(game.graph.connected_nodes(minor)).to have_key(providence)
        route = Route.new(game, game.phase, minor.trains.first,
                          connection_hexes: [%w[H19 H21], %w[H21 H23 H25], %w[H25 G26 F27]])
        route.routes = [route]
        expect(route.revenue).to eq(80)
        advance_to_phase('5')
        game.event_regional_trains!
        expect(game).not_to be_ferry_open
        expect(game.hex_by_id('H23').tile.color).to eq(:white)
        expect(game.graph.connected_nodes(minor)).not_to have_key(providence)
      end
    end

    describe 'train purchases in an operating round' do
      it 'shows the loan warning only when a mandatory purchase exceeds available funds' do
        corporation = start_corporation
        corporation.spend(corporation.cash - 90, game.bank)
        game.bank.spend(90, alice)
        advance_to_phase('5')
        game.depot.upcoming.select { |t| %w[2 3 4].include?(t.name) }.each { |t| game.depot.forget_train(t) }
        begin_operations
        act(Action::Pass) until game.round.active_step.is_a?(Game::G18PA::Step::BuyTrain)
        step = game.round.active_step
        expect(alice.cash).to eq(390)
        expect(step.must_take_player_loan?(corporation)).to be true
        game.bank.spend(20, alice)
        expect(step.must_take_player_loan?(corporation)).to be false
        alice.spend(20, game.bank)
        train = game.depot.depot_trains.find { |t| t.name == '5' }
        act(Action::BuyTrain, corporation, train: train, price: 500)
        expect(alice.debt).to eq(30)
        expect(step.must_take_player_loan?(corporation)).to be false
      end

      it 'allows a cash-only presidential contribution for a trade when the treasury is empty' do
        corporation = start_corporation
        other = start_corporation('B&A', bob)
        train = game.depot.depot_trains.first
        game.buy_train(other, train, :free)
        corporation.spend(corporation.cash, game.bank)
        begin_operations
        act(Action::Pass)
        act(Action::BuyTrain, corporation, train: train, price: 100)
        expect(corporation.cash).to eq(0)
        expect(corporation.trains).to include(train)
        expect(alice.cash).to eq(200)
        expect(alice.debt).to eq(0)
        expect(other.cash).to eq(600)
      end

      it 'does not let the president top up a nonempty treasury for a trade' do
        corporation = start_corporation
        other = start_corporation('B&A', bob)
        train = game.depot.depot_trains.first
        game.buy_train(other, train, :free)
        corporation.spend(corporation.cash - 1, game.bank)
        begin_operations
        act(Action::Pass)
        expect { act(Action::BuyTrain, corporation, train: train, price: 100) }.to raise_error(GameError, /treasury is empty/)
        expect(train.owner).to eq(other)
      end

      it 'requires a depot purchase after emergency share sales' do
        corporation = start_corporation
        other = start_corporation('B&A', bob)
        other.operating_history[[1, 1]] = OperatingInfo.new([], nil, 0, [])
        share = other.ipo_shares.find { |s| !s.president }
        game.share_pool.buy_shares(alice, share)
        game.buy_train(other, game.depot.depot_trains.first, :free)
        corporation.spend(corporation.cash, game.bank)
        alice.spend(alice.cash, game.bank)
        begin_operations
        act(Action::Pass)
        act(Action::SellShares, alice, shares: [share])
        step = game.round.active_step
        expect(step.other_trains(corporation)).to be_empty
        train = game.depot.depot_trains.first
        act(Action::BuyTrain, corporation, train: train, price: 100)
        expect(alice.cash).to eq(0)
        expect(alice.debt).to eq(0)
      end

      it 'permits borrowing for a 3D even when cash is sufficient for the available 5' do
        corporation = start_corporation
        corporation.spend(corporation.cash, game.bank)
        game.bank.spend(250, alice)
        advance_to_phase('5')
        game.depot.upcoming.select { |t| %w[2 3 4].include?(t.name) }.each { |t| game.depot.forget_train(t) }
        begin_operations
        act(Action::Pass) until game.round.active_step.is_a?(Game::G18PA::Step::BuyTrain)
        expect(alice.cash).to eq(550)
        train = game.depot.depot_trains.find { |t| t.name == '3D' }
        act(Action::BuyTrain, corporation, train: train, price: 600)
        expect(alice.cash).to eq(0)
        expect(alice.debt).to eq(75)
        expect(corporation.trains).to include(train)
      end

      it 'forms NYC immediately after the first 4 buyer and inserts its operation' do
        own_private('P1', alice)
        own_private('P2', alice)
        corporation = start_corporation
        advance_to_phase('3')
        game.depot.upcoming.select { |t| %w[2 3].include?(t.name) }.each { |t| game.depot.forget_train(t) }
        begin_operations
        2.times do
          act(Action::Pass) # private track
          act(Action::RunRoutes, routes: []) if game.round.active_step.is_a?(Step::Route)
        end
        act(Action::Pass) # PRR track
        train = game.depot.depot_trains.first
        expect(train.name).to eq('4')
        act(Action::BuyTrain, corporation, train: train, price: 400)
        expect(game.nyc).to be_floated
        expect(game.current_entity).to eq(game.nyc)
        expect(game.round.entities).to eq([game.minor_by_id('1'), game.minor_by_id('2'), corporation, game.nyc])
        act(Action::Pass) # NYC track
        expect(game.current_entity).to eq(alice)
        expect(game.round.active_step).to be_a(Game::G18PA::Step::Convert)
        act(Action::Choose, alice, choice: '0')
      end

      it 'borrows the shortfall with immediate interest to buy a mandatory depot train' do
        corporation = start_corporation
        corporation.spend(corporation.cash, game.bank)
        alice.spend(alice.cash - 50, game.bank)
        begin_operations
        act(Action::Pass)
        train = game.depot.depot_trains.first
        act(Action::BuyTrain, corporation, train: train, price: 100)
        expect(corporation.trains).to include(train)
        expect(alice.cash).to eq(0)
        expect(alice.debt).to eq(75)
      end

      it 'does not sell a third ordinary train even when that train would rust an existing train' do
        corporation = start_corporation
        2.times { game.buy_train(corporation, game.depot.depot_trains.first, :free) }
        begin_operations
        step = game.round.steps.find { |s| s.is_a?(Game::G18PA::Step::BuyTrain) }
        expect(step.buyable_trains(corporation)).to be_empty
        expect(step.actions(corporation)).to be_empty
      end

      it 'keeps 2R trains out of intercompany trade' do
        corporation = start_corporation
        other = start_corporation('B&A', bob)
        game.create_regional_train(other)
        begin_operations
        step = game.round.steps.find { |s| s.is_a?(Game::G18PA::Step::BuyTrain) }
        expect(step.other_trains(corporation)).not_to include(other.trains.first)
      end
    end

    describe '18PA_game_end_bank' do
      it 'finishes both operating rounds when the bank breaks during a stock round' do
        replay = fixture_at_action(160, clear_cache: true)
        expect(replay.round).to be_stock
        replay.bank.break!
        replay.process_to_action(213).maybe_raise!
        expect(replay.finished).to be(false)
        expect(replay.round.round_num).to eq(2)
        replay.process_to_action(250).maybe_raise!
        expect(replay.finished).to be(true)
        expect(replay.game_end_reason).to eq(:bank)
      end
    end

    describe 'player debt' do
      it 'charges interest on borrowing, at the end of the stock round, and at game end' do
        game.take_player_loan(alice, 100)
        expect(alice.debt).to eq(150)
        skip_auction
        game.round.finish_round
        expect(alice.debt).to eq(225)
        game.end_game!(:bank)
        expect(alice.debt).to eq(338)
      end

      it 'blocks stock purchases until debt is repaid' do
        skip_auction
        game.take_player_loan(alice, 100)
        step = game.round.active_step
        share = game.nyc.ipo_shares.find(&:buyable)
        expect(step.can_buy?(alice, share.to_bundle)).to be(false)
        act(Action::PayoffPlayerDebt, alice)
        expect(alice.debt).to eq(0)
        expect(step.can_buy?(alice, share.to_bundle)).to be(true)
      end
    end
  end
end
