require 'rwordnet'
require 'ruby-progressbar'
require 'lemmatizer'
require 'linguistics'
require 'pry'


Linguistics.use(:en, monkeypatch: false)

class Lexicon
  @@path = File.join(File.dirname(__FILE__), 'lexicon')
  SPACE = ' '
  attr_reader :word_pos_frequencies

  def initialize
    @lemm = Lemmatizer.new

    @conf = Hash.new
    @conf[:word_list_source_path] = File.join(@@path, 'UKACD.txt')
    @conf[:word_list_path]        = File.join(@@path, 'words.marshal')
    @conf[:uk_to_us_source_path]  = File.join(@@path, 'uk-us-spelling')
    @conf[:uk_to_us_path]         = File.join(@@path, 'uk_to_us.marshal')
    @conf[:word_pos_frequencies_source_path]  = File.join(@@path, 'word_pos_frequencies.yml')
    @conf[:word_pos_frequencies_path]         = File.join(@@path, 'word_pos_frequencies.marshal')
    @conf[:dictionary_path]                   = File.join(@@path, 'dictionary.marshal')
    @conf[:reverse_dictionary_path]           = File.join(@@path, 'reverse_dictionary.marshal')

    if File.exists?(@conf[:word_list_path]) &&
       File.exists?(@conf[:uk_to_us_path]) &&
       File.exists?(@conf[:dictionary_path]) &&
       File.exists?(@conf[:reverse_dictionary_path]) &&
       File.exists?(@conf[:word_pos_frequencies_path])

      puts "Loading from marshal"
      @word_list = load_file(@conf[:word_list_path])
      @uk_to_us = load_file(@conf[:uk_to_us_path])
      @dictionary = load_file(@conf[:dictionary_path])
      @reverse_dictionary = load_file(@conf[:reverse_dictionary_path])
      @word_pos_frequencies = load_file(@conf[:word_pos_frequencies_path])
      @size = @word_list.length
    else
      puts "Rebuilding everything..."
      install
    end
  end

  def to_s
    "<Lexicon word_count=\"#{@size}\">"
  end
  alias_method :inspect, :to_s

  def load_file(path)
    File.open(path, 'r') do |fh|
      Marshal.load(fh)
    end
  end

  def install
    # Word list to populate dictionary
    create_word_list
    @size = @word_list.length
    create_uk_to_us_lookup
    # POS frequencies
    create_word_pos_frequencies
    @dictionary = generate_dictionary(@word_list)
    link_all_lemmas
    link_all_synonyms
    File.open(@conf[:dictionary_path], 'w') do |file|
      Marshal.dump(@dictionary, file)
    end

    @reverse_dictionary = generate_dictionary(@word_list, reverse: true)
    File.open(@conf[:reverse_dictionary_path], 'w') do |file|
      Marshal.dump(@reverse_dictionary, file)
    end
  end

  def create_word_list
    # Only letters, apostrophes, spaces and hyphens allowed.
    # Can't start with punctuation.
    # Must start with a lette
    word_regex = /^[a-z][a-z\-\'\ ]{1,15}$/i

    words = []
    discarded = []
    puts "Adding words from UKACD"
    File.open(@conf[:word_list_source_path], 'r') do |fh|
      fh.each_line do |line|
        line.chomp!
        if line =~ word_regex
          words << line
        else
          discarded << discarded
        end
      end
    end
    puts "Discarded #{discarded.length} words."
    puts "Kept #{words.length} words from UKACD."
    p

    puts "Adding words from WordNet"
    # Prime the wordnet cache
    WordNet::Lemma.find_all("")
    discarded = []
    # Wordnet's cache has one hash for each POS with words as keys and the
    # WordNet space separated database line as values
    WordNet::Lemma.class_variable_get("@@cache").each do |pos, rows|
      rows.each do |word, data|
        word = word.gsub('_', ' ')
        if word =~ word_regex
          words << word
        else
          discarded << discarded
        end
      end
    end

    puts "Discarded #{discarded.length} from wordnet"
    puts "Increased to #{words.length}"
    words.uniq!
    puts "Recuded to #{words.length}"

    File.open(@conf[:word_list_path], 'w') do |file|
      Marshal.dump(words, file)
    end

    @word_list = words
  end

  def find(string)
    # Call on root of dictionary
    @dictionary.to(string)
  end

  def find_masked(masked_word)
    @dictionary.to(
      masked_word,
      character_comparator: proc do |target, node|
        # Matches character at position or target char is wildcard
        node.character == target[node.depth] || target[node.depth] == '?'
      end
    )
  end

  def find_starting_with(word_start, reverse: false)
    (reverse ? @reverse_dictionary : @dictionary).to(
      word_start,
      deep_search: true,
      character_comparator: proc do |target, node|
        node.character == target[node.depth] || node.depth > target.length - 1
      end,
      destination_comparator: proc do |target, node|
        (node.full_path.join == target || node.depth > target.length - 1) &&
          node.is_word
      end
    )
  end

  def find_ending_with(word_end)
    # Look it up forewards in the reversed dict
    find_starting_with(word_end.reverse, reverse: true).map(&:reverse)
  end

  def contains?(word)
    self[word]&.is_word
  end

  def lookup(string)
    position = @dictionary
    string.chars.each do |c|
      return nil unless position[c]
      position = position[c]
    end
    position
  end
  alias_method :[], :lookup

  # Building methods
  def generate_dictionary(words, reverse: false)
    print "Generating #{'reverse' if reverse} dictionary tree... "
    # Reverse words for reverse lookups (ends-with search)
    words = words.map(&:reverse) if reverse
    # Make the dictionary
    dictionary = DictNode.new
    words.each do |word|
      # Start at the root
      node = dictionary
      # Place each character
      word.chars.each do |char|
        node[char] ||= DictNode.new(char, node)
        node = node[char]
      end
      # Mark the final char as a word ending
      node.is_word = true
    end
    puts "done."
    dictionary
  end

  def link_all_lemmas
    bar = ProgressBar.create(title: 'Linking lemmas', total: @size, throttle_rate: 0.1)
    link_lemmas(@dictionary) do
      bar.increment
    end
  end

  def link_lemmas(node, &block)
    if node.is_word
      # Link this node to the node of its lemma (which may be itself)
      node.lemma = self[@lemm.lemma(node.to_s)] || node

      # Link each lemma to all of its inflected forms
      if node.lemma?
        # Stringify once
        word = node.to_s

        # Look up POS frequencies for all known POS for word
        poss = @word_pos_frequencies[word]&.keys || []

        poss.each do |pos|
          case pos
          when :vb, :vbp
            [:past, :present_participle, :third_person_present].each do |tense|
              if tense == :third_person_present
                conjugation = word.en.conjugate(:present, :third_person_singular)
              else
                conjugation = word.en.conjugate(tense)
              end
              if (inflection_node = lookup(conjugation))
                node.inflections[tense] = inflection_node
              end
            end
          when :nn, :nnp
            if (plural = lookup(word.en.plural))
              node.inflections[:plural] = plural
            end
          end
        end

      end

      # Callback at each word processed
      yield
    end

    node.each do |char, n|
      link_lemmas(n, &block)
    end
  end

  def link_all_synonyms
    bar = ProgressBar.create(title: 'Syns', total: @size, throttle_rate: 0.1)
    link_synonyms(@dictionary) do
      bar.increment
    end
  end

  def link_synonyms(node, &block)
    if node.is_word
      node.synonyms = find_synonyms(node)
      yield
    end
    node.each do |char, n|
      link_synonyms(n, &block)
    end
  end

  def find_synonyms(node)
    word = node.to_s
    wordnet_pos_tags = WordNet::Lemma.find_all(word.tr(' ', '_')).map(&:pos)

    synonyms = wordnet_pos_tags.flat_map do |tag|
      wordnet_lookup_syns(word, tag.to_sym)
    end

    # Look up POS frequencies for all known POS for word
    frequency_tags = @word_pos_frequencies[word]&.keys || []

    # Remove all that wordnet already had
    frequency_tags -= wordnet_pos_tags.map { |t| normalise_pos_tag(t) }

    # Find/generate synonyms for each known POS for word inflected from its lemma
    synonyms += frequency_tags.flat_map do |pos|
      lemma = (node.lemma || node).to_s
      inflected_syns(lemma, pos)
    end

    # Remove the word itself
    synonyms.delete(word)

    synonyms.uniq!

    # Exclude all synonyms that are closely related to the word including:
    # - Alternative spellings
    # - Hyphenated and non-hyphenated variants
    # - Related words, eg. 'stagecoach' and 'coach'
    synonyms.reject do |syn|
      syn = syn.downcase.tr('-', '')
      word = word.downcase.tr('-', '')

      # Simple containment
      next true if word.include?(syn)
      next true if syn.include?(word)

      # Complex similarity. Dehyphenate and check each synonym word for stem
      # similarity to the main word.
      syn.tr('-', '').split(' ').any? do |syn_word|
        # Since we're checking for inclusion, skip over short words. Otherwise
        # we'll reject phrases like "in the end" for "finally" because "finally"
        # contains the word "in".
        next false if syn_word.length < 3

        # Americanize the spelling and take the stem of the word
        s = americanize(syn_word).en.stem
        w = americanize(word).en.stem

        # Check for inclusion. This covers prefixes which aren't removed by the
        # Porter Stemmer, like "color" and "discolor".
        w.include?(s) || s.include?(w)
      end
    end
  end

  def normalise_pos_tag(tag)
    case tag.to_sym
    # Noun
    when :n then :nn
    # Verb
    when :v then :vbp
    # Adjective
    when :a then :jj
    # Adverb
    when :r then :rb
    end
  end

  def inflected_syns(lemma, pos)
    generated_syns = case pos
    when :vb, :vbp, :jj, :nn, :nnp
      # Not inflected
      []
    when :fw, :in, :ls, :sym, :det, :in, :uh, :ppc, :pp, :ppd, :ppl, :ppr,
      :cd, :wrb, :wdt, :cc, :md, :wp, :wps, :pdt
      # Known not handled
      []
    when :nnps, :nns
      # Plural nouns
      wordnet_lookup_syns(lemma, :noun).map do |lemma_syn|
        lemma_syn.en.plural
      end
    when :vbd, :vbn
      # Verb: past tense (vbn = past/passive participle)
      wordnet_lookup_syns(lemma, :verb).map do |lemma_syn|
        lemma_syn.en.conjugate(:past)
      end
    when :vbg
      # Verb: present participle (gerund)
      wordnet_lookup_syns(lemma, :verb).map do |lemma_syn|
        lemma_syn.en.conjugate(:present_participle)
      end
    when :vbz
      # Verb: present, third person singular
      wordnet_lookup_syns(lemma, :verb).map do |lemma_syn|
        lemma_syn.en.conjugate(:present, :third_person_singular)
      end
    else
      # puts "Unhandled POS: #{pos}"
      []
    end

    # Exclude any non-words generated
    generated_syns.select do |syn|
      contains?(syn)
    end
  end

  def americanize(word)
    @uk_to_us[word] || word
  end


  # Search wordnet for the lemma with a given POS and return inflected versions
  # of each synonym according to the block given.
  def wordnet_lookup_syns(lemma, pos)
    # Convert back to wordnet format
    lemma = lemma.tr(' ', '_')
    if (wordnet_lemma = WordNet::Lemma.find(lemma, pos))
      # Fetch all synonyms (combining all senses of the word)
      wordnet_lemma.synsets.flat_map(&:words).map do |w|
        # Clean up the output
        # - Adjectives can have an adjective marker at their end which needs be
        #   stripped. Eg. beautiful(ip), beautiful(p), beautiful(a)
        # - Replace underscores with spaces
        w.gsub(/\([a-z]*\)$/, '').tr('_', ' ')
      end
    else
      []
    end
  end

private

  def create_word_pos_frequencies
    puts "Loading word POS frequencies"
    @word_pos_frequencies = Hash.new
    File.open(@conf[:word_pos_frequencies_source_path], 'r') do |file|
      while line = file.gets
        /\A"?([^{"]+)"?: \{ (.*) \}/ =~ line
        next unless $1 and $2
        key, data = $1, $2
        items = data.split(/,\s+/)
        pairs = Hash.new
        items.each do |i|
          /([^:]+):\s*(.+)/ =~ i
          pairs[$1.to_sym] = $2.to_f
        end
        @word_pos_frequencies[key] = pairs
      end
    end
    File.open(@conf[:word_pos_frequencies_path], 'w') do |file|
      Marshal.dump(@word_pos_frequencies, file)
    end
  end

  def create_uk_to_us_lookup
    @uk_to_us = Hash.new
    File.open(@conf[:uk_to_us_source_path], 'r') do |file|
      file.each_line do |line|
        uk, us = line.split(SPACE)
        @uk_to_us[uk] = us
      end
    end
    File.open(@conf[:uk_to_us_path], 'w') do |file|
      Marshal.dump(@uk_to_us, file)
    end
  end
