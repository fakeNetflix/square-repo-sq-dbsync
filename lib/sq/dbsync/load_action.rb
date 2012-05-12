require 'date'
require 'tempfile'
require 'ostruct'

require 'sq/dbsync/schema_maker'

module Sq::Dbsync
  # An stateful action object representing the transfer of data from a source
  # table to a target. The action can be performed in full using `#call`, but
  # control can also be inverted using the `.stages` method, which allows the
  # action to be combined to run efficiently in parallel with other actions.
  #
  # This is useful because a single load taxes the source system then the target
  # system in sequence, so for maximum efficency a second load should be
  # interleaved to start taxing the source system as soon as the first finishes
  # the extract, rather than waiting for it to also finish the load. This is not
  # possible if the process is fully encapsulated as it is in `#call`.
  #
  # This is an abstract base class, see `BatchLoadAction` and
  # `IncrementalLoadAction` for example subclasses.
  class LoadAction
    EPOCH   = Date.new(2000, 1, 1).to_time

    # An empty action that is used when a load needs to be noop'ed in a manner
    # that does not raise an error (i.e. expected conditions).
    class NullAction
      def extract_data; self; end
      def load_data; self; end
      def post_load; self; end
    end

    def initialize(target, plan, registry, logger, now = ->{ Time.now.utc })
      @target   = target
      @plan     = OpenStruct.new(plan)
      @registry = registry
      @logger   = logger
      @now      = now
    end

    def call
      self.class.stages.inject(self) {|x, v| v.call(x) }
    end

    def self.stages
      [
        ->(x) { x.do_prepare || NullAction.new },
        ->(x) { x.extract_data },
        ->(x) { x.load_data },
        ->(x) { x.post_load }
      ]
    end

    def do_prepare
      return unless prepare

      ensure_target_exists
      self
    end

    protected

    attr_reader :target, :plan, :registry, :logger, :now

    def prepare
      registry.ensure_storage_exists
      return false unless plan.source_db.table_exists?(plan.table_name)
      add_schema_to_table_plan(plan)
      plan.prefixed_table_name = (prefix + plan.table_name.to_s).to_sym
      filter_columns
    end

    def ensure_target_exists
      unless target.table_exists?(plan.prefixed_table_name)
        SchemaMaker.create_table(target, plan)
      end
    end

    def add_schema_to_table_plan(x)
      x.schema ||= x.source_db.hash_schema(x.table_name)
      x
    end

    def extract_to_file(since)
      plan.source_db.ensure_connection

      last_row_at = plan.source_db[plan.table_name].
        max(([:updated_at, :created_at] & plan.columns)[0])

      file = make_writeable_tempfile

      plan.source_db.extract_incrementally_to_file(
        plan.table_name,
        plan.columns,
        file.path,
        since,
        0
      )

      [file, last_row_at]
    end

    def db; target; end

    def measure(stage, &block)
      label = "%s.%s.%s" % [
        operation,
        stage,
        plan.table_name
      ]
      logger.measure(label) { block.call }
    end

    def overlap
      self.class.overlap
    end

    def self.overlap
      15
    end

    def make_writeable_tempfile
      x = Tempfile.new(plan.table_name.to_s)
      x.chmod(0666)
      x
    end
  end
end
