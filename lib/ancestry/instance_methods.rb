module Ancestry
  module InstanceMethods
    # Validate that the ancestors don't include itself
    def ancestry_exclude_self
      errors.add(:base, "#{self.class.name.humanize} cannot be a descendant of itself.") if ancestor_ids.include? self.id
    end

    # Set scope_association unless already set
    def set_scope_association
      unless ancestry_callbacks_disabled?
        if ancestry_scope_association && eval("self.#{ancestry_scope_association}").blank? && parent
          eval("self.#{ancestry_scope_association} = parent.#{ancestry_scope_association}")
        end
      end
    end

    # Update descendants with new ancestry
    def update_descendants_with_new_ancestry
      # Skip this if callbacks are disabled
      unless ancestry_callbacks_disabled?
        # If node is not a new record and ancestry was updated and the new ancestry is sane ...
        if ancestry_changed? && !new_record? && sane_ancestry?
          # ... for each descendant ...
          unscoped_descendants.each do |descendant|
            # ... replace old ancestry with new ancestry
            descendant.without_ancestry_callbacks do
              descendant.update_attribute(
                self.ancestry_base_class.ancestry_column,
                descendant.read_attribute(descendant.class.ancestry_column).gsub(
                  /^#{self.child_ancestry}/,
                  if read_attribute(self.class.ancestry_column).blank? then id.to_s else "#{read_attribute self.class.ancestry_column }/#{id}" end
                )
              )
            end
          end
        end
      end
    end

    # Apply orphan strategy
    def apply_orphan_strategy
      # Skip this if callbacks are disabled
      unless ancestry_callbacks_disabled?
        # If this isn't a new record ...
        unless new_record?
          # ... make all children root if orphan strategy is rootify
          if self.ancestry_base_class.orphan_strategy == :rootify
            unscoped_descendants.each do |descendant|
              descendant.without_ancestry_callbacks do
                descendant.update_attribute descendant.class.ancestry_column, (if descendant.ancestry == child_ancestry then nil else descendant.ancestry.gsub(/^#{child_ancestry}\//, '') end)
              end
            end
          # ... destroy all descendants if orphan strategy is destroy
          elsif self.ancestry_base_class.orphan_strategy == :destroy
            unscoped_descendants.each do |descendant|
              descendant.without_ancestry_callbacks do
                descendant.destroy
              end
            end
          # ... make child elements of this node, child of its parent if orphan strategy is adopt
          elsif self.ancestry_base_class.orphan_strategy == :adopt
            descendants.each do |descendant|
              descendant.without_ancestry_callbacks do
                new_ancestry = descendant.ancestor_ids.delete_if { |x| x == self.id }.join("/")
                # check for empty string if it's then set to nil
                new_ancestry = nil if new_ancestry.empty?
                descendant.update_attribute descendant.class.ancestry_column, new_ancestry || nil
              end
            end
          # ... throw an exception if it has children and orphan strategy is restrict
          elsif self.ancestry_base_class.orphan_strategy == :restrict
            raise Ancestry::AncestryException.new('Cannot delete record because it has descendants.') unless is_childless?
          end
        end
      end
    end

    # Touch each of this record's ancestors
    def touch_ancestors_callback

      # Skip this if callbacks are disabled
      unless ancestry_callbacks_disabled?

        # Only touch if the option is enabled
        if self.ancestry_base_class.touch_ancestors

          # Touch each of the old *and* new ancestors
          self.class.where(id: (ancestor_ids + ancestor_ids_was).uniq).each do |ancestor|
            ancestor.without_ancestry_callbacks do
              ancestor.touch
            end
          end
        end
      end
    end

    # The ancestry value for this record's children
    def child_ancestry
      # New records cannot have children
      raise Ancestry::AncestryException.new('No child ancestry for new record. Save record before performing tree operations.') if new_record?

      if self.send("#{self.ancestry_base_class.ancestry_column}_before_last_save").blank? then id.to_s else "#{self.send "#{self.ancestry_base_class.ancestry_column}_before_last_save"}/#{id}" end
    end

    # Ancestors

    def ancestry_changed?
      saved_changes.keys.include?(self.ancestry_base_class.ancestry_column.to_s)
    end

    def parse_ancestry_column obj
      obj.to_s.split('/').map { |id| cast_primary_key(id) }
    end

    def ancestor_ids
      parse_ancestry_column(read_attribute(self.ancestry_base_class.ancestry_column))
    end

    def ancestor_conditions
      t = get_arel_table
      t[get_primary_key_column].in(ancestor_ids)
    end

    def ancestors depth_options = {}
      self.ancestry_base_class.scope_depth(depth_options, depth).ordered_by_ancestry.where ancestor_conditions
    end

    def ancestor_was_conditions
      {primary_key_with_table => ancestor_ids_was}
    end

    def ancestor_ids_was
      parse_ancestry_column(saved_changes[self.ancestry_base_class.ancestry_column.to_s]&.first)
    end

    def path_ids
      ancestor_ids + [id]
    end

    def path_string(delimiter = '/')
      path_ids.join(delimiter)
    end

    def path_conditions
      t = get_arel_table
      t[get_primary_key_column].in(path_ids)
    end

    def path depth_options = {}
      self.ancestry_base_class.scope_depth(depth_options, depth).ordered_by_ancestry.where path_conditions
    end

    def depth
      ancestor_ids.size
    end

    def cache_depth
      write_attribute self.ancestry_base_class.depth_cache_column, depth
    end

    def ancestor_of?(node)
      node.ancestor_ids.include?(self.id)
    end

    # Parent

    def parent= parent
      write_attribute(self.ancestry_base_class.ancestry_column, if parent.nil? then nil else parent.child_ancestry end)
    end

    def parent_id= parent_id
      self.parent = if parent_id.blank? then nil else unscoped_find(parent_id) end
    end

    def parent_id
      if ancestor_ids.empty? then nil else ancestor_ids.last end
    end

    def parent
      if parent_id.blank? then nil else unscoped_find(parent_id) end
    end

    def parent_id?
      parent_id.present?
    end
    # Scope
    def scope_conditions
      return true unless self.ancestry_scope_column
      t = get_arel_table
      t[get_scope_column].eq(eval("self.#{ancestry_scope_column}"))
    end

    def parent_of?(node)
      self.id == node.parent_id
    end

    # Root

    def root_conditions
      t = get_arel_table
      t[get_ancestry_column].eq(nil)
    end

    def roots
      self.ancestry_base_class.where(scope_conditions).where(root_conditions)
    end

    def roots_and_descendants
      self.ancestry_base_class.where(scope_conditions)
    end

    def root_id
      if ancestor_ids.empty? then id else ancestor_ids.first end
    end

    def root
      if root_id == id then self else unscoped_find(root_id) end
    end

    def is_root?
      read_attribute(self.ancestry_base_class.ancestry_column).blank?
    end
    alias :root? :is_root?

    def root_of?(node)
      self.id == node.root_id
    end

    # Children

    def child_conditions
      t = get_arel_table
      t[get_ancestry_column].eq(child_ancestry)
    end

    def children
      self.ancestry_base_class.where child_conditions
    end

    def child_ids
      children.pluck(self.ancestry_base_class.primary_key)
    end

    def has_children?
      self.children.exists?({})
    end
    alias_method :children?, :has_children?

    def is_childless?
      !has_children?
    end
    alias_method :childless?, :is_childless?

    def child_of?(node)
      self.parent_id == node.id
    end

    # Siblings

    def sibling_conditions
      t = get_arel_table
      t[get_ancestry_column].eq(read_attribute(self.ancestry_base_class.ancestry_column))
    end

    def siblings
      self.ancestry_base_class.where(scope_conditions).where(sibling_conditions)
    end

    def sibling_ids
      siblings.pluck(self.ancestry_base_class.primary_key)
    end

    def has_siblings?
      self.siblings.count > 1
    end
    alias_method :siblings?, :has_siblings?

    def is_only_child?
      !has_siblings?
    end
    alias_method :only_child?, :is_only_child?

    def siblings_and_descendants_conditions
      t = get_arel_table
      t[get_ancestry_column].eq(read_attribute(self.ancestry_base_class.ancestry_column)).or(t[get_ancestry_column].matches("#{read_attribute(self.ancestry_base_class.ancestry_column)}/%"))
    end

    def siblings_and_descendants
      if is_root?
        self.ancestry_base_class.where(scope_conditions)
      else
        self.ancestry_base_class.where(scope_conditions).where(siblings_and_descendants_conditions)
      end
    end

    def sibling_of?(node)
      self.ancestry == node.ancestry
    end

    # Descendants

    def descendant_conditions
      t = get_arel_table
      # rails has case sensitive matching.
      if ActiveRecord::VERSION::MAJOR >= 5
        t[get_ancestry_column].matches("#{child_ancestry}/%", nil, true).or(t[get_ancestry_column].eq(child_ancestry))
      else
        t[get_ancestry_column].matches("#{child_ancestry}/%").or(t[get_ancestry_column].eq(child_ancestry))
      end
    end

    def descendants depth_options = {}
      self.ancestry_base_class.ordered_by_ancestry.scope_depth(depth_options, depth).where descendant_conditions
    end

    def descendant_ids depth_options = {}
      descendants(depth_options).pluck(self.ancestry_base_class.primary_key)
    end

    def descendant_of?(node)
      ancestor_ids.include?(node.id)
    end

    # Subtree

    def subtree_conditions
      t = get_arel_table
      descendant_conditions.or(t[get_primary_key_column].eq(self.id))
    end

    def subtree depth_options = {}
      self.ancestry_base_class.ordered_by_ancestry.scope_depth(depth_options, depth).where subtree_conditions
    end

    def subtree_ids depth_options = {}
      subtree(depth_options).pluck(self.ancestry_base_class.primary_key)
    end

    # Callback disabling

    def without_ancestry_callbacks
      @disable_ancestry_callbacks = true
      yield
      @disable_ancestry_callbacks = false
    end

    def ancestry_callbacks_disabled?
      defined?(@disable_ancestry_callbacks) && @disable_ancestry_callbacks
    end

  private

    def cast_primary_key(key)
      if [:string, :uuid, :text].include? primary_key_type
        key
      else
        key.to_i
      end
    end

    def primary_key_type
      @primary_key_type ||= column_for_attribute(self.class.primary_key).type
    end

    def unscoped_descendants
      self.ancestry_base_class.unscoped do
        self.ancestry_base_class.where descendant_conditions
      end
    end

    # Validates the ancestry, but can also be applied if validation is bypassed to determine if children should be affected
    def sane_ancestry?
      ancestry_value = read_attribute(self.ancestry_base_class.ancestry_column)
      ancestry_value.nil? || (ancestry_value.to_s =~ Ancestry::ANCESTRY_PATTERN && !ancestor_ids.include?(self.id))
    end

    def unscoped_find id
      self.ancestry_base_class.unscoped { self.ancestry_base_class.find(id) }
    end

    def get_arel_table
      self.ancestry_base_class.arel_table
    end

    def get_primary_key_column
      self.ancestry_base_class.primary_key.to_sym
    end

    def get_ancestry_column
      self.ancestry_base_class.ancestry_column.to_sym
    end

    def get_scope_column
      self.ancestry_base_class.ancestry_scope_column.to_sym
    end
  end
end
