require 'csv'

#$use_twin_network = true
#$use_heuristics = false


class << RDL::Typecheck
  ## Hash<Type, Array<Symbol>>. A Hash mapping RDL types to a list of names of variables that have that type as a solution.
  attr_accessor :type_names_map
  attr_accessor :type_vars_map
end

module RDL::Typecheck

  RUBY_TYPES = ["Abbrev", "Array", "Base64", "BasicObject", "Benchmark", "BigDecimal",
                     "BigMath", "Class", "Complex", "Coverage", "CSV", "Date", "Dir", "Encoding",
                     "Enumerable", "Enumerator", "Exception", "File", "FileUtils", "Float", "Gem",
                     "Hash", "Integer", "IO", "Kernel", "Marshal", "MatchData", "Math", "Module",
                     "NilClass", "Numeric", "Object", "Pathname", "PrettyPrint", "Proc", "Process",
                     "Random", "Range", "Rational", "Regexp", "Set", "String", "StringScanner", "Symbol",
                     "Time", "URI", "YAML", "FalseClass", "TrueClass", "Number"]

  RAILS_TYPES = ["AbstractController", "AbstractController::Translation", "ActionController",
                 "ActionController::Base", "ActionController::Instrumentation", "ActionController::Metal",
                 "ActionController::MimeResponds", "ActionController::Parameters",
                 "ActionController::StrongParameters", "ActionDispatch", 'ActionDispatch::Flash::FlashHash',
                 "ActionMailer", 'ActionMailer::Base', 'ActionMailer::MessageDelivery',
                 'ActionView::Helpers::SanitizeHelper', 'ActionView::Helpers::UrlHelper', 'ActiveModel::Errors',
                 'ActiveModel::Validations', 'ActiveRecord::Associations::CollectionProxy',
                 'ActiveRecord::Associations::ClassMethods', 'ActiveRecord::Base', 'ActiveRecord::FinderMethods',
                 "ActiveRecord::ModelSchema::ClassMethods", 'ActiveRecord::Relation', 'ActiveRecord::Validations',
                 'ActiveSupport::Logger', 'ActiveSupport::TaggedLogging', 'ActiveSupport::TimeWithZone',
                'ActiveSupport::TimeZone']

  @rails_types = []

  @type_names_map = Hash.new { |h, k| h[k] = [] }#[]
  @type_vars_map = Hash.new { |h, k| h[k] = [] }#[]
  @failed_sol_cache = Hash.new { |h, k| h[k] = [] }
  @tried_heuristic_list = {}
  @tried_twin_list = {}  

  @common_matches_by_twin = 0
  @rare_matches_by_twin = 0
  @common_by_twin = 0
  @rare_by_twin = 0
  @tot_orig_common = 0
  @tot_orig_rare = 0 

  def self.empty_cache!
    @type_names_map = Hash.new { |h, k| h[k] = [] }#[]
    @type_vars_map = Hash.new { |h, k| h[k] = [] }#[]
    @failed_sol_cache = Hash.new { |h, k| h[k] = [] }
    @common_matches_by_twin = 0
    @rare_matches_by_twin = 0
    @common_by_twin = 0
    @rare_by_twin = 0
    @tot_orig_common = 0
    @tot_orig_rare = 0 
  end

  def self.resolve_constraints
    RDL::Logging.log_header :inference, :info, "Starting constraint resolution..."
    RDL::Globals.constrained_types.each { |klass, name|
      RDL::Logging.log :inference, :debug, "Resolving constraints from #{RDL::Util.pp_klass_method(klass, name)}"
      typ = RDL::Globals.info.get(klass, name, :type)
      ## If typ is an Array, then it's an array of method types
      ## but for inference, we only use a single method type.
      ## Otherwise, it's a single VarType for an instance/class var.
      if typ.is_a?(Array)
        var_types = name == :initialize ? typ[0].args + [typ[0].block] : typ[0].args + [typ[0].block, typ[0].ret]
      else
        var_types = [typ]
      end

      var_types.each { |var_type|
        begin
          if var_type.var_type? || var_type.optional_var_type? || var_type.vararg_var_type?
            var_type = var_type.type if var_type.optional_var_type? || var_type.vararg_var_type?
            var_type.lbounds.each { |lower_t, ast|
              RDL::Logging.log :typecheck, :trace, "#{lower_t} <= #{var_type}"
              var_type.add_and_propagate_lower_bound(lower_t, ast)
            }
            var_type.ubounds.each { |upper_t, ast|
              var_type.add_and_propagate_upper_bound(upper_t, ast)
            }
          elsif var_type.fht_var_type?
            var_type.elts.values.each { |v|
              vt = v.optional_var_type? || v.vararg_var_type? ? v.type : v
              vt.lbounds.each { |lower_t, ast|
                vt.add_and_propagate_lower_bound(lower_t, ast)
              }
              vt.ubounds.each { |upper_t, ast|
                vt.add_and_propagate_upper_bound(upper_t, ast)
              }
            }
          else
            raise "Got unexpected type #{var_type}."
          end
        rescue => e
          raise e unless RDL::Config.instance.continue_on_errors

          RDL::Logging.log :inference, :debug_error, "Caught error when resolving constraints for #{var_type}; skipping..."
        end
      }
    }
  end

  def self.overly_general?(typ)
    return (typ.is_a?(RDL::Type::UnionType) && !(typ == RDL::Globals.types[:bool])) || (typ == RDL::Globals.types[:bot]) || (typ == RDL::Globals.types[:top]) || (typ == RDL::Globals.types[:nil]) || typ.is_a?(RDL::Type::StructuralType) || typ.is_a?(RDL::Type::IntersectionType) || (typ == RDL::Globals.types[:object])    
  end

  def self.extract_var_sol(var, category, add_sol_to_graph = true)    
    #raise "Expected VarType, got #{var}." unless var.is_a?(RDL::Type::VarType)
    return var.canonical unless var.is_a?(RDL::Type::VarType)
    if category == :arg
      non_vartype_ubounds = var.ubounds.map { |t, ast| t}.reject { |t| t.instance_of?(RDL::Type::VarType) }
      sol = non_vartype_ubounds.size == 1 ? non_vartype_ubounds[0] : RDL::Type::IntersectionType.new(*non_vartype_ubounds).canonical
      sol = sol.drop_vars.canonical if sol.is_a?(RDL::Type::IntersectionType)  ## could be, e.g., nominal type if only one type used to create intersection.
      #return sol
    elsif category == :ret
      non_vartype_lbounds = var.lbounds.map { |t, ast| t}.reject { |t| t.instance_of?(RDL::Type::VarType) }
      sol = RDL::Type::UnionType.new(*non_vartype_lbounds)
      sol = sol.drop_vars.canonical if sol.is_a?(RDL::Type::UnionType)  ## could be, e.g., nominal type if only one type used to create union.
    #return sol
    elsif category == :var
      if var.lbounds.empty? || (var.lbounds.size == 1 && var.lbounds[0][0] == RDL::Globals.types[:bot])
        ## use upper bounds in this case.
        non_vartype_ubounds = var.ubounds.map { |t, ast| t}.reject { |t| t.instance_of?(RDL::Type::VarType) }
        sol = RDL::Type::IntersectionType.new(*non_vartype_ubounds).canonical
        #return sol
      else
        ## use lower bounds
        non_vartype_lbounds = var.lbounds.map { |t, ast| t}.reject { |t| t.instance_of?(RDL::Type::VarType) }
        sol = RDL::Type::UnionType.new(*non_vartype_lbounds)
        sol = sol.drop_vars.canonical if sol.is_a?(RDL::Type::UnionType)  ## could be, e.g., nominal type if only one type used to create union.
        #return sol#RDL::Type::UnionType.new(*non_vartype_lbounds).canonical
      end
    else
      raise "Unexpected VarType category #{category}."
    end
    if  overly_general?(sol)
      ## Try each rule. Return first non-nil result.
      ## If no non-nil results, return original solution.
      ## TODO: check constraints.
      heuristics_start_time = Time.now
      RDL::Logging.log_header :heuristic, :debug, "Beginning Heuristics..."

      RDL::Heuristic.rules.each { |name, rule|
        next if (@counter == 1) && (name == :twin_network)
        next if (name == :twin_network) && !$use_twin_network
        next if (name != :twin_network) && !$use_heuristics
        start_time = Time.now
        RDL::Logging.log :heuristic, :debug, "Trying rule `#{name}` for variable #{var}."
        typ = rule.call(var)
        if typ.is_a?(Array) && (name == :twin_network)
          count = 0
          typ.each { |t|
            @tried_twin_list[var] = true
            new_cons = {}
            count += 1
              begin
                t = t.canonical
                next if @failed_sol_cache[var].include?(t)
                if add_sol_to_graph
                  var.add_and_propagate_upper_bound(t, nil, new_cons)
                  var.add_and_propagate_lower_bound(t, nil, new_cons)
                end
                RDL::Logging.log :hueristic, :debug, "Heuristic Applied: #{name}"
                #puts "Successfully applied twin network! Solution #{t} for #{var}".blue unless $collecting_time_data
                @new_constraints = true if !new_cons.empty?
                RDL::Logging.log :inference, :trace, "New Constraints branch A" if !new_cons.empty?
                raise "2. got here with #{var} and #{t}" if t.to_s == "%bot"
                @type_vars_map[t] = @type_vars_map[t] | [var]
                var.solution_source = "Twin" if (var.solution != t)
                return t
              rescue RDL::Typecheck::StaticTypeError => e
                @failed_sol_cache[var] << t
                undo_constraints(new_cons)
              end
            }
        elsif typ.is_a?(RDL::Type::Type)
          new_cons = {}
          begin
            typ = typ.canonical
            @tried_heuristic_list[var] = true
            next if @failed_sol_cache[var].include?(typ)
            if add_sol_to_graph
              var.add_and_propagate_upper_bound(typ, nil, new_cons)
              var.add_and_propagate_lower_bound(typ, nil, new_cons) 
            end
=begin
               new_cons.each { |var, bounds|
                 bounds.each { |u_or_l, t, _|
                   puts "1. Added #{u_or_l} bound constraint #{t} of kind #{t.class} to variable #{var}"
                   puts "It has upper bounds: "
                   var.ubounds.each { |t, _| puts t }
                 }
               }
=end
            RDL::Logging.log :hueristic, :debug, "Heuristic Applied: #{name}"
            @new_constraints = true if !new_cons.empty?
            RDL::Logging.log :inference, :trace, "New Constraints branch A" if !new_cons.empty?
            raise "3.. got here with #{var} and #{typ} for #{name}" if typ.to_s == "%bot"
            @type_vars_map[typ] = @type_vars_map[typ] | [var] 
            var.solution_source = "Heur: #{name}" if (var.solution != typ)
            return typ
          #sol = typ
          rescue RDL::Typecheck::StaticTypeError => e
            RDL::Logging.log :heuristic, :debug_error, "Attempted to apply heuristic rule #{name} solution #{typ} to var #{var}"
            RDL::Logging.log :heuristic, :trace, "... but got the following error: #{e}"
            @failed_sol_cache[var] << typ
            undo_constraints(new_cons)
          ## no new constraints in this case so we'll leave it as is
          ensure
            total_time = Time.now - start_time
            RDL::Logging.log :hueristic, :debug, "Heuristic #{name} took #{total_time} to evaluate"
          end
        else
          raise "Unexpected return value #{typ} from heuristic rule #{name}." unless typ.nil?
        end
      }

      heuristics_total_time = Time.now - heuristics_start_time
      RDL::Logging.log_header :heuristic, :debug, "Evaluated heuristics in #{heuristics_total_time}"
    end
    ## out here, none of the heuristics applied.
    ## Try to use `sol` as solution -- there is a chance it will
    begin      
      new_cons = {}
      sol = var if sol == RDL::Globals.types[:bot] # just use var itself when result of solution extraction was %bot.
      return sol if sol.is_a?(RDL::Type::VarType) ## don't add var type as solution
      sol = sol.canonical
      raise RDL::Typecheck::StaticTypeError if @failed_sol_cache.include?(sol)
      var.add_and_propagate_upper_bound(sol, nil, new_cons) unless (sol == RDL::Globals.types[:nil])
      var.add_and_propagate_lower_bound(sol, nil, new_cons) unless sol.is_a?(RDL::Type::StructuralType) || (sol.is_a?(RDL::Type::IntersectionType) && sol.types.any? { |t| t.is_a?(RDL::Type::StructuralType) } )# || (sol == RDL::Globals.types[:object]) || (sol == RDL::Globals.types[:top])
