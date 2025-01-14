class << ActiveRecord::Base
  def has_ancestry options = {}
    # Check options
    raise Ancestry::AncestryException.new("Options for has_ancestry must be in a hash.") unless options.is_a? Hash
    options.each do |key, value|
      unless [:ancestry_column, :orphan_strategy, :ancestry_scope, :cache_depth, :depth_cache_column, :touch].include? key
        raise Ancestry::AncestryException.new("Unknown option for has_ancestry: #{key.inspect} => #{value.inspect}.")
      end
    end

    # Include instance methods
    include Ancestry::InstanceMethods

    # Include dynamic class methods
    extend Ancestry::ClassMethods

    # Create ancestry column accessor and set to option or default
    cattr_accessor :ancestry_column
    self.ancestry_column = options[:ancestry_column] || :ancestry

    # Create orphan strategy accessor and set to option or default (writer comes from DynamicClassMethods)
    cattr_reader :orphan_strategy
    self.orphan_strategy = options[:orphan_strategy] || :destroy

    # Save self as base class (for STI)
    cattr_accessor :ancestry_base_class
    self.ancestry_base_class = self

    # Create scope accessor and set to option
    cattr_accessor :ancestry_scope_column, :ancestry_scope_association
    if options[:ancestry_scope]
      if options[:ancestry_scope].is_a?(Symbol) && options[:ancestry_scope].to_s !~ /_id$/
        self.ancestry_scope_association = options[:ancestry_scope].to_s
        self.ancestry_scope_column = "#{options[:ancestry_scope]}_id".intern
      else
        self.ancestry_scope_column = options[:ancestry_scope]
        self.ancestry_scope_association = "#{options[:ancestry_scope].to_s.gsub(/_id$/, '')}"
      end
    end


    # Touch ancestors after updating
    cattr_accessor :touch_ancestors
    self.touch_ancestors = options[:touch] || false

    # Validate format of ancestry column value
    validates_format_of ancestry_column, :with => Ancestry::ANCESTRY_PATTERN, :allow_nil => true

    # Validate that the ancestor ids don't include own id
    validate :ancestry_exclude_self

    # Named scopes
    if options[:ancestry_scope]
      scope :root_scope, lambda { |object| where(to_node(object).scope_conditions) }
    else
      scope :root_scope, lambda { where(nil) }
    end
    scope :roots, lambda { where(ancestry_column => nil) }
    scope :roots_of, lambda { |object| root_scope(object).where(ancestry_column => nil) }
    scope :ancestors_of, lambda { |object| root_scope(object).where(to_node(object).ancestor_conditions) }
    scope :children_of, lambda { |object| root_scope(object).where(to_node(object).child_conditions) }
    scope :descendants_of, lambda { |object| root_scope(object).where(to_node(object).descendant_conditions) }
    scope :subtree_of, lambda { |object| root_scope(object).where(to_node(object).subtree_conditions) }
    scope :siblings_of, lambda { |object| root_scope(object).where(to_node(object).sibling_conditions) }
    scope :ordered_by_ancestry, lambda {
      if %w(mysql mysql2 sqlite postgresql).include?(connection.adapter_name.downcase) && ActiveRecord::VERSION::MAJOR >= 5
        reorder(Arel.sql("coalesce(#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(ancestry_column)}, '')"))
      else
        reorder("(CASE WHEN #{connection.quote_table_name(table_name)}.#{connection.quote_column_name(ancestry_column)} IS NULL THEN 0 ELSE 1 END), #{connection.quote_table_name(table_name)}.#{connection.quote_column_name(ancestry_column)}")
      end
    }
    scope :ordered_by_ancestry_and, lambda { |order|
      if %w(mysql mysql2 sqlite postgresql).include?(connection.adapter_name.downcase) && ActiveRecord::VERSION::MAJOR >= 5
        reorder(Arel.sql("coalesce(#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(ancestry_column)}, ''), #{order}"))
      else
        reorder("(CASE WHEN #{connection.quote_table_name(table_name)}.#{connection.quote_column_name(ancestry_column)} IS NULL THEN 0 ELSE 1 END), #{connection.quote_table_name(table_name)}.#{connection.quote_column_name(ancestry_column)}, #{order}")
      end
    }
    scope :path_of, lambda { |object| to_node(object).path }

    # Set scope association unless already set
    before_save :set_scope_association

    # Update descendants with new ancestry before save
    before_save :update_descendants_with_new_ancestry

    # Apply orphan strategy before destroy
    before_destroy :apply_orphan_strategy

    # Create ancestry column accessor and set to option or default
    if options[:cache_depth]
      # Create accessor for column name and set to option or default
      self.cattr_accessor :depth_cache_column
      self.depth_cache_column = options[:depth_cache_column] || :ancestry_depth

      # Cache depth in depth cache column before save
      before_validation :cache_depth
      before_save :cache_depth

      # Validate depth column
      validates_numericality_of depth_cache_column, :greater_than_or_equal_to => 0, :only_integer => true, :allow_nil => false
    end

    # Create named scopes for depth
    {:before_depth => '<', :to_depth => '<=', :at_depth => '=', :from_depth => '>=', :after_depth => '>'}.each do |scope_name, operator|
      scope scope_name, lambda { |depth|
        raise Ancestry::AncestryException.new("Named scope '#{scope_name}' is only available when depth caching is enabled.") unless options[:cache_depth]
        where("#{depth_cache_column} #{operator} ?", depth)
      }
    end

    after_touch :touch_ancestors_callback
    after_destroy :touch_ancestors_callback
    after_save :touch_ancestors_callback, if: :saved_changes?
  end
end

ActiveSupport.on_load :active_record do
  if not(ActiveRecord::Base.respond_to?(:acts_as_tree))
    class << ActiveRecord::Base
      alias_method :acts_as_tree, :has_ancestry
    end
  end
end
