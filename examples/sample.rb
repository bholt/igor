#!/usr/bin/env ruby
require 'igor'

exe = 'graph.exe'

Igor do
  # example of using Sqlite database
  database 'sample_igor.sqlite', :test
  
  # example of using MySQL database
  # database(adapter:'mysql', host:'n03.sampa', user:'grappa', table: :test)
  
  command "srun #{File.dirname(__FILE__)}/slow_loop.sh %{a} %{b} %{e}"
  
  sbatch_flags << "--time=30:00"
  sbatch_flags << (`hostname`=~/pal/ ? '--account=pal --partition=pal' : '--partition=grappa')

  # beware: the literal source given will be eval'd to create the parser for each job, no state will be transfered
  parser {|cmdout|
    m = /(?<ao>\d+)\s+(?<bo>\d+)\s+(?<co>\w+)/.match(cmdout)
    m.dictionize if m
  }

  params {
    nnode 2; ppn 1
    a 1, 2
    b '1', '2', '3'
    c 'abc'
    e expr('a*2') # pass lambdas to do expression params
  }
  
  expect :ao, :bo, :co

  # run { d 4; tag 'sample_tag' } # tag a set of runs as being part of a logical set 

  interact
end
