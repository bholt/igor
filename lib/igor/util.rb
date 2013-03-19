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
  def dictionize
    h = {}
    names .zip captures do |name, cap|
      if cap then
        h[name.to_sym] = cap.match(REG_NUM) ? cap.to_f : cap
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

module Igor
  def self.igor_dir
    return "#{Dir.pwd}/.igor"
  end
  
  # iterator that takes a dict of variables and enumerates all possible combinations
  # yields: dict of experiment parameters
  def enumerate_exps(d, keys=d.keys, upb=new_binding())
    if keys.empty? then
      h = {}
      yield h
    else
      k,*rest = *keys
      vals = d[k]
      # puts "#{k.inspect} -- #{d.inspect}"
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
        elsif v.is_a?(ExpressionString) || !v.is_a?(String) then
          # evaluate as an expression (and give an error if it doesn't evaluate correctly)
          begin
            eval("#{k} = #{v}", upb)
          rescue TypeError, NameError
            puts "#{v}: #{k} is not available!"
            exit()
          end
        else
          eval("#{k} = '#{v}'", upb) # eval as a string literal instead of an expression
        end
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


