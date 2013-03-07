# Igor
------------
## Not just for mad scientists.
Igor is the ideal lab assistant for any grad student running a countable but nearly infinite number of experiments. It will carry out your orders with terrifying exactitude and collect results.

Igor is an "Interactive Gatherer Of Results" (I.G.O.R.), that is, it is designed to help run experiments, especially parameter sweeps, and gather the results for later analysis and visualization.

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
For now, just look at [examples/sample.rb](examples/igor.rb).

### Querying database
Show the top 5 BFS results of scale 25:

```ruby
results{ where(:scale=>25).select(:id,:mpibfs,:nnode,:ppn,:max_teps).reverse_order(:max_teps).limit(5) }.all
```

Breaking it down: `results` takes a block which can be run as if by the `Sequel::Dataset` object, allowing the clean DSL-like syntax (`select` has `@db[@dbtable]` as its implicit `self`). Then we select some fields, sort the results by the "max_teps" field, and filter just ones where `:scale` is 25. More documentation on the chaining query methods can be found [here](http://sequel.rubyforge.org/rdoc/files/doc/querying_rdoc.html).

Because of the way Sequel's `Model`s work, once they're created, they have a fixed format. This block syntax lets us get around it by setting up the query before the Model object is created. Then all that is called on the model is `all` which displays the results as a nicely formatted table.
