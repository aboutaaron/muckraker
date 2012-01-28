require 'rubygems'
require 'campaign_cash'
require 'yaml'
require 'fileutils'
require 'titlecase'
require 'erb'

class String
    def normalize
        downcase.titlecase.gsub(/[,]/i, '')
    end
end

class DataSet
    attr_accessor :title, :legend, :data, :columns, :chart_type

    def initialize title, legend, data, columns
        @title = title
        @legend = legend
        @data = data
        @columns = columns
    end

    def chart_type
        @chart_type || "PieChart"
    end
end

class Muckraker

	include CampaignCash

    DEFAULT_LIMIT = 10
    US_STATES = [:AL, :AK, :AZ, :AR, :CA, :CO, :CT, :DE, :FL, :GA, :HI, :ID, :IL, :IN, :IA, :KS, :KY, :LA, :ME, :MD,
                 :MA, :MI, :MN, :MS, :MO, :MT, :NE, :NV, :NH, :NJ, :NM, :NY, :NC, :ND, :OH, :OK, :OR, :PA, :RI, :SC,
                 :SD, :TN, :TX, :UT, :VT, :VA, :WA, :WV, :WI, :WY]

    CACHE_DIR = File.expand_path "~/.muckraker/cache"
    CANDIDATES_CACHE_FILENAME = 'candidates.yaml'
    EXPENDITURES_CACHE_FILENAME = 'expenditures.yaml'

    TEMPLATE_FILENAME = 'template.html.erb'

    attr_accessor :cache, :candidates, :expenditures, :payees

    def initialize(api_key)
   		Base.api_key = api_key
    end

    def cache=cache
        @cache = cache
        if cache
            FileUtils.mkdir_p CACHE_DIR
        end
    end

    def load
        if cache && has_cached_data?
            load_from_cache
        else
            load_candidates
            load_expenditures
        end
        generate_candidate_id_map
    end

    def chart data_sets
        @data_sets = data_sets
        template = File.open(File.join(File.dirname(__FILE__), TEMPLATE_FILENAME)).read
        return ERB.new(template).result(binding)
    end

    def top_payees party=nil, support_or_oppose=nil, limit=DEFAULT_LIMIT

        # party is one of 'REP' or 'DEM'
        # support_or_oppose is one of 'O' or 'S'

        filtered_expenditures = @expenditures
        unless support_or_oppose.nil?
            filtered_expenditures = filtered_expenditures.reject { |exp| exp.support_or_oppose != support_or_oppose }
        end
        unless party.nil?
            filtered_expenditures = restrict_to_party(filtered_expenditures, party)
        end

        payee_names, data = sort_expenditures(filtered_expenditures) do |exp|
            exp.payee.normalize # normalize against differences in names (e.g. , LLC vs. just LLC)
        end
        columns = { :names => ['Payee', 'Amount'], :types => ['string', 'number'] }
        title = "Top Payees"
        title += " #{support_or_oppose == 'O' ? 'Opposing' : 'Supporting'}" if support_or_oppose
        title += " #{party == 'REP' ? 'Republicans' : 'Democrats'}" if party
        DataSet.new(title, payee_names[0...limit], data[0...limit], columns)
    end

    def top_payees_for_candidate candidate_id, support_or_oppose=nil, limit=DEFAULT_LIMIT
        candidate = @candidate_id_map[candidate_id]
        filtered_expenditures = []
        @expenditures.each do |exp|
            if exp.candidate == candidate_id
                filtered_expenditures << exp
            end
        end
        if support_or_oppose
            filtered_expenditures.reject! { |exp| exp.support_or_oppose != support_or_oppose }
        end

        payee_names, data = sort_expenditures(filtered_expenditures) do |exp|
            exp.payee.normalize # normalize against differences in names (e.g. , LLC vs. just LLC)
        end
        columns = { :names => ['Payee', 'Amount'], :types => ['string', 'number'] }
        title = "Top Payees: "
        title += "#{support_or_oppose == 'O' ? 'Opposing' : 'Supporting'} " if support_or_oppose
        title += candidate.name + " (#{candidate.party}) "
        DataSet.new(title, payee_names[0...limit], data[0...limit], columns)
    end

    def top_supported_candidates party=nil, limit=DEFAULT_LIMIT
        top_candidates 'S', party, limit
    end

    def top_opposed_candidates party=nil, limit=DEFAULT_LIMIT
        top_candidates 'O', party, limit
    end

    private

    def top_candidates support_or_oppose=nil, party=nil, limit=DEFAULT_LIMIT
        filtered_expenditures = @expenditures
        unless party.nil?
            filtered_expenditures = restrict_to_party(filtered_expenditures, party)
        end
        filtered_expenditures.select! { |exp| exp.support_or_oppose == support_or_oppose }
        candidate_names, data = sort_expenditures(filtered_expenditures) do |exp|
            candidate = @candidate_id_map[exp.candidate]
            candidate.name + " (#{candidate.party})"
        end
        columns = { :names => ['Candidate Name', 'Amount Spent'], :types => ['string', 'number'] }
        title = "Most Supported #{party.nil? ? '' : party + " "}Candidates: "
        data_set = DataSet.new(title, candidate_names[0...limit], data[0...limit], columns)
        data_set.chart_type = "ColumnChart"
        data_set
    end

    def restrict_to_party expenditures, party
        expenditures.reject do |exp|
            candidate = @candidate_id_map[exp.candidate]
            candidate.party != party
        end
    end

    def load_from_cache
        @candidates = YAML::load File.open(File.join(CACHE_DIR, CANDIDATES_CACHE_FILENAME)).read
        @expenditures = YAML::load File.open(File.join(CACHE_DIR, EXPENDITURES_CACHE_FILENAME)).read
    end

    def generate_candidate_id_map
        @candidate_id_map = {}
        @candidates.each do |candidate|
            @candidate_id_map[candidate.id] = candidate
        end
    end

    def load_candidates
    	@candidates = US_STATES.map do |state|
  			Candidate.state_chamber(state, 'senate') + Candidate.state_chamber(state, 'house')
		end.flatten
        if cache
            File.open(File.join(CACHE_DIR, CANDIDATES_CACHE_FILENAME), 'w') do |f|
                f.write YAML::dump(@candidates)
            end
        end
    end

    def has_cached_data?
        [CANDIDATES_CACHE_FILENAME, EXPENDITURES_CACHE_FILENAME].each do |filename|
            return false unless File.exists?(File.join(CACHE_DIR, filename))
        end
        true
    end

    def load_expenditures
        @expenditures = []
        @candidates.each do |candidate|
            load_expenditures_for_candidate(candidate.id)
        end
        if cache
            File.open(File.join(CACHE_DIR, EXPENDITURES_CACHE_FILENAME), 'w') do |f|
                f.write YAML::dump(@expenditures)
            end
        end
    end

    def load_expenditures_for_candidate(candidate_id, year=2012)
		candidate_expenditures = IndependentExpenditure.candidate(candidate_id, year)
    	@expenditures << candidate_expenditures
        @expenditures.flatten!
    end

    def sort_expenditures expenditures
        payees = {}
        expenditures.each do |exp|
            payee_name = yield(exp)
            payees[payee_name] ||= 0
            payees[payee_name] += exp.amount
        end
        payee_names = payees.keys.sort do |a, b|
          payees[b] <=> payees[a]
        end
        data = []
        payee_names.each do |payee_name|
            data << payees[payee_name]
        end
        [payee_names, data]
    end

end

# Usage:
#
# API_KEY = '160748e2412352af46f3fe7c75cce5fd:15:63511996'
# m = Muckraker.new(API_KEY)
# m.cache = true
# m.load
# Chart top payees for everyone
# puts m.chart([m.top_payees, m.top_payees("REP"), m.top_payees("DEM"), m.top_payees("REP", "S"), m.top_payees("DEM", "O"), m.top_payees("DEM", "S"), m.top_payees("REP", "O")])
# Chart top payees per candidate
# payees = m.candidates.map { |candidate| m.top_payees_for_candidate(candidate.id) }
# payees.reject! { |data_set| data_set.data.empty? }
# puts m.chart(payees)
# puts m.chart([m.top_supported_candidates, m.top_supported_candidates('REP'), m.top_supported_candidates('DEM')])
