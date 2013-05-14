---
layout: page
title: Igor
tagline: Not just for mad scientists
---
{% include JB/setup %}

Igor is the ideal lab assistant for any grad student running a countable but nearly infinite number of experiments. It will carry out your orders with terrifying exactitude and collect the results.

Igor is an "Interactive Gatherer Of Results" (I.G.O.R.), that is, it is designed to help run batches of experiments, especially parameter sweeps, and gather the results for later analysis and visualization, but also provides a full Ruby REPL prompt with helpers for interacting with running experiments, visualizing results, and more.

What began as a script to enumerate and run all possible combinations of multidimensional variable sweeps has become a system that interfaces with the Slurm job manager, is configured with a simple DSL, and has an interactive Pry shell for watching the progress of experiments, reviewing results, and spawning new experiments.

## Installation
Make sure you have Ruby 1.9.3 at least, with RubyGems installed.

Then build and install the gem:

```bash
gem build igor.gemspec
gem install igor-{version}.gem
```

## Examples
The file `examples/sample.rb` contains a toy run script that demonstrates a number of features of Igor scripts. The `examples` directory also contains more realistic scripts used in [Grappa](http://sampa.cs.washington.edu/grappa). In particular, they contain more useful output parsers.

## How-to
### Writing config/run scripts
Igor scripts are defined using an Igor DSL block:

```ruby
require 'igor'
Igor do # begin DSL block
  database 'sample_igor.db', :test
  command "srun echo %{a} %{b}"
  parser {|cmdout|
    /(?<ao>\d+)\s+(?<bo>\d+)\s+(?<co>\w+)/.match(cmdout).dictionize
  }
  params {
    nnode 2; ppn 2
    a 1, 2
    b 'hello', 'goodbye'
  }
  run { tag 'base experiment' }
  interact
end
```

#### Specifying experiments
Igor's experiment-running is based around running all possible combinations of various parameter sweeps. That is, often when running experiments, one wants to vary, say, the number of cluster nodes, as well as the size of the problem. In order to get all of the possible combinations, you take the cartesian product of the two sets of parameter variations.

Because specifying all of these parameters and their combinations is so common, Igor has special syntax to make it as easy as possible to represent them. Similar to how "Igor do...end" blocks have a DSL, parameter commands (`params`, `run`, and `run_forced`), accept a special DSL syntax:

### Interactive commands
Igor leverages the [Pry](http://pryrepl.org/) REPL to do its interactive prompt. When `interact` is called from a script, it will leave you at a prompt like this:

```ruby
[1] pry(Igor)> 
```

This indicates that we're "inside" Igor right now, so anything that could be called from within an Igor block in the script can be called here (for example, we can issue new experiments with `run`).
