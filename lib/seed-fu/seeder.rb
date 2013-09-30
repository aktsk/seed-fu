require 'active_support/core_ext/hash/keys'

module SeedFu
  # Creates or updates seed records with data.
  #
  # It is not recommended to use this class directly. Instead, use `Model.seed`, and `Model.seed_once`,
  # where `Model` is your Active Record model.
  #
  # @see ActiveRecordExtension
  class Seeder
    # @param [ActiveRecord::Base] model_class The model to be seeded
    # @param [Array<Symbol>] constraints A list of attributes which identify a particular seed. If
    #   a record with these attributes already exists then it will be updated rather than created.
    # @param [Array<Hash>] data Each item in this array is a hash containing attributes for a
    #   particular record.
    # @param [Hash] options
    # @option options [Boolean] :quiet (SeedFu.quiet) If true, output will be silenced
    # @option options [Boolean] :insert_only (false) If true then existing records which match the
    #   constraints will not be updated, even if the seed data has changed
    def initialize(model_class, constraints, data, options = {})
      @model_class = model_class
      @constraints = constraints.to_a.empty? ? [:id] : constraints
      @data        = data.to_a || []
      @options     = options.symbolize_keys

      @options[:quiet] ||= SeedFu.quiet
      @options[:without_protection] ||= true

      @columns = {}
      column_struct = Struct.new(:name, :null, :type)
      @model_class.columns.each do |column|
        @columns[column.name.to_sym] = column_struct.new(column.name.to_sym, column.null, column.type)
      end

      validate_constraints!
      validate_data!
    end

    # Insert/update the records as appropriate. Validation is skipped while saving.
    # @return [Array<ActiveRecord::Base>] The records which have been seeded
    def seed
      records = @model_class.transaction do
        @data.map { |record_data| seed_record(record_data.symbolize_keys) }
      end
      update_id_sequence
      records
    end

    private

      def validate_constraints!
        unknown_columns = @constraints.map(&:to_s) - @model_class.column_names
        unless unknown_columns.empty?
          raise(ArgumentError,
            "Your seed constraints contained unknown columns: #{column_list(unknown_columns)}. " +
            "Valid columns are: #{column_list(@model_class.column_names)}.")
        end
      end

      def validate_data!
        raise ArgumentError, "Seed data missing" if @data.empty?
      end

      def column_list(columns)
        '`' + columns.join("`, `") + '`'
      end

      def seed_record(data)
        record = find_or_initialize_record(data)
        return if @options[:insert_only] && !record.new_record?

        new_data = {}
        data.each_pair do |k, v|
          column = @columns[k]
          next unless column
          next if [:created_at, :updated_at].include? column.name
          if !v.nil? && column.null && v.size == 0
            v = nil
          end
          new_data[k] = v
        end

        puts " - #{@model_class} #{new_data.inspect}" unless @options[:quiet]

        if @options[:without_protection]
          begin
            record.assign_attributes(new_data)
          rescue ActiveRecord::UnknownAttributeError => e
            puts e
          end
        else
          record.assign_attributes(new_data)
        end
        unless record.save
          record.errors.each { |attr, msg| puts "#{attr} - #{msg}" }
          raise(ActiveRecord::RecordNotSaved)
        end
        record
      end

      def find_or_initialize_record(data)
        @model_class.unscoped.where(constraint_conditions(data)).first ||
        @model_class.new
      end

      def constraint_conditions(data)
        Hash[@constraints.map { |c| [c, data[c.to_sym]] }]
      end

      def update_id_sequence
        if @model_class.connection.adapter_name == "PostgreSQL"
          quoted_id       = @model_class.connection.quote_column_name(@model_class.primary_key)
          quoted_sequence = "'" + @model_class.sequence_name + "'"
          @model_class.connection.execute(
            "SELECT pg_catalog.setval(" +
              "#{quoted_sequence}," +
              "(SELECT MAX(#{quoted_id}) FROM #{@model_class.quoted_table_name}) + 1" +
            ");"
          )
        end
      end
  end
end
