require_relative 'type'

module RDL::Type

  # A type representing some method or block. MethodType has subcomponent
  # types for arguments (zero or more), block (optional) and return value
  # (exactly one).
  class MethodType < Type
    attr_reader :args
    attr_reader :block
    attr_reader :ret

    @@contract_cache = {}
    
    # Create a new MethodType
    #
    # [+args+] List of types of the arguments of the procedure (use [] for no args).
    # [+block+] The type of the block passed to this method, if it takes one.
    # [+ret+] The type that the procedure returns.
    def initialize(args, block, ret)
      # First check argument types have form (any number of required
      # or optional args, at most one vararg, any number of named arguments)
      state = :required
      args.each { |arg|
        arg = arg.type if arg.instance_of? RDL::Type::AnnotatedArgType
        case arg
        when OptionalType
          raise "Optional arguments not allowed after varargs" if state == :vararg
          raise "Optional arguments not allowed after named arguments" if state == :hash
          state = :optional
        when VarargType
          raise "Multiple varargs not allowed" if state == :vararg
          raise "Varargs not allowed after named arguments" if state == :hash
          state = :vararg
        when FiniteHashType
          raise "Only one set of named arguments allowed" if state == :hash
          state = :hash
        else
          raise "Required arguments not allowed after varargs" if state == :vararg
          raise "Required arguments not allowed after named arguments" if state == :hash
        end
      }
      @args = *args

      raise "Block must be MethodType" unless (not block) or (block.instance_of? MethodType)
      @block = block

      @ret = ret

      super()
    end

    def le(other, h={})
      raise RuntimeError, "should not be called"
    end

    # TODO: Check blk
    def pre_cond?(inst, *args, &blk)
      states = [[0, 0]] # [position in @arg, position in args]
      until states.empty?
        formal, actual = states.pop
        return true if formal == @args.size && actual == args.size # Matched all actuals, no formals left over
        next if formal >= @args.size # Too many actuals to match
        t = @args[formal]
        t = t.type if t.instance_of? AnnotatedArgType
        case t
        when OptionalType
          t = t.type.instantiate(inst)
          if actual == args.size
            states << [formal+1, actual] # skip to allow extra formal optionals at end
          elsif t.member?(args[actual], vars_wild: true)
            states << [formal+1, actual+1] # match
            states << [formal+1, actual] # skip
          else
            states << [formal+1, actual]  # type doesn't match; must skip this formal
          end
        when VarargType
          t = t.type.instantiate(inst)
          if actual == args.size
            states << [formal+1, actual] # skip to allow empty vararg at end
          elsif t.member?(args[actual], vars_wild: true)
            states << [formal, actual+1] # match, more varargs coming
            states << [formal+1, actual+1] # match, no more varargs
#            states << [formal+1, actual] # skip - can't happen, varargs have to be at end
          else
            states << [formal+1, actual] # skip
          end
        else
          t = t.instantiate(inst)
          the_actual = nil
          if actual == args.size
            next unless t.instance_of? FiniteHashType
            if t.member?({}, vars_wild: true) # try matching against the empty hash
              states << [formal+1, actual]
            end
          elsif t.member?(args[actual], vars_wild: true)
            states << [formal+1, actual+1] # match
            # no else case; if there is no match, this is a dead end
          end
        end
      end
      return false
    end

    def post_cond?(inst, ret, *args)
      method_name = method_name ? method_name + ": " : ""
      return @ret.instantiate(inst).member?(ret, vars_wild: true)
    end

    def to_contract(inst: nil)
      c = @@contract_cache[self]
      return c if c

      # @ret, @args are the formals
      # ret, args are the actuals
      prec = RDL::Contract::FlatContract.new(@args) { |*args, &blk|
        raise TypeError, "Arguments #{args} do not match argument types #{self}" unless pre_cond?(inst, *args, &blk)
        true
      }
      postc = RDL::Contract::FlatContract.new(@ret) { |ret, *args|
        raise TypeError, "Return #{ret} does not match return type #{self}" unless post_cond?(inst, ret, *args)
        true
      }
      c = RDL::Contract::ProcContract.new(pre_cond: prec, post_cond: postc)
      return (@@contract_cache[self] = c) # assignment evaluates to c
    end

    # [+types+] is an array of method types. Checks that [+args+] and
    # [+blk+] match at least one arm of the intersection type;
    # otherwise raises exception. Returns array of method types that
    # matched [+args+] and [+blk+]
    def self.check_arg_types(method_name, types, inst, *args, &blk)
      $__rdl_contract_switch.off {
        matches = [] # types that matched args
        types.each_with_index { |t, i| matches << i if t.pre_cond?(inst, *args, &blk) }
        return matches if matches.size > 0
        method_name = method_name ? method_name + ": " : ""
        raise TypeError, <<RUBY
#{method_name}Argument type error.
Method type:
#{types.map { |t| "        " + t.to_s }.join("\n") }
Actual argument type(s):
\t(#{args.map { |arg| RDL::Util.rdl_type_or_class(arg) }.join(', ')}) #{if blk then blk.to_s end}
RUBY
      }
    end

    def self.check_ret_types(method_name, types, inst, matches, ret, *args, &blk)
      $__rdl_contract_switch.off {
        matches.each { |i| return true if types[i].post_cond?(inst, ret, *args) }
        method_name = method_name ? method_name + ": " : ""
        raise TypeError, <<RUBY
#{method_name}Return type error. *'s indicate argument lists that matched.
Method type:
#{types.each_with_index.map { |t,i| "       " + (matches.member?(i) ? "*" : " ") + t.to_s }.join("\n") }
Actual return type:
        #{ RDL::Util.rdl_type_or_class(ret)}
RUBY
      }
    end

    def to_s  # :nodoc:
      if @block
        return "(#{@args.map { |arg| arg.to_s }.join(', ')}) {#{@block.to_s}} -> #{@ret.to_s}"
      elsif @args
        return "(#{@args.map { |arg| arg.to_s }.join(', ')}) -> #{@ret.to_s}"
      else
        return "() -> #{@ret.to_s}"
      end
    end

    def eql?(other)
      self == other
    end

    # Return +true+ if +other+ is the same type
    def ==(other)
      return (other.instance_of? MethodType) &&
        (other.args == @args) &&
        (other.block == @block) &&
        (other.ret == @ret)
    end

    def hash  # :nodoc:
      h = (37 + @ret.hash) * 41 + @args.hash
      h = h * 31 + @block.hash if @block
      return h
    end
end
end

