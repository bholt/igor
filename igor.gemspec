
Gem::Specification.new do |gem|

    #required info
    gem.name = 'igor'
    gem.version = '0.2'
    gem.summary = 'Interactive Gathering Of Results'
    
    gem.files = `git ls-files`.split($/)

    #dependencies
    # (these are the earliest *tested* versions)
    gem.add_dependency('awesome_print', '~> 1.2.0')
    gem.add_dependency('open4', '~> 1.3.0')
    gem.add_dependency('sequel', '~> 4.3.0')
    gem.add_dependency('sqlite3', '~> 1.3.0')
    gem.add_dependency('sourcify', '= 0.6.0.rc4')
    gem.add_dependency('colored', '~> 1.2')
    gem.add_dependency('pry', '~> 0.9.0')
    gem.add_dependency('ffi', '~> 1.9.3')
    gem.add_dependency('file-tail','~> 1.0.0')
    gem.add_dependency('hirb', '~> 0.7.0') # optional, but makes pretty tables...
    gem.add_dependency('rugged', '~> 0.19.0')
    
    gem.authors = ['Brandon Holt', 'Brandon Myers']
    gem.email   = ['bholt@cs.washington.edu', 'bdmyers@cs.washington.edu']

    gem.homepage = "http://github.com/bholt/igor"
    gem.description = "DSL for running experiments over inputs and storing results in a sqlite database."
    
end