end

class DictNode < Hash
  attr_accessor :is_word, :synonyms, :lemma
  attr_reader :character, :inflections

  def initialize(character = nil, parent = nil)
    @character = character
    @parent = parent
    @synonyms = []
    @inflections = {}
  end

  def to(target, character_comparator: nil, destination_comparator: nil, deep_search: false)
    ret = []

    # Continue if current character matches or at root node
    if character_match?(target, character_comparator) || !@character
      # Destination matches get stored for return
      if destination_match?(target, destination_comparator)
        ret << full_path.join
        # Stop unless searching past first destination
        return ret unless deep_search
      end

      # Continue to next letters in tree
      ret << map do |_, node|
        node.to(
          target,
          character_comparator: character_comparator,
          destination_comparator: destination_comparator,
          deep_search: deep_search
        )
      end.compact
    end

    ret.flatten
  end

  def destination_match?(target, comparator)
    return comparator.call(target, self) if comparator
    full_path.length == target.length && is_word
  end

  def character_match?(target, comparator)
    return comparator.call(target, self) if comparator
    target[depth] == @character
  end

  def full_path
    @parent ? @parent.full_path + [@character] : []
  end

  def depth
    # Depth should match string index, so the root node has a depth of -1,
    # first letter has depth 0, etc.
    @depth ||= full_path.length - 1
  end

  def to_s
    full_path.join
  end

  def inspect
    "<DictNode word='#{self.is_word ? self.to_s : '-'}' lemma=#{lemma? ? 'true' : 'false'}>"
  end

  # A node is a lemma if its lemma is itself
  def lemma?
    lemma == self
  end
end

#binding.pry