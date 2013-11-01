require_relative '../experiments'
require 'set'

# monkeypatching to add generally helpful stuff
class Hash
  def pretty_s
    '{ '.red + map{|n,p| "#{n}:".green + p.to_s.yellow}.join(', ') + ' }'.red
  end

  # recursively flatten nested Hashes
  def flat_each(prefix="", &blk)
    each do |k,v|
      if v.is_a?(Hash)
        v.flat_each("#{prefix}#{k}_", &blk)
      else
        yield "#{prefix}#{k}".to_sym, v
      end
    end
  end
end

require 'file-tail'
class File
  include File::Tail
end

class Array
  def all_numbers?
    reduce(true) {|total,v| total &&= v.respond_to? :/ }
  end
end

class MatchData
  def dictionize(opts={allow_int:false})
    h = {}
    names .zip captures do |name, cap|
      if cap then
        if opts[:allow_int]
          h[name.to_sym] = Integer(cap) rescue Float(cap) rescue cap
        else
          h[name.to_sym] = cap.match(REG_NUM) ? cap.to_f : cap
        end
      end
    end
    return h
  end
end

# /monkeypatching

module Signal
  def self.scoped_trap(signal, handler, &blk)
    prev = Signal.trap(signal, &handler)
    yield
    Signal.trap(signal, prev)
  end
end


module Helpers
  
  module Git
    def find_up_path(filename)
      fs = []
      p = Dir.pwd
      while p.length > 0 do
        if Dir.entries(p).include?(filename) then 
          fs << p+'/'+filename
        end
       i = p.rindex('/')
        if i == 0 then
          p = ""
        else
          p = p[0..i-1]
        end
      end
      return fs
    end
    
    def rugged(&blk)
      begin
        require 'rugged'
        $repo = Rugged::Repository.new(Rugged::Repository.discover) if not $repo
        return yield
      rescue Rugged::RepositoryError, LoadError
        return nil
      end
    end
    
    
    # return sha of the most recent commit (string)
    def current_commit
      rugged { $repo.head.target }
    end

    def current_tag
      rugged { $repo.tags.count > 0 ? `git describe --abbrev=0 --tags` : nil }
    end

    # return dict with info that should be included in every experiment record
    def common_info()
      {
        commit: current_commit,
           tag: current_tag,
        run_at: Time.now.to_s
      }
    end
  end
  
  module Sqlite
    def insert(dbtable, record)
      @db ||= Sequel.sqlite(@dbpath)
     
      # ensure there are fields to hold this record
      tbl = prepare_table(dbtable, record, @db)
      
      tbl.insert(record)
    end
    
    def update(dbtable, id, changes)
      raise "@db not initialized, what could you possibly be updating?" if not @db
      @db[dbtable].where(:id => id).update(changes)
    end
    
    def run_already?(params)
      p = params.select{|k,v| k != :run_at }
  
      # make sure all fields in params are existing columns, then query database
      return @db.table_exists?(@dbtable) \
          && (params.keys - @db[@dbtable].columns).empty? \
          && @db[@dbtable].filter(p).count > 0
    end
  end
  
  module DSL
    
    def dsl_dataset(starting_dataset, &blk)
      d = starting_dataset
      if blk
        # same as DSL eval: if they want a handle, give it to 'em
        if blk.arity == 1
          d = yield d
        else # otherwise just evaluate directly on the dataset (implicit 'self')
          d = d.instance_eval(&blk)
        end
      end
      return d
    end

    def eval_dsl_code(&dsl_code)
      # do an arity check so users of the DSL can leave off the object parameter:
      #   ExampleDSL.new { example_call }
      # or if they want to be more explicit:
      #   ExampleDSL.new {|e| e.example_call }
      if dsl_code.arity == 1      # the arity() check
        dsl_code[self]            # argument expected, pass the object
      else
        instance_eval(&dsl_code)  # no argument, use instance_eval()
      end
    end

  end
end

class Sequel::Dataset
  def query()
    d = Helpers::DSL::dsl_dataset(self, &blk)
    return Class.new(Sequel::Model) { set_dataset d }
  end
end

module Igor
  
  
  def self.igor_dir
    return "#{Dir.pwd}/.igor"
  end
  
  def new_binding; binding; end
  
  # iterator that enumerates the cartesian product
  # of all experiment parameters
  # yields: Hash: parameter=>value bindings for a single experiment
  def enumerate_exps(d, keys=d.keys, upb=new_binding, delayed=Set.new)
    if keys.empty? then
      h = {}
      yield h
    else
      k,*rest = *keys
      vals = d[k]
      # puts "#{k.inspect} -- #{d.inspect}"

      # parameter syntax allows single value or list.
      # convert to list
      if not vals.respond_to? :each then
        vals = [vals]
      end

      vals.each {|v|
        if v.is_a? Proc
          begin
            eval("#{k} = #{v[]}", upb)
          rescue TypeError, NameError
            puts "#{v}: #{k} is not available!"
            exit()
          end
        elsif v.is_a?(ExpressionString) || (!v.is_a?(String) && v != nil) then
          # evaluate as an expression (and give an error if it doesn't evaluate correctly)
          begin
            # add parameter setting to scope (to support expr() construct)
            eval("#{k} = #{v}", upb)
          rescue TypeError, NameError
            puts "#{v}: #{k} is not available!"
            exit()
          end
        elsif v != nil
          eval("#{k} = '#{v}'", upb) # eval as a string literal instead of an expression
        end

        # generate each element in the cross product
        # of the rest of the parameters
        enumerate_exps(d, rest, upb) { |result|
          if v.is_a? ExpressionString then
            v = eval("#{v}", upb) if v.is_a? String
          end
          yield ({k => v}.merge(result))
        }
      }
    end
  end
  
end

class ExpressionString < String
end

def expr(expr)
  return ExpressionString.new(expr)
end


