require 'puppet'
require 'puppet/pops/model/tree_dumper'
# Dumps a Pops::Model in reverse polish notation; i.e. LISP style
# The intention is to use this for debugging output
# TODO: BAD NAME - A DUMP is a Ruby Serialization
#
module Retrospec
  module Puppet
    class RspecDumper < ::Puppet::Pops::Model::TreeDumper
      attr_reader :var_store

      def var_store
        @var_store ||= {}
      end

      def logger
        unless @logger
          require 'logger'
          @logger = Logger.new(STDOUT)
          if ENV['RETROSPEC_LOGGER_LEVEL'] == 'debug'
            @logger.level = Logger::DEBUG
          else
            @logger.level = Logger::INFO
          end
        end
        @logger
      end

      # wraps Puppet::Pops::Model::TreeDumper.do_dump to return ruby 1.9 hash syntax
      # instead of the older < 1.9 syntax
      #
      # == Parameters:
      # d::
      #   A puppet object to dump
      #
      # == Return:
      #   An array of representing the puppet object in ruby syntax
      #
      def dump_transform(d)
        # This is a bit messy, ideally need to send a patch upstream to puppet
        # https://github.com/puppetlabs/puppet/blob/master/lib/puppet/pops/visitor.rb#L34
        # The value we get back from puppet do_dump command dumps ruby hashs using the old
        # ruby syntax e.g. { "key" => "value" }.  this function munges the output to use
        # the new format e.g. { key: 'value' }
        dump = do_dump(d)
        if dump.kind_of?(Array) and dump[1] == :"=>"
          key = dump[0].tr('"','')
          value = dump[-1].tr('"','\'')
          [ "#{key}:", value ]
        else
          dump
        end
      end

      def lookup_var(key)
        # if exists, return value
        # if it doesn't exist, store and return key
        key = normalize_key(key)
        other_key = key.split('::').last
        if key != other_key
          other_key = "$#{other_key}"
        end
        logger.debug("looking up #{key}".yellow)
        if item = var_store[key]
          value = item[:value]
          logger.debug("Store hit: #{key} with value: #{value}")
        elsif item = var_store[other_key] # key does not exist
          logger.debug("looking up #{other_key}".yellow)
          logger.debug("Store hit: #{other_key} with value: #{value}")
          value = item[:value]
        else
          logger.debug("Store miss: #{key}".fatal)
          value = false
        end
        value
      end

      # prepends a dollar sign if doesn't already exist
      def normalize_key(key)
        unless key.start_with?('$')
          # prepend the dollar sign
          key = "$#{key}"
        end
        key
      end

      # adds a variable to the store, its value and type of scope
      def add_var_to_store(key, value, force=false, type=:scope)
        key = normalize_key(key)
        if var_store.has_key?(key) and !force
          logger.debug ("Prevented from writing #{key} with value #{value}".info)
        else
          logger.debug("storing #{key} with value #{value}".yellow)
          var_store[key]= {:value => value, :type => type}
          other_key = key.split('::').last
          if key != other_key
            other_key = "$#{other_key}"
            unless key.split('::').first == '$'
              add_var_to_store(other_key, value, false, type)
            end

          end
        end
        value
      end

      def dump_Array o
        o.collect {|e| dump_transform(e) }
      end

      def indent
        "  " * indent_count
      end

      def format(x)
        result = ""
        parts = format_r(x)
        parts.each_index do |i|
          if i > 0
            # separate with space unless previous ends with whitepsace or (
            result << ' ' if parts[i] != ")" && parts[i-1] !~ /.*(?:\s+|\()$/ && parts[i] !~ /^\s+/
          end
          result << parts[i].to_s
        end
        result
      end

      def format_r(x)
        result = []
        case x
        when :break
          result << "\n" + indent
        when :indent_break
          result << indent + "\n"
        when :indent
          @indent_count += 1
        when :dedent
          if @indent_count == 0
            logger.warn('tried dedent when indent_count is already 0')
          else
            @indent_count -= 1
          end
        when :do
          result << format_r([' ', x.to_s, :indent, :break])
        when :indent_end
          result << format_r([:indent, :break, 'end', :dedent])
        when :end
          result << format_r([:dedent, :break, x.to_s])
        when Array
          #result << '('
          result += x.collect {|a| format_r(a) }.flatten
          #result << ')'
        when Symbol
          result << x.to_s # Allows Symbols in arrays e.g. ["text", =>, "text"]
        else
          result << x
        end
        result
      end

      def dump_ResourceTypeDefinition o
        result = ["describe #{o.name.inspect}", :do]
        result << ['let(:title)', :do, 'XXreplace_meXX'.inspect, :break, :end]
        result << [:dedent, :break]
        result << [:indent, :break,'let(:params)', :do, '{', :break]
        result << o.parameters.collect {|k| dump_transform(k)}
        result << ['}', :end]
        # result << ["inherits", o.parent_class] if o.parent_class
        # we need to process the body so that we can relize which facts are used
        body_result = []
        if o.body
          body_result << [:break, dump_transform(o.body)]
        else
          body_result << []
        end
        result << [:break,:break,'let(:facts)', :do, '{',:break]
        result << dump_top_scope_vars
        result << ['}', :end]
        result << body_result
        result << [:end]
        result
      end

      def top_scope_vars
        var_store.find_all do |k,v|
          v[:type] == :top_scope
        end
      end

      #
      def dump_top_scope_vars
        result = []
        top_scope_vars.sort.each do |k, v|
          result << ['  ',k.gsub('$::', ''), ':' ,v[:value].inspect + ',', :break ]
        end
        result
      end

      def dump_HostClassDefinition o
        result = ["describe #{o.name.inspect}", :do]
        result << ['let(:params)', :do, '{', :break]
        result << o.parameters.collect {|k| dump_transform(k)}
        result << ['}', :end]
        # result << ["inherits", o.parent_class] if o.parent_class
        # we need to process the body so that we can relize which facts are used
        body_result = []
        if o.body
          body_result << [dump_transform(o.body)]
        else
          body_result << []
        end
        result << [:break,:break,'let(:facts)', :do, '{',:break]
        result << dump_top_scope_vars
        result << ['}',:end]
        result << body_result
        result << [:end]
        result
      end

      # Produces parameters as name, or (= name value)
      def dump_Parameter o
        name_prefix = o.captures_rest ? '*' : ''
        name_part = "#{name_prefix}#{o.name}"
        data_type = dump_transform(dump_transform(o.value)).first || dump_transform(o.type_expr)

        # records what is most likely a variable of some time and its value
        variable_value = dump_transform(o.value)
        # need a case for Puppet::Pops::Model::LambdaExpression
        if o.eContainer.class == ::Puppet::Pops::Model::LambdaExpression
          add_var_to_store("#{name_part}", variable_value, false, :lambda_scope)
        else
          parent_name = o.eContainer.name
          add_var_to_store("#{parent_name}::#{name_part}", variable_value, false, :parameter)
        end
        if o.value && o.type_expr
          value = {:type => data_type, :name => name_part, :required => false, :default_value => variable_value}
        elsif o.value
          value = {:type => data_type, :name => name_part, :default_value => variable_value, :required => false}
        elsif o.type_expr
          value = {:type => data_type, :name => name_part, :required => true,  :default_value => ''}
        else
          value = {:type => data_type, :name => name_part, :default_value => '', :required => true}
        end
        if value[:required]
          ['  ', "#{value[:name]}:", 'nil,', :break]
        else
          ['  ', "# #{value[:name]}:", value[:default_value].inspect + ',', :break]
        end
      end

      # this will determine and dump the resource requirement by
      # comparing itself against the resource relationship expression
      def dump_Resource_Relationship o
        result = []
        id = o.eContainer.object_id # the id of this container
        relationship = o.eContainer.eContainer.eContainer.eContents.first
        if relationship.respond_to?(:left_expr)
          if relationship.left_expr.object_id == id
            type_name = dump(relationship.right_expr.type_name).capitalize
            result += relationship.right_expr.bodies.map do |b|
              title = dump(b.title)
              [:break,".that_comes_before('#{type_name}[#{title}]')"]
            end.flatten
          else
            if relationship.left_expr.respond_to?(:type_name)
              type_name = dump(relationship.left_expr.type_name).capitalize
              result += relationship.left_expr.bodies.map do |b|
                title = dump(b.title)
                [:break, ".that_requires('#{type_name}[#{title}]')"]
              end.flatten
            end
          end
        end
        result
      end


      # @note this is the starting point where a test is created.  A resource can include a class or define
      # each resource contains parameters which can have variables or functions as values.
      # @param o [Puppet::Pops::Model::ResourceBody]
      def dump_ResourceBody o
        type_name = dump_transform(o.eContainer.type_name).gsub('::', '__')
        title = dump_transform(o.title).inspect
        #TODO remove the :: from the front of the title if exists
        result = ['  ', :indent, :it, :do, :indent, "is_expected.to contain_#{type_name}(#{title})".tr('"','\'')]
        # this determies if we should use the with() or not
        if o.operations.count > 0
          result[-1] += '.with('
          result << [:break]
          # each operation should be a resource parameter and value
          o.operations.each do |p|
            next unless p
            # this is a bit of a hack but the correct fix is to patch puppet
            result << dump_transform(p) << :break
          end
          result.pop  # remove last line break which is easier than using conditional in loop
          result << [:dedent, :break, ')']
          unless [::Puppet::Pops::Model::CallNamedFunctionExpression, ::Puppet::Pops::Model::BlockExpression].include?(o.eContainer.eContainer.class)
            result << dump_Resource_Relationship(o)
          end
          result << [:end]
          result << [:dedent]
          result << [:break]
        else
          result << [:dedent,:dedent, :break,'end',:dedent, '  ', :break]
        end
        result
      end

      def method_missing(name, *args, &block)
        logger.debug("Method #{name} called".warning)
        []
      end

      # @param o [Puppet::Pops::Model::NamedAccessExpression]
      # ie. $::var1.split(';')
      def dump_NamedAccessExpression o
        [do_dump(o.left_expr), ".", do_dump(o.right_expr)]
      end

      # Interpolated strings are shown as (cat seg0 seg1 ... segN)
      def dump_ConcatenatedString o
        o.segments.collect {|x| dump_transform(x)}.join
      end

      # Interpolation (to string) shown as (str expr)
      def dump_TextExpression o
        [dump_transform(o.expr)]
      end

      # outputs the value of the variable
      # @param VariableExpression
      # @return String the value of the variable or the name if value is not found
      def dump_VariableExpression o
        key = dump(o.expr)
        if value = lookup_var(key)
          value  # return the looked up value
        elsif [::Puppet::Pops::Model::AttributeOperation,
           ::Puppet::Pops::Model::AssignmentExpression].include?(o.eContainer.class)
          "$#{key}"
        else
          add_var_to_store(key, "$#{key}", false, :class_scope)
        end
      end

      # this doesn't return anything as we use it to store variables
      # @param o [Puppet::Pops::Model::AssignmentExpression]
      def dump_AssignmentExpression o
        oper = o.operator.to_s
        result = []
        case oper
        when '='
          # we don't know the output type of a function call, so just assign nill
          # no need to add it to the var_store since its always the same
          # without this separation, values will get stored
          if o.right_expr.class == ::Puppet::Pops::Model::CallNamedFunctionExpression
            value = nil
          else
            value = dump(o.right_expr)
            key = dump(o.left_expr)
            # we dont want empty variables storing empty values
            unless key == value
              add_var_to_store(key, value, true)
            end
          end
          result
        else
          [o.operator.to_s, dump_transform(o.left_expr), dump_transform(o.right_expr)]
        end
      end

      # @param o [Puppet::Pops::Model::BlockExpression]
      def dump_BlockExpression o
        result = [:break]
        o.statements.each {|x| result << dump_transform(x) }
        result
      end

      # this is the beginning of the resource not the body itself
      # @param o [Puppet::Pops::Model::ResourceExpression]
      def dump_ResourceExpression o
        result = []
        o.bodies.each do |b|
          result << :break << dump_transform(b)
        end
        result
      end

      # defines the resource expression and outputs -> when used
      # this would be the place to insert relationsip matchers
      # @param o [Puppet::Pops::Model::RelationshipExpression]
      def dump_RelationshipExpression o
        [dump_transform(o.left_expr), dump_transform(o.right_expr)]
      end

      # Produces (name => expr) or (name +> expr)
      # @param o [Puppet::Pops::Model::AttributeOperation]
      def dump_AttributeOperation o
        key = o.attribute_name
        value = dump_transform(o.value_expr) || nil
        [key.inspect, o.operator, value.inspect + ',']
      end

      # x[y] prints as (slice x y)
      # @return [String] the value of the array expression
      # @param o [Puppet::Pops::Model::AccessExpression]
      def dump_AccessExpression o
        # o.keys.pop is the item to get in the array
        # o.left_expr is the array
        if o.left_expr.is_a?(::Puppet::Pops::Model::QualifiedReference)
          "#{dump_transform(o.left_expr).capitalize}" + dump_transform(o.keys).to_s.gsub("\"",'')
        else
          begin
            arr = dump_transform(o.left_expr)
            element_number = dump_transform(o.keys[0]).to_i
            arr.at(element_number)
          rescue NoMethodError => e
            puts "Invalid access of array element, check array variables in your puppet code?".fatal
          end
        end
      end


      # @return [String] the value of the expression or example value
      # @param o [Puppet::Pops::Model::CallMethodExpression]
      def dump_CallMethodExpression o
        # ie. ["call-method", [".", "$::facttest", "split"], "/"]
        result = [o.rval_required ? "# some_value" : do_dump(o.functor_expr),'(' ]
        o.arguments.collect {|a| result << do_dump(a) }
        results << ')'
        result << do_dump(o.lambda) if o.lambda
        result
      end

      def dump_LiteralFloat o
        o.value.to_s
      end

      def dump_LiteralInteger o
        case o.radix
        when 10
          o.value.to_s
        when 8
          "0%o" % o.value
        when 16
          "0x%X" % o.value
        else
          "bad radix:" + o.value.to_s
        end
      end

      def dump_LiteralValue o
        o.value
      end

      def dump_LiteralList o
        o.values.collect {|x| dump_transform(x)}
      end

      def dump_LiteralHash o
        data = o.entries.collect {|x| dump_transform(x)}
        Hash[*data.flatten]
      end

      def dump_LiteralString o
        "#{o.value}"
      end

      def dump_LiteralDefault o
        ":default"
      end

      def dump_LiteralUndef o
        :undef
      end

      def dump_LiteralRegularExpression o
        "/#{o.value.source}/"
      end

      def dump_Nop o
        ":nop"
      end

      def dump_NilClass o
        :undef
      end

      def dump_NotExpression o
        ['!', dump(o.expr)]
      end

      def dump_CapabilityMapping o
        [o.kind, dump_transform(o.component), o.capability, dump_transform(o.mappings)]
      end

      def dump_ParenthesizedExpression o
        dump_transform(o.expr)
      end

      # Hides that Program exists in the output (only its body is shown), the definitions are just
      # references to contained classes, resource types, and nodes
      def dump_Program(o)
        dump(o.body)
      end

      def dump_Object o
        []
      end

      def is_nop? o
        o.nil? || o.is_a?(::Puppet::Pops::Model::Nop)
      end

    end
  end
end