=begin
      new_cons.each { |var, bounds|
        bounds.each { |u_or_l, t, _|
          puts "2. Added #{u_or_l} bound constraint #{t} to variable #{var}"
        }
      }
=end
      @new_constraints = true if !new_cons.empty?
      RDL::Logging.log :inference, :trace, "New Constraints branch B" if !new_cons.empty?
      #raise "Adding Solution Array<Number> or Number to variable #{var}".red if (sol.to_s == "(Array<Number> or Number)") && var.to_s != "{ { DashboardSection# var: @row }#[] call_ret: ret }"
      if sol.is_a?(RDL::Type::GenericType)
        new_params = sol.params.map { |p| if p.is_a?(RDL::Type::VarType) && (!p.to_infer || (p == var)) then p else extract_var_sol(p, category) end }
        sol = RDL::Type::GenericType.new(sol.base, *new_params)
      elsif sol.is_a?(RDL::Type::TupleType)
        new_params = sol.params.map { |t| extract_var_sol(t, category) }
        sol = RDL::Type::TupleType.new(*new_params)
      end
    rescue RDL::Typecheck::StaticTypeError => e
      RDL::Logging.log :inference, :debug_error, "Attempted to apply solution #{sol} for var #{var}"
      RDL::Logging.log :inference, :trace, "... but got the following error: #{e}"
      @failed_sol_cache[var] << sol
      undo_constraints(new_cons)
      ## no new constraints in this case so we'll leave it as is
      sol = var
    end
    if (sol.is_a?(RDL::Type::NominalType) || sol.is_a?(RDL::Type::GenericType) || sol.is_a?(RDL::Type::TupleType) || sol.is_a?(RDL::Type::FiniteHashType) || (sol == RDL::Globals.types[:bool])) && !(sol == RDL::Globals.types[:object])
      raise "1. got here with #{var} and #{sol}" if sol.to_s == "%bot"
      name = var.base_name#(var.category == :ret) ? var.meth : var.name
      @type_names_map[sol] = @type_names_map[sol] | [name.to_s]
      @type_vars_map[sol] = @type_vars_map[sol] | [var]
    end
    var.solution_source = "Constraints" if (var.solution != sol)
    return sol
  end

  # [+ cons +] is Hash<VarType, [:upper or :lower], Type, AST> of constraints to be undone.
  def self.undo_constraints(cons)
    cons.each_key { |var_type|
      cons[var_type].each { |upper_or_lower, bound_t, ast|
        if upper_or_lower == :upper
          var_type.ubounds.delete([bound_t, ast])
        elsif upper_or_lower == :lower
          var_type.lbounds.delete([bound_t, ast])
        end
      }
    }
  end

  def self.extract_meth_sol(tmeth)
    raise "Expected MethodType, got #{tmeth}." unless tmeth.is_a?(RDL::Type::MethodType)
    ## ARG SOLUTIONS
    arg_sols = tmeth.args.map { |a|
      if a.optional_var_type?
        soln = RDL::Type::OptionalType.new(extract_var_sol(a.type, :arg))
      elsif a.fht_var_type?
        hash_sol = a.elts.transform_values { |v|
          if v.is_a?(RDL::Type::OptionalType)
            RDL::Type::OptionalType.new(extract_var_sol(v.type, :arg))
          else
            extract_var_sol(v, :arg)
          end
        }
        soln = RDL::Type::FiniteHashType.new(hash_sol, nil)
      else
        soln = extract_var_sol(a, :arg)
      end

      a.solution = soln
      soln
    }

    ## BLOCK SOLUTION
    if tmeth.block && !tmeth.block.ubounds.empty?
      non_vartype_ubounds = tmeth.block.ubounds.map { |t, ast| t.canonical }.reject { |t| t.is_a?(RDL::Type::VarType) }
      non_vartype_ubounds.reject! { |t| t.is_a?(RDL::Type::StructuralType) }#&& (t.methods.size == 1) && (t.methods.has_key?(:to_proc) || t.methods.has_key?(:call)) }
      if non_vartype_ubounds.size == 0
        block_sol = tmeth.block
      elsif non_vartype_ubounds.size > 1
        block_sols = []
        inter = RDL::Type::IntersectionType.new(*non_vartype_ubounds).canonical
        typs = inter.is_a?(RDL::Type::IntersectionType) ? inter.types : [inter]
        typs.each { |m|
          #raise "Expected block type to be a MethodType, got #{m}." unless m.is_a?(RDL::Type::MethodType)
          block_sols << (m.is_a?(RDL::Type::MethodType) ? RDL::Type::MethodType.new(*extract_meth_sol(m)) : m)
        }
        block_sol = RDL::Type::IntersectionType.new(*block_sols).canonical
      else
        if non_vartype_ubounds[0].is_a?(RDL::Type::NominalType) && (non_vartype_ubounds[0].to_s == "Proc")
          block_sol = non_vartype_ubounds[0]
        elsif !non_vartype_ubounds[0].is_a?(RDL::Type::MethodType)
          block_sol = tmeth.block
        else
          block_sol = RDL::Type::MethodType.new(*extract_meth_sol(non_vartype_ubounds[0]))
        end
      end

      tmeth.block.solution = block_sol
    else
      block_sol = nil
    end

    ## RET SOLUTION
    if tmeth.ret.to_s == "self"
      ret_sol = tmeth.ret
    else
      ret_sol = tmeth.ret.is_a?(RDL::Type::VarType) ? extract_var_sol(tmeth.ret, :ret) : tmeth.ret
    end

    tmeth.ret.solution = ret_sol

    return [arg_sols, block_sol, ret_sol]
  end

  # Compares a single inferred type to original type.
  # Returns "E" (exact match), "P" (match up to parameter), "T" (no match but got a type), or "N" (no type).
  # [+ inf_type +] is the inferred type
  # [+ orig_type +] is the original, gold standard type
  def self.compare_single_type(inf_type, orig_type)
    inf_type = inf_type.type if inf_type.optional? || inf_type.vararg?
    orig_type = orig_type.type if orig_type.optional? || orig_type.vararg?
    inf_type = inf_type.canonical
    orig_type = orig_type.canonical
    if inf_type.to_s == orig_type.to_s
      return "E"
    elsif inf_type.is_a?(RDL::Type::NominalType) && orig_type.is_a?(RDL::Type::NominalType) && abbreviated_class?(orig_type.to_s, inf_type.to_s)
      ## needed for diferring scopes, e.g. TZInfo::Timestamp & Timestamp
      return "E"      
    elsif inf_type.is_a?(RDL::Type::NominalType) && orig_type.is_a?(RDL::Type::NominalType) && inf_type.klass.ancestors.any? { |anc| (anc.to_s == orig_type.to_s) || abbreviated_class?(orig_type.to_s, anc.to_s) }
      return "E"
    elsif inf_type.is_a?(RDL::Type::GenericType) && (orig_type == RDL::Globals.types[:object])
      return "E"
    elsif [inf_type.to_s, orig_type.to_s].all? { |t| ["String", "Symbol", "(String or Symbol)", "(Symbol or String)"].include?(t) }
      return "E"
    elsif inf_type.is_a?(RDL::Type::UnionType) && orig_type.is_a?(RDL::Type::NominalType) && inf_type.types.all? { |t| t.is_a?(RDL::Type::NominalType) && t.klass.ancestors.any? { |anc| (anc.to_s == orig_type.to_s) || abbreviated_class?(orig_type.to_s, anc.to_s) } }
      return "E"
    elsif !inf_type.is_a?(RDL::Type::VarType) && (orig_type.is_a?(RDL::Type::TopType))
      return "E"
    elsif inf_type.is_a?(RDL::Type::GenericType) && orig_type.is_a?(RDL::Type::GenericType) && inf_type.params[0] == orig_type.params[0] && inf_type.array_type? && orig_type.array_type?
      return "E"
    elsif inf_type.is_a?(RDL::Type::StructuralType) && orig_type.is_a?(RDL::Type::StructuralType) && (inf_type.methods.map { |m, _| m } == orig_type.methods.map { |m, _| m})
      return "E"
    elsif inf_type.is_a?(RDL::Type::SingletonType) && orig_type.is_a?(RDL::Type::NominalType) && inf_type.val.class.to_s == orig_type.name
      return "E"
    elsif inf_type.is_a?(RDL::Type::GenericType) && orig_type.is_a?(RDL::Type::GenericType) && inf_type.base.to_s == orig_type.base.to_s
      return "P"
    elsif inf_type.is_a?(RDL::Type::GenericType) && orig_type.is_a?(RDL::Type::NominalType) && inf_type.base.to_s == orig_type.to_s
      return "P"
    elsif orig_type.is_a?(RDL::Type::GenericType) && inf_type.is_a?(RDL::Type::NominalType) && orig_type.base.to_s == inf_type.to_s
      return "P"
    elsif inf_type.array_type? && orig_type.array_type?
      return "P"
    elsif inf_type.hash_type? && orig_type.hash_type?
      return "P"
    elsif !inf_type.is_a?(RDL::Type::VarType)
      if inf_type.is_a?(RDL::Type::StructuralType) || (inf_type.is_a?(RDL::Type::IntersectionType) && inf_type.types.any? { |t| t.is_a?(RDL::Type::StructuralType) })
        return "TS"
      else
        return "T"
      end
    else
      return "N"
    end
  end

  def self.abbreviated_class?(abbrev, original)
    abbrev = abbrev.to_s
    original = original.to_s
    original.end_with?("::" + abbrev)
  end


  def self.make_extraction_report(typ_sols)
    report = RDL::Reporting::InferenceReport.new
    #twin_csv = CSV.open("#{if !$use_twin_network then 'no_' end}twin_#{if $use_heuristics then 'heur_' end}_#{RDL::Heuristic.simscore_cutoff}_#{RDL::Heuristic.get_top_n}_infer_data.csv", 'wb')
    twin_csv = CSV.open("#{if $headeronly then 'headeronly_' end}#{if $namesonly then 'namesonly_' end}#{$infer_config}_top#{RDL::Heuristic.get_top_n}_infer_data.csv", 'wb')
    twin_csv << ["Class", "Method Name", "Arg/Ret/Var", "Variable Name", 
                 "Inferred Type", "Original Type", "Exact (E) / Up to Parameter (P) / Got Type (T) / None (N)", "Solution Source", "Source Code"]
    compares = Hash.new 0 
    ## Twin CSV format: [Class, Name, ]
    #return unless $orig_types

    # complete_types = []
    # incomplete_types = []

    # CSV.open("infer_data.csv", "wb") { |csv|
    #   csv << ["Class", "Method", "Inferred Type", "Original Type", "Source Code", "Comments"]
    # }

    correct_types = 0
    meth_types = 0
    ret_types = 0
    arg_types = 0
    var_types = 0
    noncomp_args = 0
    noncomp_rets = 0
    noncomp_vars = 0
    noncomp_meths = 0
    noncomp_no_type = 0
    noncomp_og = 0
    noncomp_usable = 0
    num_lines = 0
    num_casts = 0
    diff_struct_types = 0
    no_type_tried_heur = 0
    no_type_tried_twin = 0
    arr_type_rejected = 0
    hash_type_rejected = 0
    typ_sols.each_pair { |km, typ|
      compared = false
      klass, meth = km
      orig_typ = RDL::Globals.info.get(klass, meth, :orig_type)
      next if typ.solution.nil?
      if orig_typ.nil?
        if typ.is_a?(RDL::Type::MethodType)
          noncomp_meths += 1
          typ.args.each { |t|
            noncomp_args +=1
            t = t.solution
            if t.nil? || t.kind_of_var_input?
              noncomp_no_type += 1
            elsif overly_general?(t)
              noncomp_og += 1
            else
              noncomp_usable += 1
            end
          }
          noncomp_rets += 1
          if typ.ret.solution.nil? || typ.ret.solution.kind_of_var_input?
            noncomp_no_type += 1
          elsif overly_general?(typ.ret)
            noncomp_og += 1
          else
            noncomp_usable += 1
          end
        elsif typ.is_a?(RDL::Type::VarType)
          noncomp_vars += 1
          if typ.solution.nil? || typ.solution.kind_of_var_input?
            noncomp_no_type += 1
          elsif overly_general?(typ.solution)
            noncomp_og += 1
          else
            noncomp_usable += 1
          end
        else
          raise "Unexpected kind #{typ.class}"
        end
        next
      end
      if orig_typ.is_a?(Array)
        raise "expected just one original type for #{klass}##{meth}" unless orig_typ.size == 1
        orig_typ = orig_typ[0]
      end
      if orig_typ.is_a?(RDL::Type::MethodType)
        ast = RDL::Typecheck.get_ast(klass, meth)
        code = ast.loc.expression.source
        orig_typ.args.each_with_index { |orig_arg_typ, i |
          inf_arg_type = typ.solution.args[i]
          comp = inf_arg_type.nil? ? "N" : compare_single_type(inf_arg_type, orig_arg_typ)
          compared = true
          compares[comp] += 1
          if typ.args[i].nil?
            name = nil
          elsif (typ.args[i].optional? || typ.args[i].vararg?)
            name = typ.args[i].type.base_name
            sol_source = typ.args[i].type.solution_source
          elsif typ.args[i].is_a?(RDL::Type::FiniteHashType)
            name = typ.args[i].to_s
            sol_source = "TODO: handle FHTs"
          else
            name = typ.args[i].base_name
            sol_source = typ.args[i].solution_source
          end
          twin_csv << [klass, meth, "Arg", name, inf_arg_type.to_s, orig_arg_typ.to_s, comp, sol_source, code]
          arg_types +=1
          update_type_counts(inf_arg_type, orig_arg_typ, comp, sol_source)
          if comp == "N"
            no_type_tried_heur += 1 if @tried_heuristic_list.has_key?(inf_arg_type)
            no_type_tried_twin += 1 if @tried_twin_list.has_key?(inf_arg_type)
            arr_type_rejected += 1 if orig_arg_typ.array_type? && @failed_sol_cache[inf_arg_type].any? { |t| t.array_type? }
            hash_type_rejected += 1 if orig_arg_typ.hash_type? && @failed_sol_cache[inf_arg_type].any? { |t| t.hash_type? }
          end
        }
        unless (orig_typ.ret == RDL::Globals.types[:bot]) ## bot type is given to any returns for which we don't have a type
          ret_types += 1
          inf_ret_type = typ.solution.ret
          sol_source = typ.ret.solution_source
          comp = inf_ret_type.nil? ? "N" : compare_single_type(inf_ret_type, orig_typ.ret)
          if comp == "N"
            no_type_tried_heur += 1 if @tried_heuristic_list.has_key?(inf_ret_type)
            no_type_tried_twin += 1 if @tried_twin_list.has_key?(inf_ret_type)
            arr_type_rejected += 1 if orig_typ.ret.array_type? && @failed_sol_cache[inf_ret_type].any? { |t| t.array_type? }
            hash_type_rejected += 1 if orig_typ.ret.hash_type? && @failed_sol_cache[inf_ret_type].any? { |t| t.hash_type? }
            
          end
          compared = true
          update_type_counts(inf_ret_type, orig_typ, comp, sol_source)
          compares[comp] += 1
          twin_csv << [klass, meth, "Ret", "", inf_ret_type.to_s, orig_typ.ret.to_s, comp, sol_source, code]
        end
        if compared
          meth_types += 1
          num_lines += RDL::Util.count_num_lines(klass, meth)
          num_casts += RDL::Typecheck.get_meth_casts(klass, meth)
        else
          noncomp_meths += 1
          typ.args.each { |t|            
            t = t.solution
            noncomp_args +=1
            if t.nil? || t.kind_of_var_input?
              noncomp_no_type += 1
            elsif overly_general?(t)
              noncomp_og += 1
            else
              noncomp_usable += 1
            end
          }
          noncomp_rets += 1
          if typ.ret.solution.kind_of_var_input? || typ.ret.solution.nil?
            noncomp_no_type += 1
          elsif overly_general?(typ.ret.solution)
            noncomp_og += 1
          else
            noncomp_usable += 1
          end
        end
      else
        comp = typ.solution.nil? ? "N" : compare_single_type(typ.solution, orig_typ)
        if comp == "N"
          no_type_tried_heur += 1 if @tried_heuristic_list.has_key?(typ)
          no_type_tried_twin += 1 if @tried_twin_list.has_key?(typ)
          arr_type_rejected += 1 if orig_typ.array_type? && @failed_sol_cache[typ].any? { |t| t.array_type? }
          hash_type_rejected += 1 if orig_typ.hash_type? && @failed_sol_cache[typ].any? { |t| t.hash_type? }          
        end        
        compares[comp] += 1
        sol_source = typ.solution_source
        update_type_counts(typ.solution, orig_typ, comp, sol_source)
        twin_csv << [klass, meth, "Var", meth, typ.solution.to_s, orig_typ.to_s, comp, sol_source, ""]
        var_types += 1
      end

      if !meth.to_s.include?("@") && !meth.to_s.include?("$")#orig_typ.is_a?(RDL::Type::MethodType)
        ast = RDL::Typecheck.get_ast(klass, meth)
        code = ast.loc.expression.source
        # if RDL::Util.has_singleton_marker(klass)
        #   comment = RDL::Util.to_class(RDL::Util.remove_singleton_marker(klass)).method(meth).comment
        # else
        #   comment = RDL::Util.to_class(klass).instance_method(meth).comment
        # end
        # csv << [klass, meth, typ, orig_typ, code] #, comment

        report[klass] << { klass: klass, method_name: meth, type: typ,
                           orig_type: orig_typ, source_code: code }


        # if typ.include?("XXX")
        #  incomplete_types << [klass, meth, typ, orig_typ, code, comment]
        # else
        #  complete_types << [klass, meth, typ, orig_typ, code, comment]
        # end
      end
    }

    RDL::Logging.log_header :inference, :info, "Extraction Complete"
    #RDL::Logging.log :inference, :info, "SIMILARITY SCORE CUTOFF = #{RDL::Heuristic.simscore_cutoff}"
    RDL::Logging.log :inference, :info, "DeepSim using top N=#{RDL::Heuristic.get_top_n} Guesses"
    twin_csv << ["Total # E:", compares["E"]]
    RDL::Logging.log :inference, :info, "Total exact matches (E): #{compares["E"]}"
    twin_csv << ["Total # P:", compares["P"]]
    RDL::Logging.log :inference, :info, "Total matches up to parameter (P): #{compares["P"]}"
    twin_csv << ["Total # T:", compares["T"]]
    RDL::Logging.log :inference, :info, "Total not match but got type for (T): #{compares["T"] + compares["TS"]}"
    twin_csv << ["Total # TS:", compares["TS"]]
    RDL::Logging.log :inference, :info, "Total number of T's that were structural types: #{compares["TS"]}"
    twin_csv << ["Total # N:", compares["N"]]
    RDL::Logging.log :inference, :info, "Total no type for (N): #{compares["N"]}"
    #RDL::Logging.log :inference, :info, "Of N types, tried to apply a heuristic guess to #{no_type_tried_heur} positions, and tried to apply a DeepSim guess to #{no_type_tried_twin} positions. #{arr_type_rejected} array types were rejected even though the orig was an array type, and #{hash_type_rejected} hash types were rejected, etc."        
    #twin_csv << ["Total # method types:", meth_types]
    RDL::Logging.log :inference, :info, "Total # compared method types: #{meth_types} comprising #{num_lines} lines"
    RDL::Logging.log :inference, :info, "Total # casts within compared method: #{num_casts}"
    #RDL::Logging.log :inference, :info, "#{noncomp_meths} non-compared methods (#{noncomp_args} args/#{noncomp_rets} rets) and #{noncomp_vars} non-compared variables. Of these, inferred: #{noncomp_usable} usable types, #{noncomp_og} overly general types, and #{noncomp_no_type} no types."
    twin_csv << ["Total # return types:", ret_types]
    RDL::Logging.log :inference, :info, "Total # return types: #{ret_types}"
    twin_csv << ["Total # arg types:", arg_types]
    RDL::Logging.log :inference, :info, "Total # argument types: #{arg_types}"
    twin_csv << ["Total # var types:", var_types]
    RDL::Logging.log :inference, :info, "Total # variable types: #{var_types}"
    twin_csv << ["Total # individual types:", var_types + meth_types + arg_types]
    RDL::Logging.log :inference, :info, "Total # individual types: #{ret_types + arg_types + var_types}"
