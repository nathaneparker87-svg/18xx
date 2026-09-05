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

    def set_phase(name)
      game.phase.next! until game.phase.name == name
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
        set_phase('4')
        game.convert(corporation)
        expect(alice.percent_of(corporation)).to eq(20)
        expect(game.shares_for_corporation(corporation).map(&:percent)).to eq([20] + [10] * 8)
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
      it 'acquires a bank-owned local on another city of the same tile and later receives a 2R' do
        corporation = start_corporation('B&A')
        set_phase('4')
        local = game.company_by_id('P6')
        expect(game.acquirable_companies(corporation)).to include(local)
        game.acquire(corporation, local)
        expect(corporation.cash).to eq(280)
        expect(local.owner).to eq(corporation)
        expect(corporation.max_ownership_percent).to eq(80)
        expect(corporation.tokens.count(&:used)).to eq(3)
        expect(corporation.trains).to be_empty
        set_phase('5')
        game.event_regional_trains!
        expect(corporation.trains.map(&:name)).to eq(['2R'])
        expect(game.num_corp_trains(corporation)).to eq(0)
        expect(game.must_buy_train?(corporation)).to be(false)
      end
    end

    describe 'destinations and train revenue' do
      it 'does not treat destination blockers or towns as stations' do
        corporation = game.corporation_by_id('PRR')
        destination = game.destination_tokens[corporation]
        expect(game.city_tokened_by?(destination.city, corporation)).to be(false)
        expect(game.city_tokened_by?(game.hex_by_id('G12').tile.towns.first, corporation)).to be(false)
        expect(game.city_tokened_by?(corporation.tokens.first.city, corporation)).to be(true)
      end

      it 'doubles an active destination again on a 3D without multiplying the station bonus' do
        set_phase('3D')
        corporation = game.corporation_by_id('PRR')
        token = game.destination_tokens[corporation]
        token.status = nil
        train = game.trains.find { |t| t.name == '3D' }
        train.owner = corporation
        route = Route.new(game, game.phase, train)
        expect(game.revenue_for(route, [token.city])).to eq(4 * 60 + 30)
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
