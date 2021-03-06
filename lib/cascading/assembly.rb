# Copyright 2009, Grégoire Marabout. All Rights Reserved.
#
# This is free software. Please see the LICENSE and COPYING files for details.

require 'cascading/base'
require 'cascading/operations'
require 'cascading/ext/array'

module Cascading
  class Assembly < Cascading::Node
    include Operations

    attr_accessor :tail_pipe, :head_pipe, :outgoing_scopes

    def initialize(name, parent, outgoing_scopes = {})
      super(name, parent)

      @every_applied = false
      @outgoing_scopes = outgoing_scopes
      if parent.kind_of?(Assembly)
        @head_pipe = Java::CascadingPipe::Pipe.new(name, parent.tail_pipe)
        # Copy to allow destructive update of name
        @outgoing_scopes[name] = parent.scope.copy
        scope.scope.name = name
      else # Parent is a Flow
        @head_pipe = Java::CascadingPipe::Pipe.new(name)
        @outgoing_scopes[name] ||= Scope.empty_scope(name)
      end
      @tail_pipe = @head_pipe
    end

    def parent_flow
      return parent if parent.kind_of?(Flow)
      parent.parent_flow
    end

    def scope
      @outgoing_scopes[name]
    end

    def debug_scope
      puts "Current scope for '#{name}':\n  #{scope}\n----------\n"
    end

    def primary(*args)
      options = args.extract_options!
      if args.size > 0 && args[0] != nil
        scope.primary_key_fields = fields(args)
      else
        scope.primary_key_fields = nil
      end
      scope.grouping_primary_key_fields = scope.primary_key_fields
    end

    def make_each(type, *parameters)
      make_pipe(type, parameters)
      @every_applied = false
    end

    def make_every(type, *parameters)
      make_pipe(type, parameters, scope.grouping_key_fields)
      @every_applied = true
    end

    def every_applied?
      @every_applied
    end

    def do_every_block_and_rename_fields(group_fields, incoming_scopes, &block)
      return unless block

      # TODO: this should really be instance evaled on an object
      # that only allows aggregation and buffer operations.
      instance_eval &block

      # First all non-primary key fields from each pipe if its primary key is a
      # subset of the grouping primary key
      first_fields = incoming_scopes.map do |scope|
        if scope.primary_key_fields
          primary_key = scope.primary_key_fields.to_a
          grouping_primary_key = scope.grouping_primary_key_fields.to_a
          if (primary_key & grouping_primary_key) == primary_key
            difference_fields(scope.values_fields, scope.primary_key_fields).to_a
          end
        end
      end.compact.flatten
      # assert first_fields == first_fields.uniq

      # Do no first any fields explicitly aggregated over
      first_fields = first_fields - scope.grouping_fields.to_a
      if first_fields.size > 0
        first *first_fields
        puts "Firsting: #{first_fields.inspect} in assembly: #{@name}"
      end

      bind_names scope.grouping_fields.to_a if every_applied?
    end

    def make_pipe(type, parameters, grouping_key_fields = [], incoming_scopes = [scope])
      @tail_pipe = type.new(*parameters)
      @outgoing_scopes[name] = Scope.outgoing_scope(@tail_pipe, incoming_scopes, grouping_key_fields, every_applied?)
    end

    def to_s
      "#{@name} : head pipe : #{@head_pipe} - tail pipe: #{@tail_pipe}"
    end

    # Builds a join (CoGroup) pipe. Requires a list of assembly names to join.
    def join(*args, &block)
      options = args.extract_options!

      pipes, incoming_scopes = [], []
      args.each do |assembly_name|
        assembly = parent_flow.find_child(assembly_name)
        raise "Could not find assembly '#{assembly_name}' in join" unless assembly

        pipes << assembly.tail_pipe
        incoming_scopes << @outgoing_scopes[assembly.name]
      end

      group_fields_args = options.delete(:on)
      if group_fields_args.kind_of?(String)
        group_fields_args = [group_fields_args]
      end
      group_fields_names = group_fields_args.to_a
      group_fields = []
      if group_fields_args.kind_of?(Array)
        pipes.size.times do
          group_fields << fields(group_fields_args)
        end
      elsif group_fields_args.kind_of?(Hash)
        pipes, incoming_scopes = [], []
        keys = group_fields_args.keys.sort
        keys.each do |assembly_name|
          v = group_fields_args[assembly_name]
          assembly = parent_flow.find_child(assembly_name)
          raise "Could not find assembly '#{assembly_name}' in join" unless assembly

          pipes << assembly.tail_pipe
          incoming_scopes << @outgoing_scopes[assembly.name]
          group_fields << fields(v)
          group_fields_names = group_fields_args[keys.first].to_a
        end
      end

      group_fields = group_fields.to_java(Java::CascadingTuple::Fields)
      incoming_fields = incoming_scopes.map{ |s| s.values_fields }
      declared_fields = fields(options[:declared_fields] || dedup_fields(*incoming_fields))
      joiner = options.delete(:joiner)

      if declared_fields
        case joiner
        when :inner, "inner", nil
          joiner = Java::CascadingPipeCogroup::InnerJoin.new
        when :left,  "left"
          joiner = Java::CascadingPipeCogroup::LeftJoin.new
        when :right, "right"
          joiner = Java::CascadingPipeCogroup::RightJoin.new
        when :outer, "outer"
          joiner = Java::CascadingPipeCogroup::OuterJoin.new
        when Array
          joiner = joiner.map do |t|
            case t
            when true,  1, :inner then true
            when false, 0, :outer then false
            else fail "invalid mixed joiner entry: #{t}"
            end
          end
          joiner = Java::CascadingPipeCogroup::MixedJoin.new(joiner.to_java(:boolean))
        end
      end

      parameters = [pipes.to_java(Java::CascadingPipe::Pipe), group_fields, declared_fields, joiner].compact
      grouping_key_fields = group_fields[0] # Left key group wins
      make_pipe(Java::CascadingPipe::CoGroup, parameters, grouping_key_fields, incoming_scopes)
      do_every_block_and_rename_fields(group_fields_names, incoming_scopes, &block)
    end
    alias co_group join

    def inner_join(*args, &block)
      options = args.extract_options!
      options[:joiner] = :inner
      args << options
      join(*args, &block)
    end

    def left_join(*args, &block)
      options = args.extract_options!
      options[:joiner] = :left
      args << options
      join(*args, &block)
    end

    def right_join(*args, &block)
      options = args.extract_options!
      options[:joiner] = :right
      args << options
      join(*args, &block)
    end

    def outer_join(*args, &block)
      options = args.extract_options!
      options[:joiner] = :outer
      args << options
      join(*args, &block)
    end

    # Builds a new branch.
    def branch(name, &block)
      raise "Could not build branch '#{name}'; block required" unless block_given?
      assembly = Assembly.new(name, self, @outgoing_scopes)
      add_child(assembly)
      assembly.instance_eval(&block)
      assembly
    end

    # Builds a new _group_by_ pipe. The fields used for grouping are specified in the args
    # array.
    def group_by(*args, &block)
      options = args.extract_options!

      group_fields = fields(args)

      sort_fields = fields(options[:sort_by] || args)
      reverse = options[:reverse]

      parameters = [@tail_pipe, group_fields, sort_fields, reverse].compact
      make_pipe(Java::CascadingPipe::GroupBy, parameters, group_fields)
      do_every_block_and_rename_fields(args, [scope], &block)
    end

    # Unifies several pipes sharing the same field structure.
    # This actually creates a GroupBy pipe.
    # It expects a list of assembly names as parameter.
    def union_pipes(*args)
      pipes, incoming_scopes = [], []
      args[0].each do |assembly_name|
        assembly = parent_flow.find_child(assembly_name)
        pipes << assembly.tail_pipe
        incoming_scopes << @outgoing_scopes[assembly.name]
      end

      # Groups only on the 1st field (see line 186 of GroupBy.java)
      grouping_key_fields = fields(incoming_scopes.first.values_fields.get(0))
      make_pipe(Java::CascadingPipe::GroupBy, [pipes.to_java(Java::CascadingPipe::Pipe)], grouping_key_fields, incoming_scopes)
      # TODO: Shouldn't union_pipes accept an every block?
      #do_every_block_and_rename_fields(args, incoming_scopes, &block)
    end

    # Builds an basic _every_ pipe, and adds it to the current assembly.
    def every(*args)
      options = args.extract_options!

      in_fields = fields(args)
      out_fields = fields(options[:output])
      operation = options[:aggregator] || options[:buffer]

      parameters = [@tail_pipe, in_fields, operation, out_fields].compact
      make_every(Java::CascadingPipe::Every, *parameters)
    end

    # Builds a basic _each_ pipe, and adds it to the current assembly.
    # --
    # Example:
    #     each "line", :filter=>regex_splitter(["name", "val1", "val2", "id"],
    #                  :pattern => /[.,]*\s+/),
    #                  :output=>["id", "name", "val1", "val2"]
    def each(*args)
      options = args.extract_options!

      in_fields = fields(args)
      out_fields = fields(options[:output])
      operation = options[:filter] || options[:function]

      parameters = [@tail_pipe, in_fields, operation, out_fields].compact
      make_each(Java::CascadingPipe::Each, *parameters)
    end

    # Restricts the current assembly to the specified fields.
    # --
    # Example:
    #     project "field1", "field2"
    def project(*args)
      fields = fields(args)
      operation = Java::CascadingOperation::Identity.new
      make_each(Java::CascadingPipe::Each, @tail_pipe, fields, operation)
    end

    # Removes the specified fields from the current assembly.
    # --
    # Example:
    #     discard "field1", "field2"
    def discard(*args)
      discard_fields = fields(args)
      keep_fields = difference_fields(scope.values_fields, discard_fields)
      project(*keep_fields.to_a)
    end

    # Assign new names to initial fields in positional order.
    # --
    # Example:
    #     bind_names "field1", "field2"
    def bind_names(*new_names)
      new_fields = fields(new_names)
      operation = Java::CascadingOperation::Identity.new(new_fields)
      make_each(Java::CascadingPipe::Each, @tail_pipe, all_fields, operation)
    end

    # Renames fields according to the mapping provided.
    # --
    # Example:
    #     rename "old_name" => "new_name"
    def rename(name_map)
      old_names = scope.values_fields.to_a
      new_names = old_names.map{ |name| name_map[name] || name }
      invalid = name_map.keys.sort - old_names
      raise "invalid names: #{invalid.inspect}" unless invalid.empty?

      old_key = scope.primary_key_fields.to_a
      new_key = old_key.map{ |name| name_map[name] || name }

      new_fields = fields(new_names)
      operation = Java::CascadingOperation::Identity.new(new_fields)
      make_each(Java::CascadingPipe::Each, @tail_pipe, all_fields, operation)
      primary(*new_key)
    end

    def cast(type_map)
      names = type_map.keys.sort
      types = JAVA_TYPE_MAP.values_at(*type_map.values_at(*names))
      fields = fields(names)
      types = types.to_java(java.lang.Class)
      operation = Java::CascadingOperation::Identity.new(fields, types)
      make_each(Java::CascadingPipe::Each, @tail_pipe, fields, operation)
    end

    def copy(*args)
      options = args.extract_options!
      from = args[0] || all_fields
      into = args[1] || options[:into] || all_fields
      operation = Java::CascadingOperation::Identity.new(fields(into))
      make_each(Java::CascadingPipe::Each, @tail_pipe, fields(from), operation, Java::CascadingTuple::Fields::ALL)
    end

    # A pipe that does nothing.
    def pass(*args)
      operation = Java::CascadingOperation::Identity.new
      make_each(Java::CascadingPipe::Each, @tail_pipe, all_fields, operation)
    end

    def assert(*args)
      options = args.extract_options!
      assertion = args[0]
      assertion_level = options[:level] || Java::CascadingOperation::AssertionLevel::STRICT
      make_each(Java::CascadingPipe::Each, @tail_pipe, assertion_level, assertion)
    end

    def assert_group(*args)
      options = args.extract_options!
      assertion = args[0]
      assertion_level = options[:level] || Java::CascadingOperation::AssertionLevel::STRICT
      make_every(Java::CascadingPipe::Every, @tail_pipe, assertion_level, assertion)
    end

    # Builds a debugging pipe.
    #
    # Without arguments, it generate a simple debug pipe, that prints all tuple to the standard
    # output.
    #
    # The other named options are:
    # * <tt>:print_fields</tt> a boolean. If is set to true, then it prints every 10 tuples.
    #
    def debug(*args)
      options = args.extract_options!
      print_fields = options[:print_fields] || true
      parameters = [print_fields].compact
      debug = Java::CascadingOperation::Debug.new(*parameters)
      debug.print_tuple_every = options[:tuple_interval] || 1
      debug.print_fields_every = options[:fields_interval] || 10
      each(all_fields, :filter => debug)
    end

    # Builds a pipe that assert the size of the tuple is the size specified in parameter.
    #
    # The method accept an unique uname argument : a number indicating the size expected.
    def assert_size_equals(*args)
      options = args.extract_options!
      assertion = Java::CascadingOperationAssertion::AssertSizeEquals.new(args[0])
      assert(assertion, options)
    end

    # Builds a pipe that assert the none of the fields in the tuple are null.
    def assert_not_null(*args)
      options = args.extract_options!
      assertion = Java::CascadingOperationAssertion::AssertNotNull.new
      assert(assertion, options)
    end

    def assert_group_size_equals(*args)
      options = args.extract_options!
      assertion = Java::CascadingOperationAssertion::AssertGroupSizeEquals.new(args[0])
      assert_group(assertion, options)
    end

    # Builds a series of every pipes for aggregation.
    #
    # Args can either be a list of fields to aggregate and an options hash or
    # a hash that maps input field name to output field name (similar to
    # insert) and an options hash.
    #
    # Options include:
    #   * <tt>:sql</tt> a boolean indicating whether the operation should act like the SQL equivalent
    #
    # <tt>function</tt> is a symbol that is the method to call to construct the Cascading Aggregator.
    def composite_aggregator(args, function)
      if !args.empty? && args.first.kind_of?(Hash)
        field_map = args.shift.sort
        options = args.extract_options!
      else
        options = args.extract_options!
        field_map = args.zip(args)
      end
      field_map.each do |in_field, out_field|
        agg = self.send(function, out_field, options)
        every(in_field, :aggregator => agg, :output => all_fields)
      end
      puts "WARNING: composite aggregator '#{function.to_s.gsub('_function', '')}' invoked on 0 fields; will be ignored" if field_map.empty?
    end

    def min(*args); composite_aggregator(args, :min_function); end
    def max(*args); composite_aggregator(args, :max_function); end
    def first(*args); composite_aggregator(args, :first_function); end
    def last(*args); composite_aggregator(args, :last_function); end
    def average(*args); composite_aggregator(args, :average_function); end

    # Counts elements of a group.  First unnamed parameter is the name of the
    # output count field (defaults to 'count' if it is not provided).
    def count(*args)
      options = args.extract_options!
      name = args[0] || 'count'
      every(last_grouping_fields, :aggregator => count_function(name, options), :output => all_fields)
    end

    # Fields to be summed may either be provided as an array, in which case
    # they will be aggregated into the same field in the given order, or as a
    # hash, in which case they will be aggregated from the field named by the
    # key into the field named by the value after being sorted.
    def sum(*args)
      options = args.extract_options!
      type = JAVA_TYPE_MAP[options[:type]]
      raise "No type specified for sum" unless type

      mapping = options[:mapping] ? options[:mapping].sort : args.zip(args)
      mapping.each do |in_field, out_field|
        every(in_field, :aggregator => sum_function(out_field, :type => type), :output => all_fields)
      end
    end

    # Builds a _parse_ pipe. This pipe will parse the fields specified in input (first unamed arguments),
    # using a specified regex pattern.
    #
    # If provided, the unamed arguments must be the fields to be parsed. If not provided, then all incoming
    # fields are used.
    #
    # The named options are:
    # * <tt>:pattern</tt> a string or regex. Specifies the regular expression used for parsing the argument fields.
    # * <tt>:output</tt> a string or array of strings. Specifies the outgoing fields (all fields will be output by default)
    def parse(*args)
        options = args.extract_options!
        fields = args || all_fields
        pattern = options[:pattern]
        output = options[:output] || all_fields
        each(fields, :filter => regex_parser(pattern, options), :output => output)
    end

    # Builds a pipe that splits a field into other fields, using a specified regular expression.
    #
    # The first unnamed argument is the field to be split.
    # The second unnamed argument is an array of strings indicating the fields receiving the result of the split.
    #
    # The named options are:
    # * <tt>:pattern</tt> a string or regex. Specifies the regular expression used for splitting the argument fields.
    # * <tt>:output</tt> a string or array of strings. Specifies the outgoing fields (all fields will be output by default)
    def split(*args)
      options = args.extract_options!
      fields = options[:into] || args[1]
      pattern = options[:pattern] || /[.,]*\s+/
      output = options[:output] || all_fields
      each(args[0], :function => regex_splitter(fields, :pattern => pattern), :output=>output)
    end

    # Builds a pipe that splits a field into new rows, using a specified regular expression.
    #
    # The first unnamed argument is the field to be split.
    # The second unnamed argument is the field receiving the result of the split.
    #
    # The named options are:
    # * <tt>:pattern</tt> a string or regex. Specifies the regular expression used for splitting the argument fields.
    # * <tt>:output</tt> a string or array of strings. Specifies the outgoing fields (all fields will be output by default)
    def split_rows(*args)
      options = args.extract_options!
      fields = options[:into] || args[1]
      pattern = options[:pattern] || /[.,]*\s+/
      output = options[:output] || all_fields
      each(args[0], :function => regex_split_generator(fields, :pattern => pattern), :output=>output)
    end

    # Builds a pipe that emits a new row for each regex group matched in a field, using a specified regular expression.
    #
    # The first unnamed argument is the field to be matched against.
    # The second unnamed argument is the field receiving the result of the match.
    #
    # The named options are:
    # * <tt>:pattern</tt> a string or regex. Specifies the regular expression used for matching the argument fields.
    # * <tt>:output</tt> a string or array of strings. Specifies the outgoing fields (all fields will be output by default)
    def match_rows(*args)
      options = args.extract_options!
      fields = options[:into] || args[1]
      pattern = options[:pattern] || /[\w]+/
      output = options[:output] || all_fields
      each(args[0], :function => regex_generator(fields, :pattern => pattern), :output=>output)
    end

    # Builds a pipe that parses the specified field as a date using hte provided format string.
    # The unamed argument specifies the field to format.
    #
    # The named options are:
    # * <tt>:into</tt> a string. It specifies the receiving field. By default, it will be named after
    # the input argument.
    # * <tt>:pattern</tt> a string. Specifies the date format.
    # * <tt>:output</tt> a string or array of strings. Specifies the outgoing fields (all fields will be output by default)
    def parse_date(*args)
      options = args.extract_options!
      field = options[:into] || "#{args[0]}_parsed"
      output = options[:output] || all_fields
      pattern = options[:pattern] || "yyyy/MM/dd"

      each args[0], :function => date_parser(field, pattern), :output => output
    end

    # Builds a pipe that format a date using a specified format pattern.
    #
    # The unamed argument specifies the field to format.
    #
    # The named options are:
    # * <tt>:into</tt> a string. It specifies the receiving field. By default, it will be named after
    # the input argument.
    # * <tt>:pattern</tt> a string. Specifies the date format.
    # * <tt>:timezone</tt> a string.  Specifies the timezone (defaults to UTC).
    # * <tt>:output</tt> a string or array of strings. Specifies the outgoing fields (all fields will be output by default)
    def format_date(*args)
      options = args.extract_options!
      field = options[:into] || "#{args[0]}_formatted"
      pattern = options[:pattern] || "yyyy/MM/dd"
      output = options[:output] || all_fields

      each args[0], :function => date_formatter(field, pattern, options[:timezone]), :output => output
    end

    # Builds a pipe that perform a query/replace based on a regular expression.
    #
    # The first unamed argument specifies the input field.
    #
    # The named options are:
    # * <tt>:pattern</tt> a string or regex. Specifies the pattern to look for in the input field. This non-optional argument
    # can also be specified as a second _unamed_ argument.
    # * <tt>:replacement</tt> a string. Specifies the replacement.
    # * <tt>:output</tt> a string or array of strings. Specifies the outgoing fields (all fields will be output by default)
    def replace(*args)
      options = args.extract_options!

      pattern = options[:pattern] || args[1]
      replacement = options[:replacement] || args[2]
      into = options[:into] || "#{args[0]}_replaced"
      output = options[:output] || all_fields

      each args[0], :function => regex_replace(into, pattern, replacement), :output => output
    end

    # Builds a pipe that inserts values into the current tuple.
    #
    # The method takes a hash as parameter. This hash contains as keys the names of the fields to insert
    # and as values, the values they must contain. For example:
    #
    #       insert {"who" => "Grégoire", "when" => Time.now.strftime("%Y-%m-%d") }
    #
    # will insert two new fields: a field _who_ containing the string "Grégoire", and a field _when_ containing
    # the formatted current date.
    # The methods outputs all fields.
    # The named options are:
    def insert(args)
      args.keys.sort.each do |field_name|
        value = args[field_name]

        if value.kind_of?(ExprStub)
          each all_fields,
            :function => expression_function(field_name, :expression => value.expression,
                           :parameters => value.types), :output => all_fields
        else
          each all_fields, :function => insert_function([field_name], :values => [value]), :output => all_fields
        end
      end
    end

    # Builds a pipe that filters the tuples based on an expression or a pattern (but not both !).
    #
    # The first unamed argument, if provided, is a filtering expression (using the Janino syntax).
    #
    # The named options are:
    # * <tt>:pattern</tt> a string. Specifies a regular expression pattern used to filter the tuples. If this
    # option is provided, then the filter is regular expression-based. This is incompatible with the _expression_ option.
    # * <tt>:expression</tt> a string. Specifies a Janino expression used to filter the tuples. This option has the
    # same effect than providing it as first unamed argument. If this option is provided, then the filter is Janino
    # expression-based. This is incompatible with the _pattern_ option.
    def filter(*args)
      options = args.extract_options!
      from = options.delete(:from) || all_fields
      expression = options.delete(:expression) || args.shift
      regex = options.delete(:pattern)
      if expression
        stub = ExprStub.new(expression)
        types, expression = stub.types, stub.expression

        each from, :filter => expression_filter(
          :parameters => types,
          :expression => expression
        )
      elsif regex
        each from, :filter => regex_filter(regex, options)
      end
    end

    def filter_null(*args)
      options = args.extract_options!
      each(args, :filter => Java::CascadingOperationFilter::FilterNull.new)
    end
    alias reject_null filter_null

    def filter_not_null(*args)
      options = args.extract_options!
      each(args, :filter => Java::CascadingOperationFilter::FilterNotNull.new)
    end
    alias where_null filter_not_null

    # Builds a pipe that rejects the tuples based on an expression.
    #
    # The first unamed argument, if provided, is a filtering expression (using the Janino syntax).
    #
    # The named options are:
    # * <tt>:expression</tt> a string. Specifies a Janino expression used to filter the tuples. This option has the
    # same effect than providing it as first unamed argument. If this option is provided, then the filter is Janino
    # expression-based.
    def reject(*args)
      options = args.extract_options
      raise "Regex not allowed" if options && options[:pattern]

      filter(*args)
    end

    # Builds a pipe that includes just the tuples matching an expression.
    #
    # The first unamed argument, if provided, is a filtering expression (using the Janino syntax).
    #
    # The named options are:
    # * <tt>:expression</tt> a string. Specifies a Janino expression used to select the tuples. This option has the
    # same effect than providing it as first unamed argument. If this option is provided, then the filter is Janino
    # expression-based.
    def where(*args)
      options = args.extract_options
      raise "Regex not allowed" if options && options[:pattern]

      if options[:expression]
        options[:expression] = "!(#{options[:expression]})"
      elsif args[0]
        args[0] = "!(#{args[0]})"
      end

      filter(*args)
    end

    # Builds a pipe that evaluates the specified Janino expression and insert it in a new field in the tuple.
    #
    # The named options are:
    # * <tt>:from</tt> a string or array of strings. Specifies the input fields.
    # * <tt>:express</tt> a string. The janino expression.
    # * <tt>:into</tt> a string. Specified the name of the field to insert with the result of the evaluation.
    # * <tt>:parameters</tt> a hash. Specifies the type mapping for the parameters. See Cascading::Operations.expression_function.
    def eval_expression(*args)
      options = args.extract_options!

      into = options.delete(:into)
      from = options.delete(:from) || all_fields
      output = options.delete(:output) || all_fields
      options[:expression] ||= args.shift
      options[:parameters] ||= args.shift

      each from, :function => expression_function(into, options), :output=>output
    end

    # Builds a pipe that returns distinct tuples based on the provided fields.
    #
    # The method accepts optional unamed argument specifying the fields to base the distinct on
    # (all fields, by default).
    def distinct(*args)
      raise "Distinct is badly broken"
      fields = args[0] || all_fields
      group_by *fields
      pass
    end

    # Builds a pipe that will unify (merge) pipes. The method accepts the list of pipes as argument.
    # Tuples unified must share the same fields.
    def union(*args)
      options = args.extract_options!
      pipes = args
      union_pipes pipes
    end

    def join_fields(*args)
      options = args.extract_options!
      output = options[:output] || all_fields

      each args, :function => field_joiner(options), :output => output
    end
  end
end