=begin
    RDL::Logging.log :inference, :info, "Total # library types guessed by twin: #{@common_by_twin}."
    RDL::Logging.log :inference, :info, "Total # library type matches guessed by twin: #{@common_matches_by_twin}."
    RDL::Logging.log :inference, :info, "Total # rare types guessed by twin: #{@rare_by_twin}"
    RDL::Logging.log :inference, :info, "Total # rare type *matches* guessed by twin: #{@rare_matches_by_twin}"
    #RDL::Logging.log :inference, :info, "Total # common type originals: #{@tot_orig_common}"
    #RDL::Logging.log :inference, :info, "Total # rare type originals: #{@tot_orig_rare}"
=end
    $results_hash[:matches] = compares["E"]
    $results_hash[:param] = compares["P"]
    $results_hash[:gottype] = compares["T"] + compares["TS"]
    $results_hash[:struct] = compares["TS"]
    $results_hash[:notype] = compares["N"]
    $results_hash[:compared_meths] = meth_types
    $results_hash[:compared_ret_types] = ret_types
    $results_hash[:compared_arg_types] = arg_types
    $results_hash[:compared_var_types] = var_types
    $results_hash[:compared_meths_lines] = num_lines
    $results_hash[:compared_meths_casts] = num_casts
    $results_hash[:noncomp_meths] = noncomp_meths
    $results_hash[:noncomp_args] = noncomp_args
    $results_hash[:noncomp_rets] = noncomp_rets
    $results_hash[:noncomp_vars] = noncomp_vars
    $results_hash[:noncomp_usable] = noncomp_usable
    $results_hash[:noncomp_og] = noncomp_og
    $results_hash[:noncomp_no_type] = noncomp_no_type
    $results_hash[:noncomp_meths_lines] = num_lines
    $results_hash[:noncomp_meths_casts] = num_casts
    $results_hash[:library_guesses_by_twin] = @common_by_twin
    $results_hash[:library_matches_by_twin] = @common_matches_by_twin
  rescue => e
    RDL::Logging.log :inference, :error, "Report Generation Error"
    RDL::Logging.log :inference, :debug_error, "... got #{e}"
    puts "Got: #{e}"
    raise e unless RDL::Config.instance.continue_on_errors
  ensure
    return report
  end

  def self.update_type_counts(inf_type, orig_type, comp, sol_source)
    if common_type?(orig_type)
      @tot_orig_common += 1
    else
      @tot_orig_rare += 1
    end
    return unless (sol_source == "Twin") ## not interested in cases that constraints/heuristics got
    if common_type?(inf_type) 
      @common_by_twin += 1
      if ["E"].include?(comp)#if ["E", "P"].include?(comp)
        @common_matches_by_twin += 1
      end
    else
      ## rare type
      @rare_by_twin += 1
      if ["E"].include?(comp)#if ["E", "P"].include?(comp)
        @rare_matches_by_twin += 1
      end
    end
  end

  def self.common_type?(t)
    t = t.type if t.optional? || t.vararg?
    (t.is_a?(RDL::Type::NominalType) && (RUBY_TYPES.include?(t.name) || RAILS_TYPES.include?(t.name))) ||
      (t == RDL::Globals.types[:bool]) ||
      (t.to_s == "self") ||
      (t.is_a?(RDL::Type::GenericType) && common_type?(t.base)) ||
      (t.is_a?(RDL::Type::UnionType) && t.types.all? { |arm| common_type?(arm) } )

  end

  def self.extract_solutions()
    ## Go through once to come up with solution for all var types.
    RDL::Logging.log_header :inference, :info, "Begin Extract Solutions"
    if $use_twin_network
      uri = URI "http://127.0.0.1:5000/"
      $http = Net::HTTP.new(uri.hostname, uri.port)
      $http.start
    end
    @counter = 0;
    used_twin = false
    typ_sols = {}
    loop do
      @counter += 1
      @new_constraints = false
      typ_sols = {}

      RDL::Logging.log :inference, :info, "[#{@counter}] Running solution extraction..."
      RDL::Globals.constrained_types.each { |klass, name|
        begin
          RDL::Logging.log :inference, :debug, "Extracting #{RDL::Util.pp_klass_method(klass, name)}"
          RDL::Type::VarType.no_print_XXX!
          typ = RDL::Globals.info.get(klass, name, :type)
          if typ.is_a?(Array)
            raise "Expected just one method type for #{klass}#{name}." unless typ.size == 1
            tmeth = typ[0]

            arg_sols, block_sol, ret_sol = extract_meth_sol(tmeth)

            block_string = block_sol ? " { #{block_sol} }" : nil
            RDL::Logging.log :inference, :trace, "Extracted solution for #{klass}\##{name} is (#{arg_sols.join(',')})#{block_string} -> #{ret_sol}"

            #meth_sol = RDL::Type::MethodType.new arg_sols, block_sol, ret_sol

            typ_sols[[klass.to_s, name.to_sym]] = tmeth
          elsif name.to_s == "splat_param"
          else
            ## Instance/Class (also some times splat parameter) variables:
            ## There is no clear answer as to what to do in this case.
            ## Just need to pick something in between bounds (inclusive).
            ## For now, plan is to just use lower bound when it's not empty/%bot,
            ## otherwise use upper bound.
            ## Can improve later if desired.
            var_sol = extract_var_sol(typ, :var)
            typ.solution = var_sol
            RDL::Logging.log :inference, :trace, "Extracted solution for #{klass} variable #{name} is #{var_sol}."
            typ_sols[[klass.to_s, name.to_sym]] = typ
          end
        rescue => e
          puts "GOT HERE WITH #{e}"
          RDL::Logging.log :inference, :debug_error, "Error while exctracting solution for #{RDL::Util.pp_klass_method(klass, name)}: #{e}; continuing..."
          raise e unless RDL::Config.instance.continue_on_errors
        end
      }
      ## Trying: out here on last run, now try applying twin network to each pair of var types
      if false #$use_twin_network && !@new_constraints && !used_twin
        constrained_vars = []
        RDL::Globals.constrained_types.each { |klass, name|
          typ = RDL::Globals.info.get(klass, name, :type)
          ## First, collect *each individual VarType* into constrained_vars array
          if typ.is_a?(Array)
            typ[0].args.each { |a|
              case a
              when RDL::Type::VarType
                constrained_vars << a
              when RDL::Type::OptionalType, RDL::Type::VarargType
                constrained_vars << a.type
              when RDL::Type::FiniteHashType
                a.elts.values.each { |v|
                  vt = v.optional_var_type? || v.vararg_var_type? ? v.type : v
                  constrained_vars << vt
                }
              else
                raise "Expected type variable, got #{a}."
              end
            }
            #constrained_vars = constrained_vars + typ[0].args
            constrained_vars << typ[0].ret
          elsif name.to_s == "splat_param"
          else
            constrained_vars << typ
          end
        }
        pairs_enum = constrained_vars.combination(2)
        RDL::Heuristic.twin_network_constraints(pairs_enum)
        used_twin = true
      end
      break if !@new_constraints
    end
  rescue => e
    puts "RECEIVED ERROR #{e} from #{e.backtrace}" 
  ensure
    $http.finish if $http
    #puts "MAKING EXTRACTION REPORT"
    return make_extraction_report(typ_sols)
  end

  def self.set_new_constraints
    @new_constraints = true
  end


end
