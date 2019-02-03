Gem::Specification.new do |s|
  s.name        = 'lexicon'
  s.version     = '0.0.0'
  s.date        = '2019-01-18'
  s.summary     = "Dictionary and Thesaurus"
  s.description = ""
  s.authors     = ["Tristan Gamilis"]
  s.email       = 'tristan@gamilis.com'
  s.files       = ["lib/lexicon.rb"]
  s.homepage    = ''
  s.license       = 'MIT'
  s.add_runtime_dependency 'rwordnet'
  s.add_runtime_dependency 'ruby-progressbar'
  s.add_runtime_dependency 'lemmatizer'
  s.add_runtime_dependency 'linguistics'
end