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

The available DSL configuration commands are:

| Command                 | Alias | Description |
|-------------------------|-------|-------------|
| `database(path, table)` | `db`  | overrides any other database configs to use the specified one
| `command(string)`       | `cmd` | `string` can contain substitutions like "%{name}" where "name" is a key in the params hash
| `interact`            |       | enter Pry prompt, should probably be the last item (if you want an interactive session)
| `parser(&blk)`          |       | the block/lambda receives a string containing all the output from the job, and should parse out important results and return a hash, or list of hashes, representing records to be inserted in the database (these get merged with the params and job information in the database)
| `expect(*fields)`       |       | (takes a variable number of arguments) fields that, if not present in the output, mean the result was invalid (e.g. `:nnode`). Jobs considered invalid are not inserted in the "results" table, but still appear in the "jobs" table (see below for how to query these tables)
| `sbatch_flags`          |       | (getter/setter) list of string arguments to pass to sbatch (e.g. `sbatch_flags << '--time=15:00'`)
| `params(&blk)`          |       | add to the global parameters (if the same name is used, it overrides previous values), `params` should be treated in an imperative style, so any calls to `run` after it use the values it set (uses an ad-hoc DSL that lets you specify arbitrary parameters easily, see more detailed description below)
| `run(&blk)`             |       | runs a set of experiments based on the global params combined with params specified in this DSL block. These parameters or overrides only apply within that run. Note: this skips any experiments that already appear in the results table with identical parameters.
| `run_forced(&blk)`      |       | Run the specified experiments even if they already appear in the results table.

#### Specifying experiments
Igor's experiment-running is based around running all possible combinations of various parameter sweeps. That is, often when running experiments, one wants to vary, say, the number of cluster nodes, as well as the size of the problem. In order to get all of the possible combinations, you take the cartesian product of the two sets of parameter variations.

Because specifying all of these parameters and their combinations is so common, Igor has special syntax to make it as easy as possible to represent them. Similar to how "Igor do...end" blocks have a DSL, parameter commands (`params`, `run`, and `run_forced`), accept a special DSL syntax:

```ruby
params {
  constant 16
  nnode    2, 4
  scale    26
}
#=> @params.merge!({:constant=>[16], :nnode=>[2, 4], :scale=>[26]})
run { tag 'foo' }
# resulting parameter hash => {:constant=>[16], :nnode=>[2, 4], :scale=>[26], :tag=>["foo"]}
# runs experiments:
#   { constant:16, nnode:2, scale:26, tag:"foo" }
#   { constant:16, nnode:4, scale:26, tag:"foo" }
# (@params == {:constant=>[16], :nnode=>[2, 4], :scale=>[26]} still)
```

### Interactive commands
Igor leverages the [Pry](http://pryrepl.org/) REPL to do its interactive prompt. When `interact` is called from a script, it will leave you at a prompt like this:

```ruby
[1] pry(Igor)> 
```

This indicates that we're "inside" Igor right now, so anything that could be called from within an Igor block in the script can be called here (for example, we can issue new experiments with `run`).

There are also some additional commands that don't make sense in the configure scripts:

* `status` (alias: `st`): Print the status of all jobs. For example:

    ```ruby
    [ 0] 2369991: JOB_RUNNING on node[0158,0160-0170,0172-0197,0199,0202-0204,0397-0404,0406,0476-0488], time: 01:49:16  
    [ 1] 2370012: JOB_RUNNING on node[0423,0425-0439], time: 00:49:51
    [ 2] 2370013: JOB_RUNNING on node[0440,0445-0459], time: 00:49:51
    [ 3] 2370015: JOB_RUNNING on node[0407-0422,0460-0475], time: 00:46:48
         { nnode:32, ppn:2, scale:28 }
    [ 4] 2370016: JOB_PENDING on , time: 21:49:16
         { nnode:32, ppn:8, scale:28 }
    [ 5] 2370031: JOB_PENDING on , time: 02:16:00
         { nnode:16, ppn:16, scale:28 }
    => nil
    ```
    
    In square brackets [] is a "job alias" that you can use in a few commands to specify a running job. Notice some jobs have a param hash beneath them. These are jobs that were submitted by this Igor session, and the hash displays just the "distinguishing" parameters (ones that vary).

* `attach` (alias: `a`, `at`): Attach to a running or pending job (read-only). Detach with `ctrl-c`.

* `view(path|job_alias)`: Cat the output file for a job. You can specify either the output path directly or with a job alias, which you can find by running `status`.

* `tail(path|job_alias)`: Just like `view` but tails the file, in case it's still growing. Mostly unnecessary if the `attach` command works.

* `gdb(node,pid)`: Convenience command to create the command to ssh to a node and attach to a running process. Pry interprets commands beginning with "." as shell commands, and allows Ruby-style string "interpolation", so to use this, you can call: 

    ```ruby
    pry(Igor)> .#{gdb('n01','1234')}
    ```

* `results(&blk)`, `jobs(&blk)`, `recent_jobs(&blk)`, `sql(string)`: Query the database in a number of ways. See below.

#### Querying results

The query commands use the Sequel DSL inside the block to query the table specified by `database()` in the Igor configuration. The block should return a `Sequel::Dataset`. Supports a couple different calling styles:

* `results{ select(:id,:nnode,:ppn,:max_teps) }`: works as if "inside" the dataset, calling methods on `self` (could also say `self.select()`...)
* `results{|d| d.where(:scale => 16)}`: with an explicit dataset argument
    
The call to `results` returns a Sequel::Model instance. The fields of a Model can't be modified after creation, so the block passed to results is used to create the dataset before the Model is created. Typically, the Model object is just used to display all the queried records by calling  `all` on it: `results{select :id,:max_teps}.all`.

The other query commands `jobs` and `recent_jobs` query from the `jobs` table. The `jobs` table is shared among all Igor scripts. Useful fields in the table:
* `:results`: string containing the results hash that was parsed
* `:error`: When jobs start running, they insert a placeholder record with the `:error` field set to "x". If the job crashes and doesn't get a chance to clean up properly, this record will still be there. If the job fails more cleanly, then this record will be modified to reflect the actual error message (and set `:results`).
* `:started_at`: time the job started running
* `:run_at`: time the Igor script was started, less useful for interactively submitted jobs
* `:outfile`: path to the job output log, can be passed to the `view` command.  

You can also query using SQL directly rather than using the Sequel Ruby DSL. The command, `sql(s)`, takes a string, and returns a Sequel::Model just like the other query functions (i.e. you'll want to call something like `all` on it to see the results). For example:

```ruby
pry(Igor)> sql("select * from jobs").all
# or multiline:
pry(Igor)> sql(%q{
  select id, nnode, ppn, results
  from jobs
  where outfile like "%CombBLAS%"
}).all
```

It may be worth noting that the query isn't actually executed in any of these until you call something on the Model object, such as `.all`, or `.first`, or `.count`.

##### Example queries
Show the top 5 BFS results of scale 25:

```ruby
pry(Igor)> results{ where(:scale=>25)
        .select(:id,:mpibfs,:nnode,:ppn,:max_teps)
        .reverse_order(:max_teps).limit(5) }.all
```

Breaking it down: `results` takes a block which can be run as if by the `Sequel::Dataset` object, allowing the clean DSL-like syntax (`select` has `@db[@dbtable]` as its implicit `self`). Then we select some fields, sort the results by the "max_teps" field, and filter just ones where `:scale` is 25. More documentation on the chaining query methods can be found [here](http://sequel.rubyforge.org/rdoc/files/doc/querying_rdoc.html).

Because of the way Sequel's `Model`s work, once they're created, they have a fixed format. This block syntax lets us get around it by setting up the query before the Model object is created. Then we just call `all` on the model, which displays all queried results as a nicely formatted table.

#### Additional reading
General useful documentation on the Ruby Sequel DSL [sequel/sql.rdoc](http://sequel.rubyforge.org/rdoc/files/doc/sql_rdoc.html).

